#!/usr/bin/env bash
set -euo pipefail

# server_doc_snapshot.sh
# YAML snapshot for documenting the server & apps.

WWW_ROOT="/var/www"
NGINX_CONF_DIR="/etc/nginx/conf.d"
GIT_USER="gitdeploy"
PUBKEY_PATH="/home/${GIT_USER}/.ssh/id_ed25519.pub"
PRIVKEY_PATH="/home/${GIT_USER}/.ssh/id_ed25519"

# ---------- helpers ----------
indent() { local n="$1"; shift; local pad; pad="$(printf '%*s' "$n" '')"; sed "s/^/${pad}/"; }
yaml_q() { local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf "%s" "$s"; }

get_public_ip() {
  local ip=""
  command -v curl >/dev/null 2>&1 && ip="$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me || true)"
  [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1 && ip="$(dig +short myip.opendns.com @resolver1.opendns.com || true)"
  [[ -z "$ip" ]] && command -v wget >/dev/null 2>&1 && ip="$(wget -qO- https://api.ipify.org || true)"
  echo "${ip:-unknown}"
}

have_git_repo() { [[ -d "$1/.git" ]]; }
git_field() {
  local dir="$1" field="$2"
  case "$field" in
    repo)    git -C "$dir" remote get-url origin 2>/dev/null || true ;;
    branch)  git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true ;;
    commit)  git -C "$dir" rev-parse --short HEAD 2>/dev/null || true ;;
    subject) git -C "$dir" log -1 --pretty=%s 2>/dev/null || true ;;
  esac
}

# PORT detection: prefer .env, then ecosystem.config.js
get_port_for_dir() {
  local dir="$1" p=""
  if [[ -f "$dir/.env" ]]; then
    p="$(grep -E '^PORT=' "$dir/.env" | sed -E 's/^PORT=//; s/"//g' | tail -n1)"
  fi
  if [[ -z "$p" && -f "$dir/ecosystem.config.js" ]]; then
    p="$(grep -Eo 'PORT[^0-9]*[\"\x27]?([0-9]{2,5})[\"\x27]?' "$dir/ecosystem.config.js" | grep -Eo '[0-9]{2,5}' | head -n1 || true)"
  fi
  echo "$p"
}

