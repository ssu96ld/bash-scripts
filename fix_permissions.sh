#!/usr/bin/env bash
set -euo pipefail

# fix_permissions.sh
# Fix ownership and permissions for existing app deployments
# so that gitdeploy can run git operations and APP_USER can run npm/pm2

WWW_ROOT="/var/www"
GIT_USER="gitdeploy"
APP_USER="${SUDO_USER:-$(id -un)}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)"
  exit 1
fi

if ! id -u "$GIT_USER" >/dev/null 2>&1; then
  echo "ERROR: gitdeploy user not found."
  exit 1
fi

# Ensure gitdeploy user is in APP_USER's primary group for shared access
APP_USER_GID=$(id -g "$APP_USER")
if ! id -nG "$GIT_USER" | grep -qw "$(id -gn "$APP_USER")"; then
  echo "Adding ${GIT_USER} to ${APP_USER}'s group for shared file access..."
  usermod -a -G "$(id -gn "$APP_USER")" "$GIT_USER"
fi

echo "Fixing permissions for app deployments in ${WWW_ROOT}..."
echo "Git operations user: ${GIT_USER}"
echo "Application user: ${APP_USER}"
echo ""

if [[ ! -d "$WWW_ROOT" ]]; then
  echo "No ${WWW_ROOT} directory found."
  exit 0
fi

shopt -s nullglob
APP_DIRS=("$WWW_ROOT"/*)

if [[ ${#APP_DIRS[@]} -eq 0 ]]; then
  echo "No app directories found in ${WWW_ROOT}"
  exit 0
fi

for app_dir in "${APP_DIRS[@]}"; do
  [[ -d "$app_dir" ]] || continue
  app_name="$(basename "$app_dir")"
  
  echo "Processing app: ${app_name}"
  
  for env_dir in "$app_dir"/*; do
    [[ -d "$env_dir" ]] || continue
    [[ -d "$env_dir/.git" ]] || continue
    
    env_name="$(basename "$env_dir")"
    echo "  - Fixing ${env_name} environment (${env_dir})"
    
    # Set ownership: gitdeploy owns everything, APP_USER is the group
    chown -R "${GIT_USER}:${APP_USER}" "${env_dir}"
    
    # Make group read/write/execute (X = execute only on dirs and executables)
    chmod -R g+rwX "${env_dir}"
    
    # Set setgid bit on directories so new files inherit the group
    find "${env_dir}" -type d -exec chmod g+s {} \;
    
    echo "    ✓ Fixed permissions (gitdeploy:${APP_USER} with group write)"
  done
done

echo ""
echo "✓ Permissions fixed for all app deployments"
echo ""
echo "All files are owned by: ${GIT_USER}:${APP_USER}"
echo "Group permissions: read+write+execute"
echo "Setgid on directories: enabled (new files inherit group)"
echo ""
echo "This allows:"
echo "  - ${GIT_USER} can run git operations (fetch, reset, checkout, etc.)"
echo "  - ${APP_USER} can run npm and pm2 operations"
echo "  - Both users can read/write files via group permissions"

