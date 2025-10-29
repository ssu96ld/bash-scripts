#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# 03_add_branch.sh
# - Adds/updates a single repo branch as its own app instance
# - Safe alongside existing live/dev/staging
# - Bootstraps webhook server if missing (idempotent)
# - PM2 config & start
# - Nginx vhost + Certbot
# - Webhook integration:
#     * simple endpoint: /_deploy/<branch> (secret per domain)
#     * GitHub HMAC mapping: refs/heads/<branch> -> this instance
# ===========================================

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
BASE_PORT=3100   # base to scan from for feature branches

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

APP_USER="${SUDO_USER:-root}"
APP_HOME="$(eval echo ~${APP_USER})"

ensure_nvm_pm2() {
  sudo -u "${APP_USER}" bash -lc '
    if [[ ! -d "$HOME/.nvm" ]]; then
      echo "ERROR: NVM is not installed for '"${APP_USER}"' (run your server setup first)"; exit 1
    fi
    export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
    command -v pm2 >/dev/null 2>&1 || npm i -g pm2
  '
}

install_or_upgrade_webhook_server(){
  mkdir -p "${WEBHOOK_DIR}"

  # Create hooks.json if missing
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

  # Install/upgrade server.js to multi-app version if missing or outdated
  local needs_upgrade="yes"
  if [[ -f "${WEBHOOK_DIR}/server.js" ]]; then
    if grep -q "MULTI_GITHUB_SUPPORT" "${WEBHOOK_DIR}/server.js"; then
      needs_upgrade="no"
    fi
  fi

  if [[ "${needs_upgrade}" == "yes" ]]; then
    cp -a "${WEBHOOK_DIR}/server.js" "${WEBHOOK_DIR}/server.js.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cat > "${WEBHOOK_DIR}/server.js" <<'JS'
// MULTI_GITHUB_SUPPORT
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { exec } = require('child_process');

const cfgPath = path.join(__dirname, 'hooks.json');

function loadCfg() { return JSON.parse(fs.readFileSync(cfgPath, 'utf8')); }
function respond(res, code, obj) { res.writeHead(code, {'Content-Type':'application/json'}); res.end(JSON.stringify(obj)); }

function timingSafeEq(a, b) {
  const A = Buffer.from(a || '');
  const B = Buffer.from(b || '');
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
}
function verifyGitHubSig(buf, secret, hdr) {
  if (!hdr || !hdr.startsWith('sha256=')) return false;
  const h = crypto.createHmac('sha256', secret); h.update(buf);
  const expected = 'sha256=' + h.digest('hex');
  return timingSafeEq(expected, hdr);
}
function runDeploy(dir, branch, pm2Name, cb) {
  const cmds = [
    `cd '${dir.replace(/'/g, `'\\''`)}'`,
    `git fetch --all --prune`,
    `git reset --hard origin/${branch}`,
    `(npm ci || npm install)`,
    `pm2 restart '${pm2Name.replace(/'/g, `'\\''`)}'`
  ].join(' && ');
  exec(cmds, { shell:'/bin/bash' }, (err, stdout, stderr) => {
    if (err) return cb(err, stderr.toString());
    cb(null, stdout.toString());
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const host = (req.headers['host'] || '').split(':')[0];
  const cfg = loadCfg();

  if (req.method === 'GET' && url.pathname === '/_deploy/health') {
    return respond(res, 200, { ok:true, pong:true });
  }

  // simple hooks (per-domain, secret header)
  const simpleCandidates = (cfg.hooks || []).filter(h => (h.path === url.pathname) && (h.type === 'simple' || !h.type));
  if (simpleCandidates.length) {
    if (req.method !== 'POST') return respond(res, 405, { ok:false, error:'method not allowed' });
    let use = simpleCandidates.find(h => !!h.host && h.host === host) || simpleCandidates[0];
    const secret = req.headers['x-webhook-secret'];
    if (!secret || secret !== use.secret) return respond(res, 401, { ok:false, error:'unauthorized' });
    return runDeploy(use.dir, use.branch, use.pm2, (err, out) => {
      if (err) return respond(res, 500, { ok:false, error:'deploy failed', details: out });
      return respond(res, 200, { ok:true, result: out, id: use.id, host });
    });
  }

  // GitHub HMAC hooks (shared path; select by repo+ref)
  const ghCandidates = (cfg.github || []).filter(h => h.path === url.pathname);
  if (ghCandidates.length) {
    if (req.method !== 'POST') return respond(res, 405, { ok:false, error:'method not allowed' });
    const chunks = [];
    req.on('data', d => chunks.push(d));
    req.on('end', () => {
      const buf = Buffer.concat(chunks);
      const event = req.headers['x-github-event'] || '';
      if (event === 'ping') return respond(res, 200, { ok:true, pong:true });

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
            if (err) return respond(res, 500, { ok:false, error:'deploy failed', details: out, repo: fullName, ref });
            return respond(res, 200, { ok:true, result: out, repo: fullName, ref, id: gh.id });
          });
        } catch (e) { lastErr = e.message; }
      }
      return respond(res, 200, { ok:true, ignored: lastErr || 'no candidate matched' });
    });
    return;
  }

  return respond(res, 404, { ok:false, error:'not found' });
});

