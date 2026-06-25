#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)" >&2' ERR

# ===========================================
# add_domain.sh
# - Adds an additional domain to an existing deployed app or branch
# - Updates the nginx vhost only (no app/PM2/hooks changes)
# - Expands the existing Let's Encrypt cert to cover the new domain
#   via `certbot --nginx --expand` (original domain + cert remain intact)
# ===========================================

NGINX_CONF_DIR="/etc/nginx/conf.d"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root (sudo)" >&2
  exit 1
fi

command -v nginx   >/dev/null 2>&1 || { echo "ERROR: nginx not found"   >&2; exit 1; }
command -v certbot >/dev/null 2>&1 || { echo "ERROR: certbot not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }

strip_domain(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "${s%%/*}"; }

read -rp "Existing primary domain (e.g., example.com): " PRIMARY_DOMAIN
read -rp "Additional domain to add (e.g., www.example.com): " NEW_DOMAIN

PRIMARY_DOMAIN="$(strip_domain "${PRIMARY_DOMAIN}")"
NEW_DOMAIN="$(strip_domain "${NEW_DOMAIN}")"

[[ -z "${PRIMARY_DOMAIN}" || -z "${NEW_DOMAIN}" ]] && { echo "Both domains are required." >&2; exit 1; }
[[ "${PRIMARY_DOMAIN}" == "${NEW_DOMAIN}" ]] && { echo "Additional domain must differ from primary domain." >&2; exit 1; }

CONF_PATH="${NGINX_CONF_DIR}/${PRIMARY_DOMAIN}.conf"
if [[ ! -f "${CONF_PATH}" ]]; then
  echo "ERROR: nginx config not found at ${CONF_PATH}" >&2
  echo "Make sure '${PRIMARY_DOMAIN}' is the primary domain of an existing app/branch." >&2
  exit 1
fi

# Append NEW_DOMAIN to every `server_name` directive that doesn't already include it.
python3 - "${CONF_PATH}" "${NEW_DOMAIN}" <<'PY'
import os, re, sys
path, new_domain = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

pattern = re.compile(r"^([ \t]*)server_name[ \t]+([^;]+);", re.M)

def repl(m):
    indent, names = m.group(1), m.group(2).strip()
    tokens = names.split()
    if new_domain in tokens:
        return m.group(0)
    tokens.append(new_domain)
    return f"{indent}server_name {' '.join(tokens)};"

new_text, n = pattern.subn(repl, text)
if n == 0:
    print("ERROR: no server_name directive found in nginx config", file=sys.stderr)
    raise SystemExit(2)

if new_text != text:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, path)
    print(f"Added '{new_domain}' to {n} server_name directive(s).")
else:
    print(f"'{new_domain}' already present in all server_name directives.")
PY

echo "Validating nginx config..."
nginx -t
systemctl reload nginx

echo
echo "Expanding TLS cert to include '${NEW_DOMAIN}' (existing cert preserved via --expand)..."
certbot --nginx --expand \
  -d "${PRIMARY_DOMAIN}" -d "${NEW_DOMAIN}" \
  --non-interactive --agree-tos --register-unsafely-without-email

nginx -t
systemctl reload nginx

echo
echo "================== DOMAIN ADDED =================="
echo "Primary domain:    https://${PRIMARY_DOMAIN}"
echo "Additional domain: https://${NEW_DOMAIN}"
echo "Nginx config:      ${CONF_PATH}"
echo "==================================================="
