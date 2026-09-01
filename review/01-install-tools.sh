#!/usr/bin/env bash
# Step 1 - install the toolset on Ubuntu/Debian: apt packages, gcloud CLI, Docker, and the pinned
# kubectl/kind/kustomize/helm/spruce/yaml2json/yq binaries from versions.env.
#
# Best-effort: each tool is installed in its own section with timeouts. A tool whose download host is blocked,
# or whose install fails, is skipped and the script moves on to the next one. The end prints a summary of what is
# installed, what is not (and why) and which hosts could not be reached, and writes the same summary to
# ~/.s2ctl/install-report.txt. Exit status is 1 when anything is missing, so install-all.sh stops here.
#
# Usage: 01-install-tools.sh [--binaries-only]
#   env: S2_SKIP_GCLOUD=Y   don't install gcloud (step 3 then needs a local specs tarball, see README)
#        S2_PROBE_SKIP=Y    try every download even if the reachability probe says the host is blocked
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
load_versions

BINARIES_ONLY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --binaries-only) BINARIES_ONLY=1; shift ;;
    *) die "unknown argument: $1 (usage: $0 [--binaries-only])" ;;
  esac
done

BIN_DIR="${S2_BIN_DIR:-$(get_kv "$S2CTL_CONFIG" s2_bin_dir 2>/dev/null || echo /usr/local/bin)}"
REMOTE="${S2_REMOTE_INSTALLATION:-$(get_kv "$S2CTL_CONFIG" s2_remote_installation 2>/dev/null || echo N)}"
SKIP_GCLOUD=${S2_SKIP_GCLOUD:-N}
REPORT="$S2CTL_DIR/install-report.txt"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64; warn "arm64 is untested with the vendor specs" ;;
  *)       die "unsupported architecture: $(uname -m)" ;;
esac
OS_ID=$(get_kv /etc/os-release ID || true)
[[ $OS_ID == ubuntu || $OS_ID == debian ]] || die "this step supports Ubuntu/Debian (got '$OS_ID')"
CODENAME=$(get_kv /etc/os-release UBUNTU_CODENAME || get_kv /etc/os-release VERSION_CODENAME || true)
[[ -n $CODENAME ]] || die "cannot determine the release codename from /etc/os-release"

# ---------------------------------------------------------------- what each tool needs
TOOLS=(apt gcloud docker kubectl kind kustomize helm spruce yaml2json yq)
declare -A TOOL_HOSTS=(
  [gcloud]="packages.cloud.google.com" [docker]="download.docker.com" [kubectl]="dl.k8s.io"
  [kind]="kind.sigs.k8s.io" [helm]="get.helm.sh"
  [kustomize]="github.com objects.githubusercontent.com" [spruce]="github.com objects.githubusercontent.com"
  [yaml2json]="github.com objects.githubusercontent.com" [yq]="github.com objects.githubusercontent.com"
)
declare -A TOOL_WANT=(
  [kubectl]=$KUBECTL_VERSION [kind]=$KIND_VERSION [kustomize]=$KUSTOMIZE_VERSION [helm]=$HELM_VERSION
  [spruce]=$SPRUCE_VERSION [yaml2json]=$YAML2JSON_VERSION [yq]=$YQ_VERSION
)
declare -A CHECK_CMD=(
  [gcloud]="gcloud version" [docker]="docker --version" [kubectl]="kubectl version --client" [kind]="kind version"
  [kustomize]="kustomize version" [helm]="helm version --template {{.Version}}" [spruce]="spruce --version"
  [yaml2json]="yaml2json -version" [yq]="yq --version"
)
declare -A TOOL_URL=(
  [gcloud]="https://packages.cloud.google.com/apt (apt repo) + https://packages.cloud.google.com/apt/doc/apt-key.gpg"
  [docker]="https://download.docker.com/linux/$OS_ID (apt repo) + https://download.docker.com/linux/$OS_ID/gpg"
  [kubectl]="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl (+ .sha256)"
  [kind]="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH (+ .sha256sum)"
  [kustomize]="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz (+ checksums.txt)"
  [helm]="https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz (+ .sha256sum)"
  [spruce]="https://github.com/geofffranks/spruce/releases/download/v$SPRUCE_VERSION/spruce-linux-$ARCH"
  [yaml2json]="https://github.com/wakeful/yaml2json/releases/download/$YAML2JSON_VERSION/yaml2json-linux-$ARCH"
  [yq]="https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH"
)
declare -A WHY=()       # tool -> "COMMAND -> reason" it is not installed
declare -A BLOCKED=()   # host -> 1 when the probe could not reach it
declare -A PROBE_RESULT=()   # host -> "HTTP 200" or the curl failure reason