const cfg = loadCfg();
server.listen(cfg.listenPort, cfg.listenHost, () => {
  console.log(`Webhook server listening on ${cfg.listenHost}:${cfg.listenPort}`);
});
JS
    chown "${APP_USER}:${APP_USER}" "${WEBHOOK_DIR}/server.js"
  fi

  # Ensure pm2 process is up
  sudo -u "${APP_USER}" bash -lc '
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    cd "'"${WEBHOOK_DIR}"'"
    npm init -y >/dev/null 2>&1 || true
    pm2 start server.js --name deploy-webhooks || pm2 restart deploy-webhooks
    pm2 save
  '
}

# ---------- Preflight ----------
ensure_nvm_pm2

read -rp "App name (e.g., myapp): " APP_NAME
read -rp "GitHub repository URL: " REPO_URL
read -rp "Branch name to deploy (e.g., feature/auth): " BRANCH_NAME
read -rp "Domain for this branch (e.g., auth.dev.example.com): " BRANCH_DOMAIN
[[ -z "${APP_NAME}" || -z "${REPO_URL}" || -z "${BRANCH_NAME}" || -z "${BRANCH_DOMAIN}" ]] && { echo "All fields are required."; exit 1; }

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }
BRANCH_DOMAIN="$(strip_domain "${BRANCH_DOMAIN}")"

APP_DIR_ROOT="${WWW_ROOT}/${APP_NAME}"
BRANCH_SAFE="$(echo "${BRANCH_NAME}" | sed 's#[^A-Za-z0-9._-]#-#g')"
BRANCH_DIR="${APP_DIR_ROOT}/branches/${BRANCH_SAFE}"
PM2_NAME="${APP_NAME}-branch-${BRANCH_SAFE}"

mkdir -p "${BRANCH_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR_ROOT}"

# --- helpers ---
find_free_port() {
  local port="$1"
  while :; do
    if [[ -z "$(ss -H -ltn "sport = :$port")" ]]; then
      echo "$port"; return
    fi
    port=$((port+1))
  done
}

branch_exists_remote(){
  sudo -u gitdeploy bash -lc "git ls-remote --heads '$1' '$2'" | grep -q "refs/heads/$2"
}


clone_or_pull () {
  local branch="$1" target_dir="$2"
  if [[ -d "${target_dir}/.git" ]]; then
    sudo -u gitdeploy bash -lc "cd '${target_dir}' && git fetch origin '${branch}' && git checkout '${branch}' && git reset --hard 'origin/${branch}'"
  else
    sudo -u gitdeploy bash -lc "git clone --branch '${branch}' --single-branch '${REPO_URL}' '${target_dir}'"
  fi
}


repo_full_name_from_url () {
  local url="$1" out=""
  if [[ "$url" =~ ^git@github\.com:(.+)/(.+)\.git$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    out="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf "%s" "$out"
}
REPO_FULL_NAME="$(repo_full_name_from_url "${REPO_URL}")"

if ! branch_exists_remote "${REPO_URL}" "${BRANCH_NAME}"; then
  echo "ERROR: Remote branch '${BRANCH_NAME}' does not exist on ${REPO_URL}."
  exit 1
fi

# ---------- Ensure webhook server is installed/up-to-date ----------
install_or_upgrade_webhook_server

# --- Choose a stable port (persist to file) ---
PORT_FILE="${BRANCH_DIR}/.port"
if [[ -f "${PORT_FILE}" ]]; then
  BRANCH_PORT="$(cat "${PORT_FILE}")"
else
  BRANCH_PORT="$(find_free_port "${BASE_PORT}")"
  echo "${BRANCH_PORT}" > "${PORT_FILE}"
  chown "${APP_USER}:${APP_USER}" "${PORT_FILE}"
fi

# --- Code checkout/update ---
clone_or_pull "${BRANCH_NAME}" "${BRANCH_DIR}"

# --- PM2 ecosystem + .env ---
make_ecosystem(){
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: "${name}",
    cwd: "${dir}",
    script: "npm",
    args: "start",
    env: { PORT: "${port}", NODE_ENV: "development" },
    watch: false
  }]
};
EOF
  chown "${APP_USER}:${APP_USER}" "${dir}/ecosystem.config.js"
}
make_env(){
  local dir="$1" port="$2"
  [[ -f "${dir}/.env" ]] || { echo -e "PORT=${port}\nNODE_ENV=development" > "${dir}/.env"; chown "${APP_USER}:${APP_USER}" "${dir}/.env"; }
}

make_ecosystem "${BRANCH_DIR}" "${PM2_NAME}" "${BRANCH_PORT}"
make_env "${BRANCH_DIR}" "${BRANCH_PORT}"

start_pm2(){
  local dir="$1"
  sudo -u "${APP_USER}" bash -lc '
    set -e
    export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"
    cd "'"${dir}"'"
    npm config set fund false >/dev/null 2>&1 || true
    npm config set audit false >/dev/null 2>&1 || true
    CI=1 npm ci --no-audit --no-fund --unsafe-perm || CI=1 npm install --no-audit --no-fund --unsafe-perm
    pm2 start ecosystem.config.js || pm2 restart ecosystem.config.js
  '
}
start_pm2 "${BRANCH_DIR}"
sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 save'

