#!/usr/bin/env bash
set -euo pipefail

# setup_webhook_server.sh
# - Idempotently install/upgrade the shared deploy-webhooks server
# - Ensures:
#     * /opt/deploy-webhooks/hooks.json (with hooks + github arrays)
#     * /opt/deploy-webhooks/server.js (MULTI_GITHUB_SUPPORT variant)
#     * pm2 process "deploy-webhooks" running under APP_USER
#     * sudo rule so APP_USER can run git as gitdeploy (for webhook git operations)

WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~"${APP_USER}")"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)"
  exit 1
fi

# --- ensure sudo rule for APP_USER to run git as gitdeploy (no password) ---
GIT_BIN="$(command -v git || echo /usr/bin/git)"
if [[ -n "$GIT_BIN" ]]; then
  SUDOERS_FILE="/etc/sudoers.d/deploy-webhooks-git-${APP_USER}"
  LINE="${APP_USER} ALL=(${GIT_USER}) NOPASSWD:${GIT_BIN}"
  if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -Fxq "$LINE" "$SUDOERS_FILE"; then
    echo "$LINE" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
  fi
fi

mkdir -p "${WEBHOOK_DIR}"

# --- hooks.json (ensure multi-app structure) ---
if [[ ! -f "${WEBHOOK_DIR}/hooks.json" ]]; then
  cat > "${WEBHOOK_DIR}/hooks.json" <<JSON
{
  "listenHost": "127.0.0.1",
  "listenPort": ${WEBHOOK_PORT},
  "hooks": [],
  "github": []
}
JSON
  chown "${APP_USER}:${APP_USER}" "${WEBHOOK_DIR}/hooks.json"
fi

# --- server.js (MULTI_GITHUB_SUPPORT, git via sudo -u gitdeploy) ---
if [[ -f "${WEBHOOK_DIR}/server.js" ]]; then
  cp -a "${WEBHOOK_DIR}/server.js" "${WEBHOOK_DIR}/server.js.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
fi

cat > "${WEBHOOK_DIR}/server.js" <<'JS'
// MULTI_GITHUB_SUPPORT
// Uses sudo -u gitdeploy for git operations, PM2 as APP_USER.
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exec } = require('child_process');

const GIT_USER = 'gitdeploy';
const cfgPath = path.join(__dirname, 'hooks.json');

function loadCfg() { return JSON.parse(fs.readFileSync(cfgPath, 'utf8')); }
function respond(res, code, obj) {
  res.writeHead(code, {'Content-Type':'application/json'});
  res.end(JSON.stringify(obj));
}

function timingSafeEq(a, b) {
  const A = Buffer.from(a || '');
  const B = Buffer.from(b || '');
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
}

function verifyGitHubSig(buf, secret, hdr) {
  if (!hdr || !hdr.startsWith('sha256=')) return false;
  const h = crypto.createHmac('sha256', secret);
  h.update(buf);
  const expected = 'sha256=' + h.digest('hex');
  return timingSafeEq(expected, hdr);
}

function runDeploy(dir, branch, pm2Name, cb) {
  const safeDir = dir.replace(/'/g, `'\\''`);
  const safePm2 = pm2Name.replace(/'/g, `'\\''`);
  const cmds = [
    `sudo -u ${GIT_USER} git -C '${safeDir}' fetch --all --prune`,
    `sudo -u ${GIT_USER} git -C '${safeDir}' reset --hard origin/${branch}`,
    `cd '${safeDir}'`,
    `(npm ci || npm install)`,
    `pm2 restart '${safePm2}'`
  ].join(' && ');
  exec(cmds, { shell: '/bin/bash' }, (err, stdout, stderr) => {
    if (err) return cb(err, stderr.toString());
    cb(null, stdout.toString());
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const host = (req.headers['host'] || '').split(':')[0];
  const cfg = loadCfg();

  if (req.method === 'GET' && url.pathname === '/_deploy/health') {
    return respond(res, 200, { ok: true, pong: true });
  }

  // simple hooks (per-domain, secret header)
  const simpleCandidates = (cfg.hooks || []).filter(
    h => (h.path === url.pathname) && (h.type === 'simple' || !h.type)
  );
  if (simpleCandidates.length) {
    if (req.method !== 'POST') {
      return respond(res, 405, { ok: false, error: 'method not allowed' });
    }
    let use = simpleCandidates.find(h => !!h.host && h.host === host) || simpleCandidates[0];
    const secret = req.headers['x-webhook-secret'];
    if (!secret || secret !== use.secret) {
      return respond(res, 401, { ok: false, error: 'unauthorized' });
    }
    return runDeploy(use.dir, use.branch, use.pm2, (err, out) => {
      if (err) return respond(res, 500, { ok: false, error: 'deploy failed', details: out });
      return respond(res, 200, { ok: true, result: out, id: use.id, host });
    });
  }

  // GitHub HMAC hooks (shared path; select by repo+ref)
  const ghCandidates = (cfg.github || []).filter(h => h.path === url.pathname);
  if (ghCandidates.length) {
    if (req.method !== 'POST') {
      return respond(res, 405, { ok: false, error: 'method not allowed' });
    }
    const chunks = [];
    req.on('data', d => chunks.push(d));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      const event = req.headers['x-github-event'] || '';
      if (event === 'ping') return respond(res, 200, { ok: true, pong: true });

      let lastErr = null;
      for (const gh of ghCandidates) {
        try {
          const sig = req.headers['x-hub-signature-256'];
          if (!verifyGitHubSig(buf, gh.secret, sig)) continue;
          const payload = JSON.parse(buf.toString('utf8'));
          const fullName = payload?.repository?.full_name;
          const ref = payload?.ref;
          if (gh.repo && fullName !== gh.repo) { lastErr = `repo mismatch ${fullName}`; continue; }
          const target = gh.map?.[ref];
          if (!target) { lastErr = `no mapping for ${ref}`; continue; }
          return runDeploy(target.dir, target.branch, target.pm2, (err, out) => {
            if (err) {
              return respond(res, 500, {
                ok: false,
                error: 'deploy failed',
                details: out,
                repo: fullName,
                ref
              });
            }
            return respond(res, 200, {
              ok: true,
              result: out,
              repo: fullName,
              ref,
              id: gh.id
            });
          });
        } catch (e) { lastErr = e.message; }
      }
      return respond(res, 200, { ok: true, ignored: lastErr || 'no candidate matched' });
    });
    return;
  }

  return respond(res, 404, { ok: false, error: 'not found' });
});

const cfg = loadCfg();
server.listen(cfg.listenPort, cfg.listenHost, () => {
  console.log(`Webhook server listening on ${cfg.listenHost}:${cfg.listenPort}`);
});
JS

chown -R "${APP_USER}:${APP_USER}" "${WEBHOOK_DIR}"

# --- ensure pm2 process is up for APP_USER ---
sudo -u "${APP_USER}" bash -lc '
  export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
  cd "'"${WEBHOOK_DIR}"'"
  npm init -y >/dev/null 2>&1 || true
  pm2 start server.js --name deploy-webhooks || pm2 restart deploy-webhooks
  pm2 save
'

echo "deploy-webhooks server ensured (hooks.json + server.js + pm2) for APP_USER=${APP_USER}"