installed_version() {
  case $1 in
    gcloud)    gcloud version 2>/dev/null | head -n1 ;;
    docker)    docker --version 2>/dev/null ;;
    kubectl)   kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    kind)      kind version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    kustomize) kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yq)        yq --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    spruce)    spruce --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yaml2json) yaml2json -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    helm)      helm version --template '{{.Version}}' 2>/dev/null ;;
  esac || true
}

# tool_state TOOL -> "skip <reason>" | "ok" (already there) | "todo"
tool_state() {
  case $1 in
    apt)    (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }; echo todo ;;
    gcloud) (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }
            [[ $SKIP_GCLOUD == Y ]] && { echo "skip S2_SKIP_GCLOUD=Y"; return; }
            command -v gcloud >/dev/null 2>&1 && echo ok || echo todo ;;
    docker) (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }
            [[ $REMOTE == Y ]] && { echo "skip remote install"; return; }
            command -v docker >/dev/null 2>&1 && echo ok || echo todo ;;
    kind)   [[ $REMOTE == Y ]] && { echo "skip remote install"; return; }
            [[ $(installed_version kind) == "${TOOL_WANT[kind]}" ]] && echo ok || echo todo ;;
    *)      [[ $(installed_version "$1") == "${TOOL_WANT[$1]}" ]] && echo ok || echo todo ;;
  esac
}

# ---------------------------------------------------------------- sections (each runs in a subshell; a failure
# inside only aborts that section)
install_bin() { try "${SUDO[@]}" install -o root -g root -m 0755 "$1" "$BIN_DIR/$2"; info "installed $BIN_DIR/$2"; }

section_apt() {
  # a previous failed run may have left half-written repo files behind; drop the ones this step recreates
  command -v gcloud >/dev/null 2>&1 || try "${SUDO[@]}" rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
  command -v docker >/dev/null 2>&1 || try "${SUDO[@]}" rm -f /etc/apt/sources.list.d/docker.list
  try "${SUDO[@]}" timeout 300 apt-get update -q
  try "${SUDO[@]}" timeout 900 apt-get install -y -q apt-transport-https ca-certificates gnupg sed tar gawk jq curl lsb-release git coreutils
}

section_gcloud() {
  fetch https://packages.cloud.google.com/apt/doc/apt-key.gpg "$TMPD/gcloud.gpg"
  try "${SUDO[@]}" gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg "$TMPD/gcloud.gpg"
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > "$TMPD/google-cloud-sdk.list"
  try "${SUDO[@]}" install -m 0644 "$TMPD/google-cloud-sdk.list" /etc/apt/sources.list.d/google-cloud-sdk.list
  try "${SUDO[@]}" timeout 300 apt-get update -q
  try "${SUDO[@]}" timeout 900 apt-get install -y -q google-cloud-cli
}

section_docker() {
  try "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  fetch "https://download.docker.com/linux/$OS_ID/gpg" "$TMPD/docker.asc"
  try "${SUDO[@]}" install -m 0644 "$TMPD/docker.asc" /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $CODENAME stable" > "$TMPD/docker.list"
  try "${SUDO[@]}" install -m 0644 "$TMPD/docker.list" /etc/apt/sources.list.d/docker.list
  try "${SUDO[@]}" timeout 300 apt-get update -q
  try "${SUDO[@]}" timeout 900 apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  try "${SUDO[@]}" usermod -aG docker "$(id -un)"
}

section_kubectl() {
  local url="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  fetch "$url" "$TMPD/kubectl"; fetch "$url.sha256" "$TMPD/kubectl.sha256"
  verify_sha256 "$TMPD/kubectl" "$(first_sha256_in "$TMPD/kubectl.sha256")" kubectl
  install_bin "$TMPD/kubectl" kubectl
}

section_kind() {
  local url="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
  fetch "$url" "$TMPD/kind"; fetch "$url.sha256sum" "$TMPD/kind.sha256sum"
  verify_sha256 "$TMPD/kind" "$(first_sha256_in "$TMPD/kind.sha256sum")" kind
  install_bin "$TMPD/kind" kind
}

