#!/usr/bin/env bash
# Runs steps 0-7 in order and stops at the first failure. Resume with:  ./install-all.sh --from N
# Each step is idempotent, so re-running a finished step is harmless.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f lib/common.sh ]] || { echo "ERROR: lib/common.sh is missing next to the step scripts (unpack the tarball, or mkdir lib && mv common.sh lib/)" >&2; exit 1; }

from=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --from) from=$2; shift 2 ;;
    -h|--help) echo "usage: $0 [--from N]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

steps=(00-preflight.sh 01-install-tools.sh 02-configure.sh 03-download-specs.sh
       04-create-kind-cluster.sh 05-prepare-cluster.sh 06-deploy-apps.sh 07-deploy-s2ap.sh)

for step in "${steps[@]}"; do
  n=$(( 10#${step%%-*} ))
  (( n < from )) && continue
  printf '\n################ %s ################\n' "$step"
  bash "./$step"
  if [[ $step == 01-install-tools.sh ]] && command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    cat <<EOF

Docker is installed but this shell cannot use it yet (new 'docker' group membership).
Log out, log back in, then resume with:   $0 --from 2
EOF
    exit 2
  fi
done

printf '\nAll steps finished. Optional: ./08-fetch-s2ctl-tools.sh\n'
