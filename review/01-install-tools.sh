#!/usr/bin/env bash
# Step 1 - install the toolset on Ubuntu/Debian: apt packages, gcloud CLI, Docker, and the pinned
# kubectl/kind/kustomize/helm/spruce/yaml2json/yq binaries from versions.env.
# Downloads go to a private temp dir, are checksum-verified where the publisher ships checksums, and are
# installed root-owned with `install`. Re-running is safe: tools already at the pinned version are skipped.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_versions

BINARIES_ONLY=0   # --binaries-only: skip apt/gcloud/docker, only (re)install the pinned binaries
while [[ $# -gt 0 ]]; do
  case $1 in
    --binaries-only) BINARIES_ONLY=1; shift ;;
    *) die "unknown argument: $1 (usage: $0 [--binaries-only])" ;;
  esac
done

BIN_DIR="${S2_BIN_DIR:-$(get_kv "$S2CTL_CONFIG" s2_bin_dir 2>/dev/null || echo /usr/local/bin)}"
REMOTE="${S2_REMOTE_INSTALLATION:-$(get_kv "$S2CTL_CONFIG" s2_remote_installation 2>/dev/null || echo N)}"
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

if (( BINARIES_ONLY )); then
  info "--binaries-only: skipping apt packages, gcloud and Docker"
  DOCKER_GROUP_ADDED=0
else
log "Step 1: apt packages"
"${SUDO[@]}" apt-get update -q
"${SUDO[@]}" apt-get install -y -q apt-transport-https ca-certificates gnupg sed tar gawk jq curl lsb-release git coreutils

log "Step 1: gcloud CLI"
if command -v gcloud >/dev/null 2>&1; then
  info "present: $(gcloud version 2>/dev/null | head -n1)"
else
  fetch https://packages.cloud.google.com/apt/doc/apt-key.gpg "$TMPD/gcloud.gpg"
  "${SUDO[@]}" gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg "$TMPD/gcloud.gpg"
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  "${SUDO[@]}" apt-get update -q
  "${SUDO[@]}" apt-get install -y -q google-cloud-cli
fi

log "Step 1: Docker"
DOCKER_GROUP_ADDED=0
if [[ $REMOTE == Y ]]; then
  info "remote installation: Docker and kind are not needed on this host"
elif command -v docker >/dev/null 2>&1; then
  info "present: $(docker --version)"
else
  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  fetch "https://download.docker.com/linux/$OS_ID/gpg" "$TMPD/docker.asc"
  "${SUDO[@]}" install -m 0644 "$TMPD/docker.asc" /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $CODENAME stable" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null
  "${SUDO[@]}" apt-get update -q
  "${SUDO[@]}" apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  "${SUDO[@]}" usermod -aG docker "$(id -un)"
  DOCKER_GROUP_ADDED=1
fi
fi

log "Step 1: pinned binaries -> $BIN_DIR"
installed_version() {
  case $1 in
    kubectl)   kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' ;;
    kind)      kind version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    kustomize) kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yq)        yq --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    spruce)    spruce --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yaml2json) yaml2json -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    helm)      helm version --template '{{.Version}}' 2>/dev/null ;;
  esac || true
}
needs() {   # needs TOOL WANTED -> 0 when a (re)install is required
  local have; have=$(installed_version "$1")
  if [[ $have == "$2" ]]; then info "$1 $2 already installed"; return 1; fi
  info "$1: have '${have:-none}', want $2"
}
install_bin() { "${SUDO[@]}" install -o root -g root -m 0755 "$1" "$BIN_DIR/$2"; info "installed $BIN_DIR/$2"; }

"${SUDO[@]}" install -d -m 0755 "$BIN_DIR"

if needs kubectl "$KUBECTL_VERSION"; then
  url="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  fetch "$url" "$TMPD/kubectl"; fetch "$url.sha256" "$TMPD/kubectl.sha256"
  verify_sha256 "$TMPD/kubectl" "$(first_sha256_in "$TMPD/kubectl.sha256")" kubectl
  install_bin "$TMPD/kubectl" kubectl
fi

if [[ $REMOTE != Y ]] && needs kind "$KIND_VERSION"; then
  url="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
  fetch "$url" "$TMPD/kind"; fetch "$url.sha256sum" "$TMPD/kind.sha256sum"
  verify_sha256 "$TMPD/kind" "$(first_sha256_in "$TMPD/kind.sha256sum")" kind
  install_bin "$TMPD/kind" kind
fi

if needs kustomize "$KUSTOMIZE_VERSION"; then
  base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$KUSTOMIZE_VERSION"
  f="kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
  fetch "$base/$f" "$TMPD/$f"; fetch "$base/checksums.txt" "$TMPD/kustomize.checksums"
  verify_sha256 "$TMPD/$f" "$(awk -v f="$f" '$2 == f { print $1 }' "$TMPD/kustomize.checksums")" kustomize
  tar -xzf "$TMPD/$f" -C "$TMPD" kustomize
  install_bin "$TMPD/kustomize" kustomize
fi

if needs helm "$HELM_VERSION"; then
  f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://get.helm.sh/$f" "$TMPD/$f"; fetch "https://get.helm.sh/$f.sha256sum" "$TMPD/helm.sha256sum"
  verify_sha256 "$TMPD/$f" "$(first_sha256_in "$TMPD/helm.sha256sum")" helm
  tar -xzf "$TMPD/$f" -C "$TMPD" "linux-$ARCH/helm"
  install_bin "$TMPD/linux-$ARCH/helm" helm
fi

if needs spruce "$SPRUCE_VERSION"; then
  fetch "https://github.com/geofffranks/spruce/releases/download/v$SPRUCE_VERSION/spruce-linux-$ARCH" "$TMPD/spruce"
  verify_sha256 "$TMPD/spruce" "$SPRUCE_SHA256" spruce
  install_bin "$TMPD/spruce" spruce
fi

if needs yaml2json "$YAML2JSON_VERSION"; then
  fetch "https://github.com/wakeful/yaml2json/releases/download/$YAML2JSON_VERSION/yaml2json-linux-$ARCH" "$TMPD/yaml2json"
  verify_sha256 "$TMPD/yaml2json" "$YAML2JSON_SHA256" yaml2json
  install_bin "$TMPD/yaml2json" yaml2json
fi

if needs yq "$YQ_VERSION"; then
  fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" "$TMPD/yq"
  verify_sha256 "$TMPD/yq" "$YQ_SHA256" yq
  install_bin "$TMPD/yq" yq
fi

log "Step 1: installed"
for t in kubectl kind kustomize helm spruce yaml2json yq; do
  if command -v "$t" >/dev/null 2>&1; then info "$t $(installed_version "$t")"; else info "$t not installed"; fi
done
info "gcloud $(gcloud version 2>/dev/null | head -n1 || echo missing)"
info "docker $(docker --version 2>/dev/null || echo 'not installed (remote install)')"

if (( DOCKER_GROUP_ADDED )); then
  echo
  warn "you were just added to the 'docker' group. Log out and back in (or run: newgrp docker) before step 4."
fi
next "./02-configure.sh"