# Find domain (server_name) whose server block proxies to a given port
get_domain_for_port() {
  local port="$1" conf dom=""
  shopt -s nullglob
  for conf in "$NGINX_CONF_DIR"/*.conf; do
    grep -qE "proxy_pass\s+http://127\.0\.0\.1:$port" "$conf" || continue
    dom="$(awk '
      /server\s*\{/ {inserver=1}
      inserver && /server_name/ {print $2; exit}
    ' "$conf" | sed 's/;//')"
    [[ -n "$dom" ]] && { echo "$dom"; return 0; }
  done
  echo ""
}

# curl a URL and return HTTP code (000 on failure)
curl_code() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || { echo "curl_not_installed"; return 0; }
  curl -kLs -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || echo "000"
}

# Try to read PM2 status (JSON) from the most likely user
get_pm2_json() {
  local try_users=()
  try_users+=("$(id -un)")
  [[ -n "${SUDO_USER:-}" ]] && try_users+=("${SUDO_USER}")
  try_users+=("root")
  local u out=""
  for u in "${try_users[@]}"; do
    out="$(sudo -u "$u" bash -lc 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; pm2 jlist 2>/dev/null || true' || true)"
    [[ -n "$out" && "$out" != "[]" ]] && { echo "$out"; return 0; }
  done
  echo "[]"
}

# Build a quick lookup table: CWD|NAME|STATUS|PM_ID|CPU|MEM|PORT_ENV
build_pm2_map() {
  local json="$1"
  command -v python3 >/dev/null 2>&1 || { echo ""; return 0; }
  python3 - "$json" <<'PY'
import json, sys
data = sys.argv[1]
try:
    plist = json.loads(data)
except Exception:
    plist = []
for p in plist:
    env = p.get("pm2_env", {}) or {}
    monit = p.get("monit", {}) or {}
    cwd = env.get("cwd","") or env.get("pm_cwd","")
    name = env.get("name","")
    status = env.get("status","")
    pm_id = env.get("pm_id","")
    cpu = monit.get("cpu","")
    mem = monit.get("memory","")
    penv = env.get("env",{}) or {}
    port = penv.get("PORT","")
    print(f"{cwd}|{name}|{status}|{pm_id}|{cpu}|{mem}|{port}")
PY
}

# ---------- gather host ----------
STAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname || echo unknown)"
OS_PRETTY=""; KERNEL="$(uname -sr)"
if [[ -r /etc/os-release ]]; then . /etc/os-release; OS_PRETTY="${PRETTY_NAME:-$NAME}"; fi
PUBLIC_IP="$(get_public_ip)"

# gitdeploy basics
GITDEPLOY_EXISTS="false"
if id -u "$GIT_USER" >/dev/null 2>&1; then GITDEPLOY_EXISTS="true"; fi

# PM2 mapping
PM2_JSON="$(get_pm2_json)"
PM2_MAP="$(build_pm2_map "$PM2_JSON")"

# ---------- output YAML ----------
echo "---"
echo "generated_at: \"${STAMP}\""
echo "host:"
echo "  hostname: \"$(yaml_q "$HOST_FQDN")\""
echo "  os: \"$(yaml_q "$OS_PRETTY")\""
echo "  kernel: \"$(yaml_q "$KERNEL")\""
echo "  public_ip: \"$(yaml_q "$PUBLIC_IP")\""

echo "gitdeploy:"
if [[ "$GITDEPLOY_EXISTS" == "true" ]]; then
  # Parse passwd line safely without awk quoting woes
  # passwd fields: name:passwd:uid:gid:gecos:home:shell
  GU_NAME=""; GU_UID=""; GU_GID=""; GU_GECOS=""; GU_HOME=""; GU_SHELL=""
  IFS=: read -r GU_NAME _ GU_UID GU_GID GU_GECOS GU_HOME GU_SHELL < <(getent passwd "$GIT_USER")
  echo "  username: \"${GU_NAME}\""
  echo "  uid: \"${GU_UID}\""
  echo "  home: \"$(yaml_q "$GU_HOME")\""
  echo "  shell: \"$(yaml_q "$GU_SHELL")\""
  echo "  ssh:"
  if [[ -r "$PUBKEY_PATH" ]]; then
    echo "    public_key: |"; cat "$PUBKEY_PATH" | indent 6
  else
    echo "    public_key: \"(not found)\""
  fi
  if [[ -r "$PRIVKEY_PATH" ]]; then
    echo "    private_key: |"; cat "$PRIVKEY_PATH" | indent 6
  else
    echo "    private_key: \"(not found)\""
  fi
else
  echo "  note: \"user '${GIT_USER}' not found\""
fi

echo "apps:"
if [[ -d "$WWW_ROOT" ]]; then
  shopt -s nullglob
  APP_DIRS=("$WWW_ROOT"/*)
  if [[ ${#APP_DIRS[@]} -eq 0 ]]; then
    echo "  []"
  else
    for app_dir in "${APP_DIRS[@]}"; do
      [[ -d "$app_dir" ]] || continue
      app_name="$(basename "$app_dir")"

      # collect env folders: known ones + any other git-backed subdir
      envs=()
      for e in live dev staging; do [[ -d "$app_dir/$e" ]] && envs+=("$e"); done
      for extra in "$app_dir"/*; do
        [[ -d "$extra" ]] || continue
        ebase="$(basename "$extra")"
        [[ " ${envs[*]} " == *" $ebase "* ]] && continue
        have_git_repo "$extra" && envs+=("$ebase")
      done
      [[ ${#envs[@]} -eq 0 ]] && continue

      echo "  - name: \"$(yaml_q "$app_name")\""
      echo "    root: \"$(yaml_q "$app_dir")\""
      echo "    environments:"

      for env in "${envs[@]}"; do
        env_dir="$app_dir/$env"
        repo="$(git_field "$env_dir" repo)"
        branch="$(git_field "$env_dir" branch)"
        commit="$(git_field "$env_dir" commit)"
        subject="$(git_field "$env_dir" subject)"
        port="$(get_port_for_dir "$env_dir")"
        domain=""
        [[ -n "$port" ]] && domain="$(get_domain_for_port "$port")"

        # PM2 linkage: by cwd (exact). Fallback to name "<app>-<env>"
        pm2_name=""; pm2_status=""; pm2_id=""; pm2_cpu=""; pm2_mem=""; pm2_env_port=""
        if [[ -n "$PM2_MAP" ]]; then
          while IFS='|' read -r cwd name status id cpu mem penv_port; do
            [[ -z "$cwd" ]] && continue
            if [[ "$cwd" == "$env_dir" ]]; then
              pm2_name="$name"; pm2_status="$status"; pm2_id="$id"; pm2_cpu="$cpu"; pm2_mem="$mem"; pm2_env_port="$penv_port"
              break
            fi
          done <<< "$PM2_MAP"
        fi
        [[ -z "$pm2_name" ]] && pm2_name="${app_name}-${env}"

        # Health checks
        https_code=""; http_code=""; local_code=""
        if [[ -n "$domain" ]]; then
          https_code="$(curl_code "https://${domain}/")"
          http_code="$(curl_code "http://${domain}/")"
        fi
        if [[ -n "$port" ]]; then
          local_code="$(curl_code "http://127.0.0.1:${port}/")"
        fi

        echo "      - env: \"$(yaml_q "$env")\""
        echo "        path: \"$(yaml_q "$env_dir")\""
        echo "        repo: \"$(yaml_q "$repo")\""
        echo "        branch: \"$(yaml_q "$branch")\""
        echo "        commit: \"$(yaml_q "$commit")\""
        echo "        commit_message: \"$(yaml_q "$subject")\""
        echo "        port: \"$(yaml_q "${port:-unknown}")\""
        echo "        domain: \"$(yaml_q "${domain:-unknown}")\""
        echo "        pm2:"
        echo "          name: \"$(yaml_q "$pm2_name")\""
        echo "          status: \"$(yaml_q "${pm2_status:-unknown}")\""
        echo "          id: \"$(yaml_q "${pm2_id:-}")\""
        echo "          cpu: \"$(yaml_q "${pm2_cpu:-}")\""
        echo "          memory_bytes: \"$(yaml_q "${pm2_mem:-}")\""
        echo "          env_port: \"$(yaml_q "${pm2_env_port:-}")\""
        echo "        health:"
        echo "          https_code: \"$(yaml_q "${https_code:-}")\""
        echo "          http_code: \"$(yaml_q "${http_code:-}")\""
        echo "          local_code: \"$(yaml_q "${local_code:-}")\""
      done
    done
  fi
else
  echo "  []"
fi
