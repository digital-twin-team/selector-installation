#!/usr/bin/env bash
# Network diagnostic - explains why downloads fail: DNS, TCP, proxy, or user-vs-root. Read-only, nothing installed.
# Usage: bash 99-netdiag.sh [HOST...]        (default: every host the installer needs)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

hosts=("$@")
(( ${#hosts[@]} )) || hosts=(github.com objects.githubusercontent.com download.docker.com registry-1.docker.io dl.k8s.io
                            kind.sigs.k8s.io get.helm.sh packages.cloud.google.com storage.googleapis.com
                            oauth2.googleapis.com us-central1-docker.pkg.dev)

# apply proxy.env exactly like the step scripts do (KEY=VALUE, not sourced)
penv_lines=()
if [[ -f proxy.env ]]; then
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ $line =~ ^(http_proxy|https_proxy|no_proxy)=(.+)$ ]] || continue
    export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}" "${BASH_REMATCH[1]^^}=${BASH_REMATCH[2]}"
    penv_lines+=("$line")
  done < proxy.env
fi

probe() {   # probe HOST [env-u args...] -> "HTTP 200" or the curl failure reason, within 10 s
  local host=$1; shift
  local code err
  code=$(env "$@" curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$host/" 2>"$tmp/err")
  if [[ -n $code && $code != 000 ]]; then printf 'HTTP %s' "$code"; return; fi
  err=$(head -n1 "$tmp/err" | sed -E 's/^curl: //; s/ after [0-9]+ milliseconds//; s/\(https?:\/\/[^)]*\)//' | cut -c1-42)
  printf '%s' "${err:-no answer}"
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
have_sudo=0; [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null && have_sudo=1

printf '== who / where\n'
printf '  user: %s   host: %s   date: %s\n' "$(id -un)" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
printf '  nameservers: %s\n' "$( (grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ') )"

printf '\n== proxy settings that affect the scripts\n'
printf '  proxy.env: %s\n' "${penv_lines[*]:-(empty or absent)}"
printf '  your shell: %s\n' "$( (env | grep -iE '^(http|https|no)_proxy=' | tr '\n' ' ') || true)"
if (( have_sudo )); then printf '  under sudo: %s\n' "$( (sudo -n env 2>/dev/null | grep -iE '^(http|https|no)_proxy=' | tr '\n' ' ') || true)"; fi
printf '  /etc/environment: %s\n' "$( (grep -iE 'proxy' /etc/environment 2>/dev/null | tr '\n' ' ') || true)"
printf '  /etc/profile.d: %s\n' "$( (grep -ilE 'proxy' /etc/profile.d/* 2>/dev/null | tr '\n' ' ') || true)"
printf '  apt: %s\n' "$( (grep -rhiE 'proxy' /etc/apt/apt.conf.d/ /etc/apt/apt.conf 2>/dev/null | tr '\n' ' ') || true)"
printf '  ~/.curlrc: %s\n' "$( (grep -iE 'proxy' "$HOME/.curlrc" 2>/dev/null | tr '\n' ' ') || true)"
printf '  docker daemon: %s\n' "$( (grep -hiE 'proxy' /etc/systemd/system/docker.service.d/*.conf 2>/dev/null | tr '\n' ' ') || true)"

printf '\n== reachability (https://HOST/, 10 s each)\n'
printf '  %-32s %-16s %-30s %-30s %s\n' HOST DNS "AS YOU (scripts' view)" "DIRECT (proxy vars unset)" "VIA SUDO"
n_user_ok=0 n_direct_ok=0 n_sudo_ok=0 n_dns_fail=0
for h in "${hosts[@]}"; do
  dns=$(getent ahosts "$h" 2>/dev/null | awk 'NR==1 {print $1}'); dns=${dns:-FAIL}
  [[ $dns == FAIL ]] && n_dns_fail=$((n_dns_fail+1))
  user=$(probe "$h");                      [[ $user == HTTP* ]] && n_user_ok=$((n_user_ok+1))
  direct=$(probe "$h" -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY); [[ $direct == HTTP* ]] && n_direct_ok=$((n_direct_ok+1))
  if (( have_sudo )); then
    sudo=$(sudo -n curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$h/" 2>/dev/null); sudo=${sudo:-000}
    if [[ $sudo != 000 ]]; then sudo="HTTP $sudo"; n_sudo_ok=$((n_sudo_ok+1)); else sudo="no answer"; fi
  else
    sudo="(no passwordless sudo)"
  fi
  printf '  %-32s %-16s %-30s %-30s %s\n' "$h" "$dns" "$user" "$direct" "$sudo"
done

printf '\n== verdict\n'
total=${#hosts[@]}
if (( n_dns_fail == total )); then
  echo "  DNS does not resolve any of these names: name resolution is filtered or the resolver is unreachable. Ask for the resolver/allowlist to be fixed first."
elif (( n_user_ok == 0 && n_direct_ok > 0 )); then
  echo "  Direct access works but the scripts' view fails: a proxy setting is in the way (proxy.env or your shell). Clear it, or put the right proxy address in proxy.env."
elif (( n_user_ok == 0 && n_direct_ok == 0 && have_sudo && n_sudo_ok > 0 )); then
  echo "  Only root gets out. Root has a different network path (a proxy that applies under sudo, or per-user egress rules). Copy root's proxy settings (see above) into proxy.env."
elif (( n_user_ok == 0 && n_direct_ok == 0 )); then
  echo "  Nothing is reachable from this VM right now, with or without proxy. Egress is closed for these hosts (if github.com/docker.com worked earlier, the policy changed). Hand this output to the network team."
elif (( n_user_ok < total )); then
  echo "  Partial: $n_user_ok of $total hosts reachable as you. The failing ones must be allowlisted (or routed via the proxy in proxy.env)."
else
  echo "  All $total hosts reachable as you. Re-run step 1."
fi
