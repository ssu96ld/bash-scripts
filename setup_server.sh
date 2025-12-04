#!/usr/bin/env bash
set -euo pipefail

# Idempotent server bootstrap: base packages, gitdeploy user, nvm/Node, pm2, shared webhook service.

DEBIAN_FRONTEND=noninteractive
GIT_USER="gitdeploy"
SHELL_FOR_USERS="/bin/bash"
WEBHOOK_DIR="/opt/deploy-webhooks"
WEBHOOK_PORT=9000
APP_USER="${SUDO_USER:-$(id -un)}"
APP_HOME="$(eval echo ~${APP_USER})"
NVM_VERSION="v0.39.7"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)"; exit 1; fi

# --- Packages ---
apt-get update -y
apt-get install -y curl build-essential git nginx python3-certbot-nginx ufw openssl

# --- Firewall ---
if command -v ufw >/dev/null 2>&1; then
  ufw allow 'Nginx Full' || true
fi

# --- gitdeploy user & SSH key (create if missing) ---
if ! id -u "$GIT_USER" >/dev/null 2>&1; then
  useradd -m -s "$SHELL_FOR_USERS" "$GIT_USER"
fi
install -d -m 700 -o "$GIT_USER" -g "$GIT_USER" "/home/$GIT_USER/.ssh"
if [[ ! -f "/home/$GIT_USER/.ssh/id_ed25519" ]]; then
  sudo -u "$GIT_USER" ssh-keygen -t ed25519 -N "" -C "${GIT_USER}@$(hostname)" -f "/home/$GIT_USER/.ssh/id_ed25519"
  echo
  echo "======== gitdeploy PUBLIC key ========"
  cat "/home/$GIT_USER/.ssh/id_ed25519.pub"
  echo "======================================"
  echo
  echo "======== gitdeploy PRIVATE key ======="
  cat "/home/$GIT_USER/.ssh/id_ed25519"
  echo "======================================"
  echo
else
  echo "gitdeploy user & SSH key already exist (not reprinted)."
fi

# --- nvm + Node LTS + pm2 for APP_USER (skip if present) ---
sudo -u "$APP_USER" bash -lc "
  if [[ ! -d \"\$HOME/.nvm\" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash
  fi
  export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"
  if ! command -v node >/dev/null 2>&1; then
    nvm install --lts
    nvm alias default 'lts/*'
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2
  fi
"

# --- Shared webhook server (create once) ---
if [[ ! -d "$WEBHOOK_DIR" ]]; then
  mkdir -p "$WEBHOOK_DIR"
  cat > "$WEBHOOK_DIR/hooks.json" <<JSON
{
  "listenHost": "127.0.0.1",
  "listenPort": ${WEBHOOK_PORT},
  "hooks": []
}
JSON

  cat > "$WEBHOOK_DIR/server.js" <<'JS'
const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const cfgPath = path.join(__dirname, 'hooks.json');

function loadCfg() {
  return JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
}
function respond(res, code, obj) {
  res.writeHead(code, {'Content-Type':'application/json'}); res.end(JSON.stringify(obj));
}
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/_deploy/health') return respond(res, 200, {ok:true});
  const cfg = loadCfg();
  const url = new URL(req.url, 'http://localhost');
  const hook = (cfg.hooks || []).find(h => h.path === url.pathname);
  if (!hook) return respond(res, 404, {ok:false,error:'not found'});
  if (req.method !== 'POST') return respond(res, 405, {ok:false,error:'method not allowed'});
  const secret = req.headers['x-webhook-secret'];
  if (!secret || secret !== hook.secret) return respond(res, 401, {ok:false,error:'unauthorized'});

  const cmds = [
    `cd '${hook.dir.replace(/'/g, `'\\''`)}'`,
    `git fetch --all --prune`,
    `git reset --hard origin/${hook.branch}`,
    `(npm ci || npm install)`,
    `pm2 restart '${hook.pm2.replace(/'/g, `'\\''`)}'`
  ].join(' && ');

  exec(cmds, {shell:'/bin/bash'}, (err, stdout, stderr) => {
    if (err) return respond(res, 500, {ok:false, error:'deploy failed', details: stderr.toString()});
    respond(res, 200, {ok:true, result: stdout.toString()});
  });
});
const cfg = loadCfg();
server.listen(cfg.listenPort, cfg.listenHost, () => console.log(`deploy-webhooks listening on ${cfg.listenHost}:${cfg.listenPort}`));
JS

  chown -R "$APP_USER:$APP_USER" "$WEBHOOK_DIR"
  sudo -u "$APP_USER" bash -lc "
    export NVM_DIR=\$HOME/.nvm; . \"\$NVM_DIR/nvm.sh\"
    cd '$WEBHOOK_DIR'
    npm init -y >/dev/null 2>&1 || true
    pm2 start server.js --name deploy-webhooks
    pm2 save
    pm2 startup systemd -u '${APP_USER}' --hp '${APP_HOME}' | sed -n \"s/^.*\\(sudo.*pm2.*\\)\$/\\1/p\" | bash
  "
else
  echo "Shared webhook server already present. Restarting to be safe."
  sudo -u "$APP_USER" bash -lc "export NVM_DIR=\$HOME/.nvm; . \"\$NVM_DIR/nvm.sh\"; pm2 restart deploy-webhooks || true; pm2 save"
fi

echo "Server setup complete. You can now run 02_add_app.sh to add apps."
