# s2 step-by-step installer (Ubuntu VM)

The vendor's `s2ctl.sh install` split into one script per stage. Every step is idempotent and can be re-run
on its own; `install-all.sh` chains them and `--from N` resumes after a fix.

| Step | Script | What it does |
|------|--------|--------------|
| 0 | `00-preflight.sh` | Arch/OS/sudo/terminal checks, RAM/disk/CPU report, apt lock, snap-docker check, kernel sysctls (asks before writing), outbound reachability. |
| 1 | `01-install-tools.sh` | apt packages, gcloud CLI, docker-ce (adds you to the `docker` group), pinned kubectl/kind/kustomize/helm/spruce/yaml2json/yq with checksum verification. |
| 2 | `02-configure.sh` | Key paths, deploy dir, FQDN and overrides -> `~/.s2ctl/config` (0600). Copies the GCP key to the path the kind node mounts. For remote installs, isolates the target context into `~/.s2ctl/kubeconfig`. |
| 3 | `03-download-specs.sh` | Service-account login, downloads and extracts the specs tarball from the vendor bucket, applies `S2_INSTANCE` / `S2_NAME` / FQDN ingress-domain overrides to `config.properties`. |
| 4 | `04-create-kind-cluster.sh` | Host directories from the vendor kind config, `kind create cluster`, dedicated kubeconfig. Skipped for remote installs. |
| 5 | `05-prepare-cluster.sh` | Verifies the target cluster (typed confirmation if it already runs a different deployment), namespaces, GPG key secret, registry pull secret per namespace, optional CoreDNS config. |
| 6 | `06-deploy-apps.sh` | Platform apps in the vendor's order with the vendor's special cases. `--list`, `--only APP`, `--from APP`, `--timeout SEC`. |
| 7 | `07-deploy-s2ap.sh` | Applies s2ap and waits (`--wait MIN`, default 30). |
| 8 | `08-fetch-s2ctl-tools.sh` | Optional. Pulls the `s2ctl` binary, `get_reports.py` and the s2ml specs out of the running deployment (what `s2ctl.sh gets2mspecs` does). |

## Before you start

1. `x86_64` Ubuntu 22.04/24.04 VM, a sudo-capable user, run everything from `tmux` (an SSH drop mid-install kills the step).
2. Vendor files: the service-account JSON key and the GPG key manifest. Defaults are `~/.s2ctl/gcp.json` and `~/.s2ctl/gpg.yaml`.
3. Inbound 80/443 open, and four DNS records pointing at the VM for `<fqdn>`, `<name>-mon.<domain>`, `<name>-engine.<domain>`, `<name>-registry.<domain>` (step 2 prints them).
4. Outbound access to the hosts step 0 checks, plus `charts.releases.teleport.dev` / `selector.teleport.sh:443` if you will run the vendor's `teleport` command later.

## Run it

```bash
chmod +x *.sh
./install-all.sh            # stops after step 1 if you were just added to the docker group
# log out, log back in
./install-all.sh --from 2
```

Or run the numbered scripts one at a time; each one prints what to run next. Environment knobs:

- `S2_NONINTERACTIVE=Y` accepts defaults/environment values in step 2 without prompting; `YES_TO_ALL=Y` answers the yes/no prompts (never the typed "wrong cluster" confirmation).
- `S2_GCP_KEY`, `S2_GPG_KEY`, `S2_DEPLOY_DIR`, `S2_FQDN`, `S2_NAME`, `S2_INSTANCE`, `S2_REMOTE_INSTALLATION=Y`, `S2_KUBE_CONTEXT` pre-seed step 2.
- `S2_SKIP_SPECS_UPDATE=Y` keeps specs already on disk in step 3.
- `S2CTL_CONFIG=/path/config` moves the config directory (kubeconfig and the key mount live next to it).

## After install

Day-2 operations stay with the vendor script, which reads the same `~/.s2ctl/config` and `~/.s2ctl/kubeconfig`:
`s2ctl.sh upgrade`, `applyConfig`, `refreshIngress`, `deleteObsoleteResources`, `teleport`, `uninstall`. Step 3 prints
the checksum of the `s2ctl.sh` shipped inside the specs tarball; use that copy. Do not pass `-yes2all` to
`s2ctl.sh upgrade`: it auto-approves the Kafka data wipe on a Strimzi major upgrade.

## What is different from s2ctl.sh

- No `eval`, and nothing downloaded or generated is ever `source`d. `config.properties` and `~/.s2ctl/config` are parsed as key=value; overrides are written without `sed`.
- Every download uses `curl -f` into a private temp dir. kubectl, kind, kustomize and helm are verified against publisher checksums; spruce, yaml2json and yq print their sha256 so you can pin them in `versions.env`. Helm is pinned (`HELM_VERSION`) instead of piping the unpinned `get-helm-3` script into bash.
- The GCP key never appears on a command line: the pull secret is built from a 0600 temp file. Kubeconfig and config are 0600.
- Every cluster-touching step asserts the kube context recorded in the config; `05` requires a typed confirmation before touching a cluster that already runs a different deployment. `uninstall`-style deletes are not included.
- Kept for parity, but configurable: the vendor `chmod 777` on the host stores for loki, obmp, prometheus, elasticsearch, gitea, chroma and openbao (`s2_store_mode` in the config). Tightening it requires knowing the UID each container runs as; ask the vendor before changing it.
- Not ported on purpose: the APISIX v1 -> v2 migration and the Strimzi wipe. Step 6 detects an existing APISIX v1 and tells you to run the vendor's `upgrade`.
- `--enable-exec` is still passed to kustomize because the vendor specs need it; it means exec plugins inside the specs tarball run on this host with your privileges.

## Troubleshooting

- Step 4 "cannot talk to Docker": re-login after step 1, or `newgrp docker`.
- Step 6 namespace not ready after the timeout: the step continues like the vendor script; check `kubectl get pods -n <ns>` and `kubectl describe pod`. Elasticsearch crash-looping usually means the `vm.max_map_count` sysctl from step 0 was not applied.
- Re-running a step: safe. Re-running 03 asks before replacing the specs (previous copy goes to `<deploy dir>/backups`).
