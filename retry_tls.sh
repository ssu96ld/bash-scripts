#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)" >&2' ERR

# Retry issuing TLS for an existing app/branch without re-running add_app.sh.
# - Finds the domain + dir via /opt/deploy-webhooks/hooks.json
# - Ensures nginx vhost exists and targets the correct PORT
# - Can request multi-domain (e.g. apex + www) or wildcard certs

NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBHOOK_DIR="/opt/deploy-webhooks"
HOOKS_JSON="${WEBHOOK_DIR}/hooks.json"
WEBHOOK_PORT=9000

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root (sudo)" >&2
  exit 1
fi

command -v nginx >/dev/null 2>&1 || { echo "ERROR: nginx not found" >&2; exit 1; }
command -v certbot >/dev/null 2>&1 || { echo "ERROR: certbot not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }

if [[ ! -f "${HOOKS_JSON}" ]]; then
  echo "ERROR: hooks.json not found at ${HOOKS_JSON}" >&2
  exit 1
fi

read -rp "App name (e.g., myapp): " APP_NAME
read -rp "Branch (live/dev/staging): " BRANCH

APP_NAME="${APP_NAME// /}"
BRANCH="${BRANCH// /}"

if [[ -z "${APP_NAME}" ]]; then
  echo "ERROR: app name is required" >&2
  exit 1
fi

case "${BRANCH}" in
  live|dev|staging) ;;
  *)
    echo "ERROR: branch must be one of: live, dev, staging" >&2
    exit 1
    ;;
esac

strip_domain() {
  local s="$1"
  s="${s#http://}"
  s="${s#https://}"
  echo "${s%%/*}"
}

join_by_space() {
  local out="" x
  for x in "$@"; do
    [[ -z "${x}" ]] && continue
    if [[ -z "${out}" ]]; then out="${x}"; else out="${out} ${x}"; fi
  done
  printf '%s' "${out}"
}

dedupe_domains() {
  # inputs: domains... ; output: unique, in order
  local out=() d seen=" "
  for d in "$@"; do
    d="$(strip_domain "${d}")"
    [[ -z "${d}" ]] && continue
    if [[ "${seen}" != *" ${d} "* ]]; then
      out+=("${d}")
      seen="${seen}${d} "
    fi
  done
  printf '%s\n' "${out[@]:-}"
}

build_certbot_domain_args() {
  # outputs: "-d domain1 -d domain2 ..."
  local -a args=() d
  for d in "$@"; do
    [[ -z "${d}" ]] && continue
    args+=("-d" "${d}")
  done
  printf '%s\0' "${args[@]}"
}

read_hook() {
  local app="$1" branch="$2"
  python3 - "${HOOKS_JSON}" "${app}" "${branch}" <<'PY'
import json, sys
path, app, branch = sys.argv[1:4]
hook_id = f"{app}-{branch}"
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
for h in cfg.get("hooks", []):
    if h.get("id") == hook_id:
        host = (h.get("host") or "").strip()
        dirp = (h.get("dir") or "").strip()
        print(host)
        print(dirp)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

HOOK_OUT="$(read_hook "${APP_NAME}" "${BRANCH}")" || {
  echo "ERROR: could not find hook entry '${APP_NAME}-${BRANCH}' in ${HOOKS_JSON}" >&2
  exit 1
}

DOMAIN="$(printf '%s\n' "${HOOK_OUT}" | sed -n '1p')"
APP_DIR="$(printf '%s\n' "${HOOK_OUT}" | sed -n '2p')"

DOMAIN="$(strip_domain "${DOMAIN}")"

if [[ -z "${DOMAIN}" ]]; then
  echo "ERROR: hook '${APP_NAME}-${BRANCH}' has no host/domain configured" >&2
  exit 1
fi
if [[ -z "${APP_DIR}" || ! -d "${APP_DIR}" ]]; then
  echo "ERROR: hook '${APP_NAME}-${BRANCH}' has invalid dir '${APP_DIR}'" >&2
  exit 1
fi

PORT=""
if [[ -f "${APP_DIR}/.env" ]]; then
  PORT="$(awk -F= '/^PORT=/{print $2; exit}' "${APP_DIR}/.env" | tr -d '\r')"
fi
if [[ -z "${PORT}" && -f "${APP_DIR}/ecosystem.config.cjs" ]]; then
  PORT="$(sed -nE 's/.*PORT:[[:space:]]*"([0-9]+)".*/\1/p' "${APP_DIR}/ecosystem.config.cjs" | head -n1)"
fi
if [[ -z "${PORT}" ]]; then
  echo "ERROR: could not determine PORT from ${APP_DIR}/.env or ecosystem.config.cjs" >&2
  exit 1
fi
if [[ ! "${PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: invalid PORT '${PORT}'" >&2
  exit 1
fi

echo
echo "Certificate options for ${DOMAIN}:"
echo "  1) Single domain (${DOMAIN}) [default]"
echo "  2) Include www (${DOMAIN} + www.${DOMAIN})"
echo "  3) Additional domains (enter a list)"
echo "  4) Wildcard (*.${DOMAIN} + ${DOMAIN}) via DNS challenge (manual)"
read -rp "Choose option [1-4]: " CERT_OPT
CERT_OPT="${CERT_OPT:-1}"

DOMAINS=()
WILDCARD_MODE="false"
case "${CERT_OPT}" in
  1)
    DOMAINS=("${DOMAIN}")
    ;;
  2)
    DOMAINS=("${DOMAIN}" "www.${DOMAIN}")
    ;;
  3)
    read -rp "Additional domains (comma/space separated, e.g. www.${DOMAIN} other.example.com): " EXTRA
    # shellcheck disable=SC2206
    EXTRA_ARR=(${EXTRA//,/ })
    # Always include the primary domain first
    mapfile -t DOMAINS < <(dedupe_domains "${DOMAIN}" "${EXTRA_ARR[@]:-}")
    ;;
  4)
    DOMAINS=("${DOMAIN}" "*.${DOMAIN}")
    WILDCARD_MODE="true"
    ;;
  *)
    echo "ERROR: invalid option '${CERT_OPT}'" >&2
    exit 1
    ;;