section_kustomize() {
  local base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$KUSTOMIZE_VERSION"
  local f="kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
  fetch "$base/$f" "$TMPD/$f"; fetch "$base/checksums.txt" "$TMPD/kustomize.checksums"
  verify_sha256 "$TMPD/$f" "$(awk -v f="$f" '$2 == f { print $1 }' "$TMPD/kustomize.checksums")" kustomize
  tar -xzf "$TMPD/$f" -C "$TMPD" kustomize
  install_bin "$TMPD/kustomize" kustomize
}

section_helm() {
  local f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://get.helm.sh/$f" "$TMPD/$f"; fetch "https://get.helm.sh/$f.sha256sum" "$TMPD/helm.sha256sum"
  verify_sha256 "$TMPD/$f" "$(first_sha256_in "$TMPD/helm.sha256sum")" helm
  tar -xzf "$TMPD/$f" -C "$TMPD" "linux-$ARCH/helm"
  install_bin "$TMPD/linux-$ARCH/helm" helm
}

section_spruce() {
  fetch "https://github.com/geofffranks/spruce/releases/download/v$SPRUCE_VERSION/spruce-linux-$ARCH" "$TMPD/spruce"
  verify_sha256 "$TMPD/spruce" "$SPRUCE_SHA256" spruce
  install_bin "$TMPD/spruce" spruce
}

section_yaml2json() {
  fetch "https://github.com/wakeful/yaml2json/releases/download/$YAML2JSON_VERSION/yaml2json-linux-$ARCH" "$TMPD/yaml2json"
  verify_sha256 "$TMPD/yaml2json" "$YAML2JSON_SHA256" yaml2json
  install_bin "$TMPD/yaml2json" yaml2json
}

section_yq() {
  fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" "$TMPD/yq"
  verify_sha256 "$TMPD/yq" "$YQ_SHA256" yq
  install_bin "$TMPD/yq" yq
}

# ---------------------------------------------------------------- probe the hosts this run needs (in parallel)
declare -A STATE=()
for t in "${TOOLS[@]}"; do STATE[$t]=$(tool_state "$t"); done

hosts=()
for t in "${TOOLS[@]}"; do
  [[ ${STATE[$t]} == todo ]] || continue
  for h in ${TOOL_HOSTS[$t]:-}; do
    printf '%s\n' "${hosts[@]:-}" | grep -qx "$h" || hosts+=("$h")
  done
