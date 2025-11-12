#!/usr/bin/env bash
# enum_server_apps.sh
# Enumerate server setup details and deployed applications with URLs, ports, and git repos.
# Usage: sudo ./enum_server_apps.sh [--output FILE]

set -euo pipefail
IFS=$'\n\t'

OUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) shift; OUT_FILE="$1"; shift ;;
    -h|--help) echo "Usage: $0 [--output FILE]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$OUT_FILE" ]]; then
  OUT_FILE="/tmp/server_enumeration_$(date +%Y%m%d_%H%M%S).txt"
fi

echof() { printf "%s\n" "$*" >> "$OUT_FILE"; }
echol() { printf "%s\n" "$*"; printf "%s\n" "$*" >> "$OUT_FILE"; }

start_section() { echol "\n===== $1 =====\n"; }

# Helper: run a command if available
have() { command -v "$1" >/dev/null 2>&1; }

# Collect basic system info
gather_system_info() {
  start_section "System Information"
  echof "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echof "Hostname: $(hostname -f 2>/dev/null || hostname)"
  if have lsb_release; then
    echof "OS: $(lsb_release -ds)"
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echof "OS: $NAME $VERSION" 
  else
    echof "OS: Unknown"
  fi
  echof "Kernel: $(uname -sr)"
  echof "Uptime: $(uptime -p)"
  if [[ -r /proc/cpuinfo ]]; then
    echof "CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  fi
  echof "Memory: $(free -h | awk '/^Mem:/ {print $2 " total, " $3 " used, " $4 " free"}')"
  echof "Disk: $(df -h --output=source,size,used,avail,target -x tmpfs -x devtmpfs | sed -n '1,6p' )"
}

# Network info
gather_network_info() {
  start_section "Network"
  if have ip; then
    echof "IP addresses:" 
    ip -brief addr show | awk '{print $1 " -> " $3}' | sed 's/\/.*//g' >> "$OUT_FILE"
  else
    echof "ifconfig output:" 
    if have ifconfig; then ifconfig >> "$OUT_FILE"; fi
  fi
  echof "Default route: $(ip route show default 2>/dev/null || echo 'none')"
}

# List listening sockets and map to processes
gather_listening_services() {
  start_section "Listening Services (ports -> process)"
  if have ss; then
    echof "Using: ss -tulpn"
    ss -tulpn 2>/dev/null | sed -n '1,200p' >> "$OUT_FILE"
  elif have netstat; then
    echof "Using: netstat -tulpn"
    netstat -tulpn 2>/dev/null >> "$OUT_FILE"
  else
    echof "No ss or netstat available to enumerate listening sockets"
  fi
}

# Parse nginx / apache vhosts for server_name/listen
gather_web_vhosts() {
  # Nginx
  if [[ -d /etc/nginx/sites-enabled ]] || [[ -d /etc/nginx/conf.d ]]; then
    start_section "Nginx Virtual Hosts"
    find /etc/nginx/sites-enabled /etc/nginx/conf.d -type f -name "*.conf" 2>/dev/null | while read -r f; do
      echof "File: $f"
      awk '/server\s*\{/,/\}/ {print}' "$f" | sed -n '1,200p' >> "$OUT_FILE"
      # Try to extract server_name and listen
      sn=$(awk '/server_name/ {for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' "$f" | sed 's/;//g' | tr -d '\n')
      if [[ -n "$sn" ]]; then echof "server_name: $sn"; fi
      li=$(awk '/listen/ {print $0}' "$f" | sed 's/;//g' | tr '\n' ',')
      if [[ -n "$li" ]]; then echof "listen: $li"; fi
      # Try to get root and check for git
      rootdir=$(awk '/root/ {gsub(/;$/,"",$0); print $2; exit}' "$f" || true)
      if [[ -n "$rootdir" && -d "$rootdir" ]]; then
        echof "root: $rootdir"
        if [[ -d "$rootdir/.git" ]]; then
          if have git; then
            url=$(git -C "$rootdir" remote get-url origin 2>/dev/null || true)
            if [[ -n "$url" ]]; then echof "git: $url"; fi
          fi
        fi
      fi
      echof "---"
    done
  fi

  # Apache
  if [[ -d /etc/apache2/sites-enabled ]]; then
    start_section "Apache Virtual Hosts"
    find /etc/apache2/sites-enabled -type f -name "*.conf" 2>/dev/null | while read -r f; do
      echof "File: $f"
      awk '/<VirtualHost/,/<\/VirtualHost>/ {print}' "$f" | sed -n '1,200p' >> "$OUT_FILE"
      sn=$(awk '/ServerName/ {print $2; exit}' "$f" || true)
      if [[ -n "$sn" ]]; then echof "ServerName: $sn"; fi
      li=$(awk '/<VirtualHost/ {print $0; exit}' "$f" || true)
      if [[ -n "$li" ]]; then echof "VirtualHost: $li"; fi
      rootdir=$(awk '/DocumentRoot/ {print $2; exit}' "$f" || true)
      if [[ -n "$rootdir" && -d "$rootdir" ]]; then
        echof "DocumentRoot: $rootdir"
        if [[ -d "$rootdir/.git" && $(have git; echo $?) -eq 0 ]]; then
          url=$(git -C "$rootdir" remote get-url origin 2>/dev/null || true)
          if [[ -n "$url" ]]; then echof "git: $url"; fi
        fi
      fi
      echof "---"
    done
  fi
}

