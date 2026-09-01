#!/usr/bin/env bash
# Step 0 - preflight for an Ubuntu VM. Read-only, except for /etc/sysctl.d/99-s2.conf (asks first).
# Every line shows the command that was run and what it returned, so a failure can be reproduced by hand.
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

problems=()
line() { printf '  %-5s %-28s %s\n' "$1" "$2" "$3"; }      # STATUS  CHECK  "command -> result"
ok()   { line ok   "$1" "$2"; }
wrn()  { line warn "$1" "$2"; }
bad()  { line FAIL "$1" "$2"; problems+=("$(printf '%-28s %s' "$1" "$2")"); }

log "Step 0: host checks"
arch=$(uname -m)
if [[ $arch == x86_64 ]]; then ok architecture "uname -m -> $arch"; else bad architecture "uname -m -> $arch (need x86_64; the vendor toolchain is amd64)"; fi

os_id=$(get_kv /etc/os-release ID || true); os_ver=$(get_kv /etc/os-release VERSION_ID || true)
if [[ $os_id == ubuntu || $os_id == debian ]]; then ok "OS" "/etc/os-release -> $os_id $os_ver"; else bad "OS" "/etc/os-release -> '$os_id' (need ubuntu/debian)"; fi

if (( BASH_VERSINFO[0] >= 4 )); then ok bash "bash --version -> $BASH_VERSION"; else bad bash "bash --version -> $BASH_VERSION (need 4+)"; fi

if [[ -t 0 && -t 1 && -n ${TERM:-} ]]; then ok "interactive terminal" "[[ -t 0 && -t 1 && -n \$TERM ]] -> TERM=$TERM"
else bad "interactive terminal" "[[ -t 0 && -t 1 && -n \$TERM ]] -> not a tty or TERM unset (run from a real shell, tmux recommended)"; fi

if [[ $EUID -eq 0 ]]; then ok sudo "id -u -> 0 (root, sudo not needed)"
elif sudo -n true 2>/dev/null; then ok sudo "sudo -n true -> ok (passwordless)"
elif sudo -v; then ok sudo "sudo -v -> ok (asked for a password)"
else bad sudo "sudo -v -> failed ($(id -un) needs sudo rights)"; fi

cpus=$(nproc); mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)
disk_gb=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
res="nproc; /proc/meminfo; df -BG / -> $cpus vCPU, $mem_gb GB RAM, $disk_gb GB free on / (want 8 / 32 / 150)"
if (( cpus < 8 || mem_gb < 30 || disk_gb < 150 )); then wrn resources "$res"; else ok resources "$res"; fi

if command -v fuser >/dev/null 2>&1; then
  if holder=$("${SUDO[@]}" fuser /var/lib/dpkg/lock-frontend 2>/dev/null); then
    bad "apt lock" "sudo fuser /var/lib/dpkg/lock-frontend -> held by pid${holder} (unattended-upgrades? wait, then re-run)"
  else
    ok "apt lock" "sudo fuser /var/lib/dpkg/lock-frontend -> free"
  fi
fi

if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  bad "docker (snap)" "snap list docker -> installed (remove it; kind needs docker-ce, which step 1 installs)"
fi
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok docker "docker info -> ok"
  else wrn docker "docker info -> $(docker info 2>&1 | head -n1 | cut -c1-70) (re-login after step 1 fixes the group)"; fi
else
  ok docker "command -v docker -> not installed yet (step 1 installs it)"
fi

log "Step 0: kernel limits"
needs_sysctl=0
want_sysctl() {   # want_sysctl KEY MIN
  local cur; cur=$(sysctl -n "$1" 2>/dev/null || echo 0)
  if (( cur >= $2 )); then ok "$1" "sysctl -n $1 -> $cur"; else line low "$1" "sysctl -n $1 -> $cur (want >= $2)"; needs_sysctl=1; fi
}
want_sysctl vm.max_map_count 262144
want_sysctl fs.inotify.max_user_watches 524288
want_sysctl fs.inotify.max_user_instances 512
if (( needs_sysctl )); then
  if confirm "Write /etc/sysctl.d/99-s2.conf with the values above and apply it now?"; then
    printf 'vm.max_map_count=262144\nfs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' > "$TMPD/99-s2.conf"
    if "${SUDO[@]}" install -m 0644 "$TMPD/99-s2.conf" /etc/sysctl.d/99-s2.conf && "${SUDO[@]}" sysctl -e -p /etc/sysctl.d/99-s2.conf >/dev/null; then
      ok sysctl "sudo sysctl -e -p /etc/sysctl.d/99-s2.conf -> applied and persisted"
    else
      bad sysctl "sudo sysctl -e -p /etc/sysctl.d/99-s2.conf -> failed (restricted VM/container?)"
    fi
  else
    bad sysctl "sysctl -> not applied (declined); Elasticsearch and kind need these values"
  fi
fi

log "Step 0: outbound connectivity (10 s per host)"
[[ -n ${https_proxy:-} ]] && info "proxy in effect: $https_proxy (from proxy.env or your shell)"
for host in packages.cloud.google.com download.docker.com registry-1.docker.io dl.k8s.io github.com \
            objects.githubusercontent.com kind.sigs.k8s.io get.helm.sh storage.googleapis.com oauth2.googleapis.com \
            us-central1-docker.pkg.dev; do
  if r=$(probe_host "$host"); then ok "reach $host" "$(printf "$PROBE_CMD" "$host") -> $r"
  else bad "reach $host" "$(printf "$PROBE_CMD" "$host") -> $r"; fi
done

echo
if (( ${#problems[@]} )); then
  printf 'Preflight: %s problem(s)\n' "${#problems[@]}"
  printf '  FAIL  %s\n' "${problems[@]}"
  printf '\nFix these and re-run. Blocked hosts: run "bash 99-netdiag.sh" to see whether it is DNS, a proxy, or user-vs-root.\n'
  exit 1
fi
log "Preflight passed"
next "./01-install-tools.sh"