done
if (( ${#hosts[@]} )); then
  log "Step 1: probing ${#hosts[@]} download host(s), 10 s each, in parallel"
  info "proxy in effect: ${https_proxy:-none} (from proxy.env or your shell)"
  for h in "${hosts[@]}"; do ( if probe_host "$h" > "$TMPD/probe.$h"; then touch "$TMPD/$h.ok"; fi ) & done
  wait
  for h in "${hosts[@]}"; do
    PROBE_RESULT[$h]=$(cat "$TMPD/probe.$h" 2>/dev/null || echo "no answer")
    if [[ -f $TMPD/$h.ok ]]; then info "ok      $(printf "$PROBE_CMD" "$h") -> ${PROBE_RESULT[$h]}"
    else info "BLOCKED $(printf "$PROBE_CMD" "$h") -> ${PROBE_RESULT[$h]}"; BLOCKED[$h]=1; fi
  done
fi

# ---------------------------------------------------------------- run the sections, never stopping on one
run_section() {   # run_section TOOL
  local tool=$1 h
  rm -f "$TMPD/last-fail"
  case ${STATE[$tool]} in
    skip*) info "$tool: skipped (${STATE[$tool]#skip })"; return 0 ;;
    ok)    info "$tool: already installed -> ${CHECK_CMD[$tool]:-} -> $(installed_version "$tool")"; return 0 ;;
  esac
  for h in ${TOOL_HOSTS[$tool]:-}; do
    if [[ -n ${BLOCKED[$h]:-} && ${S2_PROBE_SKIP:-N} != Y ]]; then
      WHY[$tool]="$(printf "$PROBE_CMD" "$h") -> ${PROBE_RESULT[$h]}"
      warn "$tool: skipped, host blocked: ${WHY[$tool]}"; return 0
    fi
  done
  # run the section in a subshell with errexit switched on *inside* it (bash ignores -e for a subshell that sits
  # in an if/|| condition, which would let a failed download slip through)
  local rc
  set +e
  ( set -e; "section_$tool" )
  rc=$?
  set -e
  if (( rc == 0 )); then
    info "$tool: done -> ${CHECK_CMD[$tool]:-} -> $(installed_version "$tool")"
  else
    WHY[$tool]=$(cat "$TMPD/last-fail" 2>/dev/null || echo "install failed (see the messages above)")
    warn "$tool: failed, moving on: ${WHY[$tool]}"
  fi
}

had_docker=$(command -v docker 2>/dev/null || true)
for t in "${TOOLS[@]}"; do
  log "Step 1: $t"
  run_section "$t"
done

if [[ -z $had_docker ]] && command -v docker >/dev/null 2>&1; then DOCKER_GROUP_ADDED=1; else DOCKER_GROUP_ADDED=0; fi
proxy_https=${https_proxy:-${HTTPS_PROXY:-}}
if (( ! BINARIES_ONLY )) && [[ -n $proxy_https && $REMOTE != Y ]] && command -v docker >/dev/null 2>&1; then
  "${SUDO[@]}" install -d -m 0755 /etc/systemd/system/docker.service.d
  printf '[Service]\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="HTTP_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
    "$proxy_https" "${http_proxy:-${HTTP_PROXY:-$proxy_https}}" "${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}" \
    | "${SUDO[@]}" tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
  "${SUDO[@]}" systemctl daemon-reload && "${SUDO[@]}" systemctl restart docker || warn "could not restart docker with the proxy drop-in"
fi

# ---------------------------------------------------------------- summary (screen + ~/.s2ctl/install-report.txt)
summary() {
  local t v state
  printf 'Step 1 summary  %s  host %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)"
  for t in "${TOOLS[@]}"; do
    [[ $t == apt ]] && continue
    state=${STATE[$t]}
    v=$(installed_version "$t")
    if [[ $state == skip* ]]; then
      printf '%-10s skipped (%s)\n' "$t" "${state#skip }"
    elif [[ -n ${WHY[$t]:-} ]]; then
      if [[ -n $v ]]; then printf '%-10s WRONG VERSION  have %s, want %s\n' "$t" "$v" "${TOOL_WANT[$t]:-?}"
      else printf '%-10s NOT INSTALLED\n' "$t"; fi
      printf '%-10s failed:  %s\n' '' "${WHY[$t]}"
      printf '%-10s needs:   %s\n' '' "${TOOL_URL[$t]:-?}"
    elif [[ -n $v ]]; then
      printf '%-10s installed      %s\n' "$t" "$v"
      printf '%-10s works:   %s -> %s\n' '' "${CHECK_CMD[$t]:-}" "$v"
    else
      printf '%-10s NOT INSTALLED\n%-10s check:   %s -> command not found\n' "$t" '' "${CHECK_CMD[$t]:-}"
    fi
  done
  [[ -n ${WHY[apt]:-} ]] && printf '\napt packages failed:  %s\n' "${WHY[apt]}"
  if (( ${#PROBE_RESULT[@]} )); then
    printf '\nHOSTS PROBED  (%s)\n' "$(printf "$PROBE_CMD" HOST)"
    for h in "${!PROBE_RESULT[@]}"; do
      if [[ -n ${BLOCKED[$h]:-} ]]; then printf '  BLOCKED  %-32s %s\n' "$h" "${PROBE_RESULT[$h]}"; else printf '  ok       %-32s %s\n' "$h" "${PROBE_RESULT[$h]}"; fi
    done | sort
    (( ${#BLOCKED[@]} )) && printf '  -> blocked hosts must be opened on 443 (or routed via proxy.env); run "bash 99-netdiag.sh" for DNS/proxy/user-vs-root detail\n'
  else
    printf '\nNo downloads were needed, so no hosts were probed.\n'
  fi
  (( DOCKER_GROUP_ADDED )) && printf '\nDocker was installed and you were added to the docker group: log out and back in before step 4.\n'
  return 0
}

log "Step 1: summary"
summary | tee "$TMPD/summary.txt"
install -d -m 0700 "$S2CTL_DIR" && install -m 0600 "$TMPD/summary.txt" "$REPORT" && info "(saved to $REPORT)"

if (( ${#WHY[@]} )); then
  warn "${#WHY[@]} item(s) missing; fix the network (or versions.env) and re-run this step. Already-installed tools are skipped."
  (( ${#BLOCKED[@]} )) && warn "to see whether it is DNS, a proxy, or user-vs-root, run:  bash 99-netdiag.sh"
  exit 1
fi
next "./02-configure.sh"