esac

if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
  echo "ERROR: no domains selected" >&2
  exit 1
fi

CONF_PATH="${NGINX_CONF_DIR}/${DOMAIN}.conf"

write_vhost() {
  local server_names="$1" port="$2"
  mkdir -p "${NGINX_CONF_DIR}"
  cat > "${CONF_PATH}" <<EOF
server {
  listen 80; listen [::]:80;
  server_name ${server_names};

  location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location ^~ /_deploy/ { proxy_pass http://127.0.0.1:${WEBHOOK_PORT}; }
  location ^~ /_github/ { proxy_pass http://127.0.0.1:${WEBHOOK_PORT}; }
}
EOF
}

SERVER_NAME_DOMAINS=()
for d in "${DOMAINS[@]}"; do
  # Exclude wildcard names from nginx server_name
  if [[ "${d}" == \*.* ]]; then
    continue
  fi
  SERVER_NAME_DOMAINS+=("${d}")
done
mapfile -t SERVER_NAME_DOMAINS < <(dedupe_domains "${SERVER_NAME_DOMAINS[@]:-}")
SERVER_NAMES="$(join_by_space "${SERVER_NAME_DOMAINS[@]:-}")"
SERVER_NAMES="$(printf '%s' "${SERVER_NAMES}" | tr -s ' ' | sed 's/^ //; s/ $//')"
[[ -z "${SERVER_NAMES}" ]] && SERVER_NAMES="${DOMAIN}"

if [[ ! -f "${CONF_PATH}" ]]; then
  echo "Creating nginx vhost ${CONF_PATH} (server_name='${SERVER_NAMES}' port=${PORT})"
  write_vhost "${SERVER_NAMES}" "${PORT}"
else
  # Keep existing certbot-managed structure but ensure upstream port is correct.
  if grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:[0-9]+;' "${CONF_PATH}"; then
    sed -i.bak -E "s#proxy_pass[[:space:]]+http://127\.0\.0\.1:[0-9]+;#proxy_pass http://127.0.0.1:${PORT};#g" "${CONF_PATH}"
  fi

  # Ensure the vhost includes all requested non-wildcard names.
  if grep -qE '^[[:space:]]*server_name[[:space:]]+' "${CONF_PATH}"; then
    python3 - "${CONF_PATH}" "${SERVER_NAMES}" <<'PY'
import io, sys
path, names = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith("server_name "):
        indent = line[: len(line) - len(stripped)]
        out.append(f"{indent}server_name {names};\n")
    else:
        out.append(line)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.writelines(out)
import os
os.replace(tmp, path)
PY
  fi
fi

nginx -t
systemctl reload nginx

echo
echo "Requesting/renewing TLS cert for: ${DOMAINS[*]} (branch=${BRANCH}, app=${APP_NAME})"
CERTBOT_ARGS=()
while IFS= read -r -d '' part; do CERTBOT_ARGS+=("$part"); done < <(build_certbot_domain_args "${DOMAINS[@]}")
if [[ "${WILDCARD_MODE}" == "true" ]]; then
  echo "Wildcard certs require a DNS challenge. Certbot will prompt you to create TXT records."
  certbot certonly --manual --preferred-challenges dns --manual-public-ip-logging-ok \
    --agree-tos --register-unsafely-without-email \
    "${CERTBOT_ARGS[@]}"
else
  certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
    "${CERTBOT_ARGS[@]}"
fi

nginx -t
systemctl reload nginx

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  echo "✓ Certificate present at /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
else
  echo "WARNING: certbot completed but cert file not found at /etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >&2
fi

echo "Done."
