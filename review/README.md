# s2 step-by-step installer (Ubuntu VM)

The vendor's `s2ctl.sh install` split into one script per stage. Every step is idempotent and can be re-run
on its own; `install-all.sh` chains them and `--from N` resumes after a fix.

| Step | Script | What it does |
|------|--------|--------------|
| 0 | `00-preflight.sh` | Arch/OS/sudo/terminal checks, RAM/disk/CPU report, apt lock, snap-docker check, kernel sysctls (asks before writing), outbound reachability. |
| 1 | `01-install-tools.sh` | apt packages, gcloud CLI, docker-ce (adds you to the `docker` group), pinned kubectl/kind/kustomize/helm/spruce/yaml2json/yq with checksum verification. Best-effort: probes the download hosts first, skips tools whose host is blocked or whose install fails, and ends with a summary of installed / missing tools and unreachable hosts (also saved to `~/.s2ctl/install-report.txt`). Re-run after fixing the network; installed tools are skipped. |
| 2 | `02-configure.sh` | Key paths, deploy dir, FQDN and overrides -> `~/.s2ctl/config` (0600). Copies the GCP key to the path the kind node mounts. For remote installs, isolates the target context into `~/.s2ctl/kubeconfig`. |
| 3 | `03-download-specs.sh` | Service-account login, downloads and extracts the specs tarball from the vendor bucket, applies `S2_INSTANCE` / `S2_NAME` / FQDN ingress-domain overrides to `config.properties`. |
| 4 | `04-create-kind-cluster.sh` | Host directories from the vendor kind config, `kind create cluster`, dedicated kubeconfig. Skipped for remote installs. |
| 5 | `05-prepare-cluster.sh` | Verifies the target cluster (typed confirmation if it already runs a different deployment), namespaces, GPG key secret, registry pull secret per namespace, optional CoreDNS config. |
| 6 | `06-deploy-apps.sh` | Platform apps in the vendor's order with the vendor's special cases. `--list`, `--only APP`, `--from APP`, `--timeout SEC`. |
| 7 | `07-deploy-s2ap.sh` | Applies s2ap and waits (`--wait MIN`, default 30). |
| 8 | `08-fetch-s2ctl-tools.sh` | Optional. Pulls the `s2ctl` binary, `get_reports.py` and the s2ml specs out of the running deployment (what `s2ctl.sh gets2mspecs` does). |

## If you can only commit files (no shell on the VM)

Commit exactly this layout to the repo the VM checks out (`lib/common.sh` may also sit flat next to the scripts):

```
00-preflight.sh  01-install-tools.sh  02-configure.sh  03-download-specs.sh  04-create-kind-cluster.sh
05-prepare-cluster.sh  06-deploy-apps.sh  07-deploy-s2ap.sh  08-fetch-s2ctl-tools.sh
install-all.sh  versions.env  proxy.env  README.md  lib/common.sh
```

Whoever runs them on the VM should run them **as the normal user, never with `sudo` in front** (the steps call
sudo themselves), and with `bash` so the executable bit doesn't matter:

```bash
cd <checkout>
bash install-all.sh            # or one step at a time: bash 00-preflight.sh, bash 01-install-tools.sh, ...
```

If the VM reaches the internet only through a proxy, put it in `proxy.env` (`https_proxy=http://proxy:3128`) and
commit that too; every step reads it and passes it to curl, apt, gcloud, the Docker daemon and kind. Step 1 also
cleans up the half-written apt repo files a failed earlier run leaves behind, so no manual `rm` is needed.

## Blocked egress, proxies and offline specs

Step 0 lists every host the install needs; step 1 and step 3 re-check the ones they are about to use and stop
within seconds naming the blocked host (instead of hanging in a connect timeout). Three ways out:

- **Allowlist** (ask the network team to open 443 to): `packages.cloud.google.com`, `download.docker.com`,
  `registry-1.docker.io`, `dl.k8s.io`, `cdn.dl.k8s.io`, `github.com`, `objects.githubusercontent.com`,
  `kind.sigs.k8s.io`, `get.helm.sh`, `storage.googleapis.com`, `oauth2.googleapis.com`, `www.googleapis.com`,
  `us-central1-docker.pkg.dev`, plus `charts.releases.teleport.dev` and `selector.teleport.sh` for Teleport.
- **Proxy**: fill in `proxy.env`; every step passes it to curl, apt, gcloud, the Docker daemon and kind.
- **Offline specs**: if the vendor gives you the `<deployment-name>.tgz` directly, place it next to the scripts (or
  set `S2_SPECS_TARBALL=/path/to/it`) and run step 1 with `S2_SKIP_GCLOUD=Y`; step 3 then unpacks it without gcloud.
  This does **not** remove the need for `us-central1-docker.pkg.dev`: the cluster pulls every image from there.

## Quick start (fresh Ubuntu VM)

**1. Copy the bundle to the VM** (from your workstation):

```bash
scp s2-install.tar.gz <user>@<vm-ip>:~/
```

**2. Log in to the VM and unpack it.** Use `tmux` so an SSH drop can't kill a step half-way:

```bash
ssh <user>@<vm-ip>
tmux
tar -xzf ~/s2-install.tar.gz
cd ~/s2-install
ls            # 00-preflight.sh ... 08-fetch-s2ctl-tools.sh, install-all.sh, lib/, versions.env, README.md
```

The tarball keeps the executable bits, so no `chmod` is needed. If you downloaded the scripts one by one instead of the
tarball, recreate the layout by hand (`mkdir -p ~/s2-install/lib`, put `common.sh` in `lib/`) and run
`chmod +x ~/s2-install/*.sh`.

**3. Put the two vendor files where step 2 expects them** (any path works; these are the defaults it offers):

```bash
mkdir -p ~/.s2ctl
cp /path/to/service-account.json ~/.s2ctl/gcp.json
cp /path/to/gpg-key.yaml         ~/.s2ctl/gpg.yaml
chmod 600 ~/.s2ctl/*
```

**4. Run the steps:**

```bash
./install-all.sh            # runs 00 -> 07; stops after step 1 if it just added you to the docker group
exit                        # log out of the VM and back in so the docker group applies
./install-all.sh --from 2   # resumes at step 2
```

Or run them one at a time (`./00-preflight.sh`, `./01-install-tools.sh`, ...); each one prints what to run next.

## Requirements

1. `x86_64` Ubuntu 22.04/24.04 VM and a user with sudo. Nothing else pre-installed: step 1 installs the apt packages, gcloud, Docker and the pinned kubectl/kind/kustomize/helm/spruce/yaml2json/yq.
2. The vendor's service-account JSON key and GPG key manifest (see step 3 above).
3. Inbound 80/443 open, and four DNS records pointing at the VM for `<fqdn>`, `<name>-mon.<domain>`, `<name>-engine.<domain>`, `<name>-registry.<domain>` (step 2 prints the exact names).
4. Outbound access to the hosts step 0 checks, plus `charts.releases.teleport.dev` / `selector.teleport.sh:443` if you will run the vendor's `teleport` command later.

## Environment knobs

- `S2_NONINTERACTIVE=Y` accepts defaults/environment values in step 2 without prompting; `YES_TO_ALL=Y` answers the yes/no prompts (never the typed "wrong cluster" confirmation).
- `S2_GCP_KEY`, `S2_GPG_KEY`, `S2_DEPLOY_DIR`, `S2_FQDN`, `S2_NAME`, `S2_INSTANCE`, `S2_REMOTE_INSTALLATION=Y`, `S2_KUBE_CONTEXT` pre-seed step 2.
- `S2_SKIP_SPECS_UPDATE=Y` keeps specs already on disk in step 3.
- `S2CTL_CONFIG=/path/config` moves the config directory (kubeconfig and the key mount live next to it).
- `proxy.env` (next to the scripts): `http_proxy`, `https_proxy`, `no_proxy` for VMs without direct egress.

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
