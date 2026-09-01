#!/usr/bin/env bash
# Step 0 - preflight for an Ubuntu VM. Read-only, except for /etc/sysctl.d/99-s2.conf (asks first).
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }

problems=()
ok()  { info "ok    $*"; }
bad() { info "FAIL  $*"; problems+=("$*"); }

log "Step 0: host checks"

arch=$(uname -m)
if [[ $arch == x86_64 ]]; then ok "architecture $arch"; else bad "architecture is $arch; the vendor toolchain is only exercised on x86_64"; fi

os_id=$(get_kv /etc/os-release ID || true); os_ver=$(get_kv /etc/os-release VERSION_ID || true)
if [[ $os_id == ubuntu || $os_id == debian ]]; then ok "$os_id $os_ver"; else bad "OS is '$os_id'; 01-install-tools.sh supports Ubuntu/Debian"; fi

if (( BASH_VERSINFO[0] >= 4 )); then ok "bash $BASH_VERSION"; else bad "bash 4+ required"; fi

if [[ -t 0 && -t 1 && -n ${TERM:-} ]]; then ok "interactive terminal (TERM=$TERM)"; else bad "not an interactive terminal; run the steps from a real shell (tmux/screen recommended)"; fi

if [[ $EUID -eq 0 ]]; then
  ok "running as root (sudo not needed)"
elif sudo -n true 2>/dev/null || sudo -v; then
  ok "sudo works for $(id -un)"
else
  bad "sudo is required for the install steps"
fi

mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)
cpus=$(nproc)
disk_gb=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
info "resources: ${cpus} vCPU, ${mem_gb} GB RAM, ${disk_gb} GB free on /"
(( mem_gb < 30 )) && warn "less than 32 GB RAM; confirm the vendor's sizing before continuing"
(( cpus < 8 )) && warn "fewer than 8 vCPUs; confirm the vendor's sizing before continuing"
(( disk_gb < 150 )) && warn "less than 150 GB free on /; Docker images and /var/selector/storage both live here"

if command -v fuser >/dev/null 2>&1 && "${SUDO[@]}" fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  bad "apt/dpkg lock is held (unattended-upgrades on a fresh VM?); wait for it to finish and re-run"
else
  ok "apt is not locked"
fi

if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  bad "Docker is installed via snap; kind's host mounts fail with it. Remove it and let 01-install-tools.sh install docker-ce"
fi
if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
  warn "docker is installed but not usable from this shell (group membership or service); step 1 handles the install, re-login handles the group"
fi

log "Step 0: kernel limits"
needs_sysctl=0
want_sysctl() {   # want_sysctl KEY MIN
  local cur; cur=$(sysctl -n "$1" 2>/dev/null || echo 0)
  if (( cur >= $2 )); then ok "$1=$cur"; else info "low   $1=$cur (want >= $2)"; needs_sysctl=1; fi
}
want_sysctl vm.max_map_count 262144
want_sysctl fs.inotify.max_user_watches 524288
want_sysctl fs.inotify.max_user_instances 512
if (( needs_sysctl )); then
  if confirm "Write /etc/sysctl.d/99-s2.conf with the values above and apply it now?"; then
    printf 'vm.max_map_count=262144\nfs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' \
      | "${SUDO[@]}" tee /etc/sysctl.d/99-s2.conf >/dev/null
    if "${SUDO[@]}" sysctl -e -p /etc/sysctl.d/99-s2.conf >/dev/null; then
      ok "sysctls applied (persisted in /etc/sysctl.d/99-s2.conf)"
    else
      bad "could not apply the sysctls (containers/restricted VMs may not allow it)"
    fi
  else
    problems+=("kernel sysctls not applied")
  fi
fi

log "Step 0: outbound connectivity"
[[ -n ${https_proxy:-} ]] && info "using proxy from proxy.env: $https_proxy"
for host in packages.cloud.google.com download.docker.com registry-1.docker.io dl.k8s.io github.com \
            objects.githubusercontent.com kind.sigs.k8s.io get.helm.sh storage.googleapis.com oauth2.googleapis.com \
            us-central1-docker.pkg.dev; do
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$host/" 2>/dev/null || true)
  if [[ -n $code && $code != 000 ]]; then ok "$host (HTTP $code)"; else bad "cannot reach https://$host"; fi
done

echo
if (( ${#problems[@]} )); then
  printf '%s\n' "Preflight found ${#problems[@]} problem(s):" "${problems[@]/#/  - }"
  exit 1
fi
log "Preflight passed"
next "./01-install-tools.sh"