# Docker info
gather_docker_info() {
  if have docker; then
    start_section "Docker Containers"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' | sed -n '1,200p' >> "$OUT_FILE"
    # Inspect containers for mounts or labels indicating source repo
    docker ps -q | while read -r cid; do
      name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#/##')
      echof "Container: $name"
      # ports
      docker port "$cid" 2>/dev/null >> "$OUT_FILE" || true
      # labels
      docker inspect --format '{{json .Config.Labels}}' "$cid" 2>/dev/null >> "$OUT_FILE" || true
      # mounts
      mounts=$(docker inspect --format '{{range .Mounts}}{{printf "%s:%s\n" .Source .Destination}}{{end}}' "$cid" 2>/dev/null || true)
      if [[ -n "$mounts" ]]; then
        echof "Mounts:"
        echof "$mounts"
        # For each host mount, check for .git
        echo "$mounts" | awk -F: '{print $1}' | sort -u | while read -r hostpath; do
          if [[ -d "$hostpath/.git" ]]; then
            if have git; then
              url=$(git -C "$hostpath" remote get-url origin 2>/dev/null || true)
              if [[ -n "$url" ]]; then echof "git in $hostpath: $url"; fi
            fi
          fi
        done
      fi
      echof "---"
    done
  fi
}

# systemd services that look like apps
gather_systemd_apps() {
  if have systemctl; then
    start_section "Systemd Services (running)"
    systemctl list-units --type=service --state=running --no-legend | awk '{print $1 " " $4}' | sed -n '1,200p' >> "$OUT_FILE"
    # Look for ExecStart for services that might be apps
    systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | while read -r s; do
      if echo "$s" | egrep -i 'node|gunicorn|uwsgi|pm2|app|web|django|flask' >/dev/null; then
        echof "Service: $s"
        es=$(systemctl show -p ExecStart "$s" 2>/dev/null || true)
        echof "$es"
        # Try to extract path and lookup git
        execline=$(echo "$es" | sed -n 's/^ExecStart=//p')
        if [[ -n "$execline" ]]; then
          # attempt to find a directory in execline
          for part in $execline; do
            if [[ -d "$part" ]]; then
              if [[ -d "$part/.git" && $(have git; echo $?) -eq 0 ]]; then
                url=$(git -C "$part" remote get-url origin 2>/dev/null || true)
                if [[ -n "$url" ]]; then echof "git: $url"; fi
              fi
            fi
          done
        fi
        echof "---"
      fi
    done
  fi
}

# Scan common deployment directories for git repos
scan_common_paths_for_git() {
  start_section "Discovered Git Repositories (common paths)"
  paths=(/var/www /srv /opt /home /usr/local/www /root)
  for p in "${paths[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -maxdepth 4 -type d -name .git 2>/dev/null | while read -r g; do
        repo_dir=$(dirname "$g")
        echof "Repo path: $repo_dir"
        if have git; then
          url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
          if [[ -n "$url" ]]; then echof "git: $url"; fi
        fi
        echof "---"
      done
    fi
  done
}

# Map listening ports to git repos by inspecting process cwd
map_ports_to_repos() {
  start_section "Map Listening Ports -> Likely App Repositories"
  # Read ss output lines and parse pid
  if have ss; then
    ss -tulpn 2>/dev/null | sed 1d | while read -r line; do
      # try to extract local address and pid/program
      proto=$(echo "$line" | awk '{print $1}')
      local=$(echo "$line" | awk '{print $5}')
      prog=$(echo "$line" | sed -n '1p' | awk -F"pid=" '{print $2}' | awk -F"," '{print $1}' || true)
      if [[ -n "$prog" ]]; then
        pid=$(echo "$prog" | awk -F"/" '{print $1}')
        pname=$(echo "$prog" | awk -F"/" '{print $2}')
        echof "$local -> PID:$pid ($pname)"
        if [[ -d "/proc/$pid/cwd" ]]; then
          cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null || true)
          if [[ -n "$cwd" ]]; then
            echof "  cwd: $cwd"
            if [[ -d "$cwd/.git" && $(have git; echo $?) -eq 0 ]]; then
              url=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
              if [[ -n "$url" ]]; then echof "  git: $url"; fi
            fi
          fi
        fi
      fi
    done >> "$OUT_FILE"
  fi
}

# Main
main() {
  printf "Server enumeration report will be written to %s\n" "$OUT_FILE"
  : > "$OUT_FILE"
  gather_system_info
  gather_network_info
  gather_listening_services
  gather_web_vhosts
  gather_docker_info
  gather_systemd_apps
  scan_common_paths_for_git
  map_ports_to_repos
  printf "Report complete: %s\n" "$OUT_FILE"
}

main