# --- Nginx vhost for this branch ---
mkdir -p "${NGINX_CONF_DIR}"
VHOST_PATH="${NGINX_CONF_DIR}/${BRANCH_DOMAIN}.conf"
cat > "${VHOST_PATH}" <<EOF
server {
  listen 80; listen [::]:80;
  server_name ${BRANCH_DOMAIN};

  location / {
    proxy_pass http://127.0.0.1:${BRANCH_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Simple deploy hook (per-domain)
  location ^~ /_deploy/ {
    proxy_pass http://127.0.0.1:${WEBHOOK_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # GitHub Webhooks (HMAC)
  location ^~ /_github/ {
    proxy_pass http://127.0.0.1:${WEBHOOK_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF

nginx -t
systemctl reload nginx

# --- TLS (best-effort) ---
certbot --nginx -d "${BRANCH_DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email || echo "WARNING: certbot failed for ${BRANCH_DOMAIN}"

# --- Update hooks.json (upsert) ---
python3 - "$WEBHOOK_DIR/hooks.json" "$APP_NAME" "$REPO_URL" "$REPO_FULL_NAME" "$BRANCH_NAME" "$BRANCH_DIR" "$PM2_NAME" "$BRANCH_DOMAIN" <<'PY'
import json, os, sys, secrets, re
cfg_path, app_name, repo_url, repo_full, branch_name, branch_dir, pm2_name, branch_domain = sys.argv[1:9]

def load():
    with open(cfg_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save(cfg):
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

def parse_owner_repo(url):
    m = re.match(r'^git@github\.com:([^/]+)/([^/]+)\.git$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    m = re.match(r'^https?://github\.com/([^/]+)/([^/.]+)(?:\.git)?$', url)
    if m: return f"{m.group(1)}/{m.group(2)}"
    return ""

repo_full = repo_full or parse_owner_repo(repo_url)
cfg = load()
cfg.setdefault("hooks", [])
cfg.setdefault("github", [])

def get_or_create_secret():
    return secrets.token_hex(32)

# ----- simple hook: /_deploy/<branch> scoped to host -----
simple_id = f"{app_name}-branch-{re.sub(r'[^A-Za-z0-9._-]', '-', branch_name)}"
simple_path = f"/_deploy/{branch_name}"
simple_entry = None
for h in cfg["hooks"]:
    if h.get("id")==simple_id:
        h.update({"type":"simple","path":simple_path,"host":branch_domain,"dir":branch_dir,"branch":branch_name,"pm2":pm2_name})
        simple_entry = h
        break
if not simple_entry:
    simple_entry = {"type":"simple","id":simple_id,"path":simple_path,"host":branch_domain,"dir":branch_dir,"branch":branch_name,"pm2":pm2_name,"secret":get_or_create_secret()}
    cfg["hooks"].append(simple_entry)

# ----- GitHub HMAC mapping for this repo -----
gh = None
for g in cfg["github"]:
    if repo_full and g.get("repo")==repo_full:
        gh = g; break
# If none exists yet for this repo, create one
if not gh:
    gh = {"id": app_name, "path": "/_github", "secret": get_or_create_secret(), "repo": repo_full or "", "map": {}}
    cfg["github"].append(gh)

gh.setdefault("map", {})
gh["map"][f"refs/heads/{branch_name}"] = { "dir": branch_dir, "pm2": pm2_name, "branch": branch_name }

save(cfg)

# print simple secret and GH secret (for shell)
print(simple_entry.get("secret",""))
print(gh.get("secret",""))
PY

read -r SIMPLE_SECRET || SIMPLE_SECRET=""
read -r GH_SECRET || GH_SECRET=""

# restart webhook server to pick up changes
sudo -u "${APP_USER}" bash -lc 'export NVM_DIR=$HOME/.nvm; . "$NVM_DIR/nvm.sh"; pm2 restart deploy-webhooks; pm2 save'

echo
echo "================== BRANCH ADDED/UPDATED =================="
echo "App: ${APP_NAME}   Repo: ${REPO_URL}"
echo "Branch: ${BRANCH_NAME}"
echo "Dir: ${BRANCH_DIR}"
echo "Domain: https://${BRANCH_DOMAIN}"
echo "PM2: ${PM2_NAME}    PORT ${BRANCH_PORT}"
echo
echo "Manual deploy webhook (POST with X-Webhook-Secret):"
echo "  https://${BRANCH_DOMAIN}/_deploy/${BRANCH_NAME}    Secret: ${SIMPLE_SECRET:-existing}"
echo
echo "GitHub webhook (HMAC verified):"
echo "  Payload URL: https://${BRANCH_DOMAIN}/_github"
echo "  Secret: ${GH_SECRET:-existing}"
echo "  Mapping:"
echo "    refs/heads/${BRANCH_NAME}  → ${BRANCH_DIR}  (pm2: ${PM2_NAME})"
echo "==========================================================="
