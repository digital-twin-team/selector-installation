#!/usr/bin/env bash
set -e

# Check bash version
if [ $(echo $BASH_VERSION | cut -d '.' -f 1) -lt 4 ]
then
	echo
	echo "This script requires Bash shell in version 4 or above. Please upgrade your your Bash istallation"
	echo
	exit 1
fi

bold=$(tput bold)
normal=$(tput sgr0)
specs_bucket_prefix="s2-deployment"
docker_registry="us-central1-docker.pkg.dev"
os_family=$(uname -s | tr [:upper:] [:lower:])
os_user=root
os_user_group=wheel
if [ ${os_family} == "darwin" ]; then
	os_user_group=wheel
else
	os_user_group=root
fi

toolset_remote="gcloud gsutil jq yq kubectl kustomize"
toolset_remote_linux="sed tar awk spruce yaml2json"
toolset_local="kind docker"
declare -A toolset_darwin
toolset_darwin[gcloud]="gcloud-cli"
toolset_darwin[gsutil]="gcloud-cli"
toolset_darwin[gsed]="gsed"
toolset_darwin[gtar]="gnu-tar"
toolset_darwin[gawk]="gawk"
toolset_darwin[getopt]="gnu-getopt"
toolset_darwin[sha256sum]="coreutils"
declare -A toolset_darwin_manual
toolset_darwin_manual[spruce]="https://github.com/geofffranks/spruce"
toolset_darwin_manual[yaml2json]="https://github.com/wakeful/yaml2json"

# Set aliases for binaries
if [ "$(uname -s)" == "Darwin" ]; then
        BREW_HOME="$(brew config | grep HOMEBREW_PREFIX | awk '{print $2}' | xargs)"

        alias sed="${BREW_HOME}/bin/gsed"
        alias tar="${BREW_HOME}/bin/gtar"
        alias awk="${BREW_HOME}/bin/gawk"
        alias getopt="${BREW_HOME}/opt/gnu-getopt/bin/getopt"
fi

download_s2m_specs=N
wait_for_completed=
configure_s2_ns_as_default=Y
YES_TO_ALL=N
s2_remote_installation=N
dont_ask_s2_name=N
s2_bin_dir=/usr/local/bin
k_build_params="build --enable-alpha-plugins --enable-exec --enable-helm"

declare -A TOOLS_VERSIONS
TOOLS_VERSIONS[kubectl]="v1.32.4"
TOOLS_VERSIONS[kind]="v0.27.0"
TOOLS_VERSIONS[kustomize]="v5.7.0"
TOOLS_VERSIONS[spruce]="1.29.0"
TOOLS_VERSIONS[yaml2json]="0.4.0"
TOOLS_VERSIONS[yq]="v4.52.5"
TOOLS_VERSIONS[teleport]="18.10.0"

# Teleport configuration defaults
teleport_version="${TOOLS_VERSIONS[teleport]}"
teleport_cluster_name="kind"
teleport_env=""

: "${S2CTL_CONFIG:=$HOME/.s2ctl/config}"
declare -A CONFIG_ENV_VARS
CONFIG_ENV_VARS[S2_GCP_KEY]="path to google service account json key"
CONFIG_ENV_VARS[S2_GPG_KEY]="path to gpg key used to decrypt secrets inside kubernetes setup"
CONFIG_ENV_VARS[S2_DEPLOY_DIR]="path were script is going to store all files"
CONFIG_ENV_VARS[S2_FQDN]="fully qualified domain name for deployment"
declare -A CONFIG_PARAMS_NO_OPTIONS
CONFIG_PARAMS_NO_OPTIONS[no-setns]="don't set s2 namespace as default for cluster"
CONFIG_PARAMS_NO_OPTIONS[yes2all]="answer 'Y' to all Y/N questions"
CONFIG_PARAMS_NO_OPTIONS[download-s2mspecs]="download s2mspecs after installation is completed (will set '-wait 30' if parameter '-wait' not set)"
CONFIG_PARAMS_NO_OPTIONS[remote]="install s2ap on remote host configured in kubectl"
CONFIG_PARAMS_NO_OPTIONS[dont-ask-s2-name]="skip question for S2_NAME and S2_INSTANCE parameters"
CONFIG_PARAMS_NO_OPTIONS[skip-specs-update]="Skip specs download from remote"
CONFIG_PARAMS_NO_OPTIONS[non-root]="Do not attempt to use root user/group or sudo"
declare -A CONFIG_PARAMS_WITH_OPTIONS
CONFIG_PARAMS_WITH_OPTIONS[config]="${bold}<path_to_config_file>${normal} \t- path to config file for s2ctl.sh - will create file if not existing yet"
CONFIG_PARAMS_WITH_OPTIONS[path-to-gcp-key]="${bold}<path_to_key>${normal} \t- path to GCP service account key used to pull docker images"
CONFIG_PARAMS_WITH_OPTIONS[path-to-gpg-key]="${bold}<path_to_key>${normal} \t- path to GPG private key in yaml manifest. Used to decrypt secrets in deployment container"
CONFIG_PARAMS_WITH_OPTIONS[deployment-dir]="${bold}<path_to_folder>${normal} \t- path to store deployment manifests"
CONFIG_PARAMS_WITH_OPTIONS[fqdn]="${bold}<fqdn>${normal} \t- machine hostname to be set in config.properties file"
CONFIG_PARAMS_WITH_OPTIONS[bin-dir]="${bold}<path_to_folder>${normal} \t- path to store downloaded tools"
CONFIG_PARAMS_WITH_OPTIONS[wait]="${bold}<number_of_minutes>${normal} \t- will wait for deployment to finish but no longer than time provided in parameter in minutes"
CONFIG_PARAMS_WITH_OPTIONS[config-core-dns]="${bold}<path_to_coredns_config_file>${normal} \t- path to coredns config file for kind clusters - it will change configmap for coredns"
CONFIG_PARAMS_WITH_OPTIONS[env]="${bold}<environment>${normal} \t- environment name for teleport labels (e.g., dev, staging, prod)"
CONFIG_PARAMS_WITH_OPTIONS[teleport-version]="${bold}<version>${normal} \t- teleport version to install (default: ${TOOLS_VERSIONS[teleport]})"
CONFIG_PARAMS_WITH_OPTIONS[cluster-name]="${bold}<name>${normal} \t- kind cluster name for teleport installation (default: kind)"

# Envs only for dev mode
declare -A s2_dev_container_repo
declare -A s2_dev_container_tag

function help() {
	echo "Supported commands:"
	echo -e "\t${bold}versionInfo${normal} \t- get version Info of s2ctl binary and s2ctl.sh"
	echo -e "\t${bold}install${normal} \t- create whole setup"
	echo -e "\t${bold}uninstall${normal} \t- delete kind cluster and s2ap directories"
	echo -e "\t${bold}upgrade${normal} \t- upgrade s2ap installation from network"
	echo -e "\t${bold}gets2mspecs${normal} \t- get services/s2ml and s2ctl from deploy container"
	echo -e "\t${bold}gets2ctl${normal} \t- get ONLY s2ctl binary from deploy container"
	echo -e "\t${bold}configureCDPATH${normal} \t- Add custom CDPATH to .bashrc"
	echo -e "\t${bold}depsinstall${normal} \t- Install required dependencies"
	echo -e "\t${bold}applyConfig${normal} \t- Apply all configs for s2ap"
	echo -e "\t${bold}applyConfig <directory-name>${normal} \t- Apply config only from specified directory"
	echo -e "\t${bold}refreshIngress${normal} \t- Reinstall Ingress specs only"
	echo -e "\t${bold}deleteObsoleteResources${normal} \t- Removes resources which were removed from specs"
	echo -e "\t${bold}teleport${normal} \t- Install/upgrade Teleport kube-agent on kind cluster (requires --env parameter)"
	echo
	echo "Supported parameters:"
	for key in "${!CONFIG_PARAMS_NO_OPTIONS[@]}"
	do
		echo -e "\t${bold}-${key}${normal}|${bold}--${key}${normal} \t- ${CONFIG_PARAMS_NO_OPTIONS[$key]}"
	done
	for key in "${!CONFIG_PARAMS_WITH_OPTIONS[@]}"
	do
		echo -e "\t${bold}-${key}${normal}|${bold}--${key}${normal} ${CONFIG_PARAMS_WITH_OPTIONS[$key]}"
	done
	echo
	echo "Environment variables able to set:"
	echo -e "\t${bold}S2CTL_CONFIG${normal} - path to configuration file. By default it is ${S2CTL_CONFIG}"
	for key in "${!CONFIG_ENV_VARS[@]}"
	do
		echo -e "\t${bold}${key}${normal} - ${CONFIG_ENV_VARS[$key]}"
	done
}

function _run_deferred() {
	local _depth="$BASHPID.${#FUNCNAME[@]}"
	[[ "$_depth" != "$_deferred_depth" ]] && return
	local opt=$-
	set +e
	for (( i=${#_deferred[@]} - 1; i >= 0; i-- )); do
		eval "${_deferred[i]}"
	done
	[[ "$opt" == *e* ]] && set -e
}

function _defer() {
	_deferred_depth="$BASHPID.${#FUNCNAME[@]}"
	_deferred+=( "$(printf '%q ' "$@")" )
}
# This has to be an alias so that the `trap ... RETURN` runs appropriately.
shopt -s expand_aliases
alias defer='declare -a _deferred; declare _deferred_depth; trap _run_deferred EXIT RETURN; _defer'

function exists_in_list() {
	list=$1
	value=$2
	for element in $list
	do
		if [ "${element}" == "${value}" ]; then
			return 0
		fi
	done
	return 1
}

function check_tools_version() {
	toolset=$1
	declare -A need_to_update
	if [ "$(kubectl version --client=true -o json | jq -r '.clientVersion.gitVersion')" != "${TOOLS_VERSIONS[kubectl]}" ]
	then
		need_to_update[kubectl]=Y
	fi
	if [ "$(kustomize version | grep -E "v[0-9]+.[0-9]+.[0-9]+" -o)" != "${TOOLS_VERSIONS[kustomize]}" ]
	then
		need_to_update[kustomize]=Y
	fi
	if exists_in_list "$toolset" kind && [ "$(kind version | grep -E "v[0-9]+.[0-9]+.[0-9]+" -o)" != "${TOOLS_VERSIONS[kind]}" ]
	then
		need_to_update[kind]=Y
	fi
	if exists_in_list "$toolset" spruce && [ "$(spruce --version | grep -E "[0-9]+.[0-9]+.[0-9]+" -o)" != "${TOOLS_VERSIONS[spruce]}" ]
	then
		need_to_update[spruce]=Y
	fi
	if exists_in_list "$toolset" yq && [ "$(yq --version | grep -E "v[0-9]+.[0-9]+.[0-9]+" -o)" != "${TOOLS_VERSIONS[yq]}" ]
	then
		need_to_update[yq]=Y
	fi
	if exists_in_list "$toolset" yaml2json && [ "$(yaml2json -version | grep -E "[0-9]+.[0-9]+.[0-9]+" -o)" != "${TOOLS_VERSIONS[yaml2json]}" ]
	then
		need_to_update[yaml2json]=Y
	fi
	if [ ${#need_to_update[@]} -gt 0 ]
	then
		echo "${bold}Detected version mismatch for tools:${normal}"
		for tool in ${!need_to_update[@]}
		do
			echo -e "\t${tool}\t- need ${TOOLS_VERSIONS[${tool}]}"
			echo "Trying to update toolset"
			install_toolset "${toolset}"
		done
	fi
}

function install_tool_os_independed() {
	tool=$1
	architecture=$(uname -m)
	family=$(uname -s | tr [:upper:] [:lower:])

	# Translace architecture to download links
	case $architecture in
	amd64|x86_64 )
		normalized_arch="amd64"
		;;
	arm64|aarch64 )
		normalized_arch="arm64"
		;;
	* )
		echo "Unsupported architecture: $architecture"
		exit 1
	esac

	# Prepare download links
	case $tool in
	kubectl )
		download_url="https://dl.k8s.io/release/${TOOLS_VERSIONS[kubectl]}/bin/${family}/${normalized_arch}/kubectl"
		archive_type="bin"
		;;
	kustomize )
		download_url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/${TOOLS_VERSIONS[kustomize]}/kustomize_${TOOLS_VERSIONS[kustomize]}_${family}_${normalized_arch}.tar.gz"
		archive_type="tgz"
		;;
	yq )
		download_url="https://github.com/mikefarah/yq/releases/download/${TOOLS_VERSIONS[yq]}/yq_${family}_${normalized_arch}"
		archive_type="bin"
		;;
	*)
		echo "Unsupported tool: $tool"
		exit 1
	esac

	# Download and install
	curl -Lo "${tool}.${archive_type}" "${download_url}"
	defer rm "${tool}.${archive_type}"

	case $archive_type in
		tgz )
			tar -xzf "${tool}.${archive_type}"
			defer rm "${tool}"
			source_bin="${tool}"
			;;
		bin )
			source_bin="${tool}.${archive_type}"
			;;
		* )
			echo "Unsupported archive type: $archive_type"
			exit 1
	esac

	${sudo} mkdir -p ${s2_bin_dir}
	${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 "${source_bin}" "${s2_bin_dir}/${tool}"

}

function install_toolset_os_linux() {
	toolset=$1
	# kubectl
	install_tool_os_independed kubectl
	# kind
	install_tool_os_independed kustomize
	if exists_in_list "$toolset" "kind"
	then
		curl -Lo ./kind https://kind.sigs.k8s.io/dl/${TOOLS_VERSIONS[kind]}/kind-linux-amd64
		${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 kind ${s2_bin_dir}/kind
		defer rm kind
	fi
	# spruce
	curl -Lo ./spruce https://github.com/geofffranks/spruce/releases/download/v${TOOLS_VERSIONS[spruce]}/spruce-linux-amd64
	${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 spruce ${s2_bin_dir}/spruce
	defer rm spruce
	# yaml2json
	curl -Lo ./yaml2json https://github.com/wakeful/yaml2json/releases/download/${TOOLS_VERSIONS[yaml2json]}/yaml2json-linux-amd64
	${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 yaml2json ${s2_bin_dir}/yaml2json
	defer rm yaml2json
	# yq
	curl -Lo ./yq https://github.com/mikefarah/yq/releases/download/${TOOLS_VERSIONS[yq]}/yq_linux_amd64
	${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 yq ${s2_bin_dir}/yq
	defer rm yq
}

function install_toolset_debian() {
	toolset=$1
	if test "${NON_ROOT}" == "Y"; then
		cat <<- EOF
		Ensure the following packages are installed:
			apt-get update
			apt-get install -y apt-transport-https ca-certificates gnupg sed tar gawk jq curl lsb-release git coreutils

		gcloud-sdk install:
			https://cloud.google.com/sdk/docs/install#deb

		Docker install (KIND only):
			https://docs.docker.com/engine/install/debian/
			https://docs.docker.com/engine/install/ubuntu/

			Add user to docker group:
			usermod -aG docker $(whoami)
			systemctl start docker
		EOF
	else
		${sudo} apt-get update
		${sudo} apt-get install -y apt-transport-https ca-certificates gnupg sed tar gawk jq curl lsb-release git coreutils
		# gcloud sdk
		if ! which gcloud > /dev/null 2>&1
		then
			echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | ${sudo} tee /etc/apt/sources.list.d/google-cloud-sdk.list
			curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | ${sudo} gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
			${sudo} apt-get update && ${sudo} apt-get install -y google-cloud-cli
		fi
		# docker
		if exists_in_list "$toolset" "docker"
		then
			if ! which docker > /dev/null 2>&1
			then
				curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${sudo} tee /etc/apt/keyrings/docker.asc > /dev/null
				${sudo} chmod a+r /etc/apt/keyrings/docker.asc
				echo \
					"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
					$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
					${sudo} tee /etc/apt/sources.list.d/docker.list > /dev/null
				${sudo} apt-get update
				${sudo} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
				${sudo} adduser $(whoami) docker
				echo
				echo "${bold}It is possible that you need to relogin to shell to be able to use docker!${normal}"
			fi
		fi
	fi
}

function install_toolset_enterprise_linux() {
	toolset=$1

	if test "${NON_ROOT}" == "Y"; then
		# no epel-release on RHEL
		if ! grep -q 'ID="rhel"' /etc/os-release; then
			cat <<- EOF
			Ensure the following packages are installed:
				yum install -y sed tar gawk jq curl yum-utils git coreutils
			EOF
		else
			cat <<- EOF
			Ensure the following packages are installed:
				yum install -y epel-release
				yum install -y sed tar gawk jq curl yum-utils git coreutils
			EOF
		fi
		cat <<- EOF
		gcloud-sdk install:
			https://cloud.google.com/sdk/docs/install#rpm

		Docker install (KIND only):
			https://docs.docker.com/engine/install/rhel/

			Add user to docker group:
			usermod -aG docker $(whoami)
			systemctl start docker
		EOF
	else
		# no epel-release on RHEL
		if ! grep -q 'ID="rhel"' /etc/os-release; then
			${sudo} yum install -y epel-release
		fi
		${sudo} yum install -y sed tar gawk jq curl yum-utils git coreutils
		# gcloud sdk
		if ! which gcloud > /dev/null 2>&1
		then
			${sudo} tee -a /etc/yum.repos.d/google-cloud-sdk.repo <<- EOM
				[google-cloud-sdk]
				name=Google Cloud SDK
				baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
				enabled=1
				gpgcheck=1
				repo_gpgcheck=0
				gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
				       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
			EOM
			${sudo} yum install -y google-cloud-cli
		fi
		# docker
		if exists_in_list "$toolset" "docker"
		then
			if ! which docker > /dev/null 2>&1
			then
				${sudo} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
				${sudo} yum install -y docker-ce docker-ce-cli containerd.io
				${sudo} usermod -aG docker $(whoami)
				${sudo} systemctl start docker
				echo
				echo "${bold}It is possible that you need to relogin to shell to be able to use docker!${normal}"
			fi
		fi
	fi
}

function install_toolset_os_darwin() {
	toolset=$1
	architecture=$(uname -m)
	if ! which brew > /dev/null 2>&1
	then
		echo "To install dependencies you need to install first ${bold}brew${normal}"
		echo "    See https://brew.sh/ for instructions."
		exit 1
	fi

	for tool in $toolset
	do
		local darwin_tools_list=${!toolset_darwin_manual[@]}
		if exists_in_list "${darwin_tools_list}" $tool ! which $tool > /dev/null 2>&1
		then
			if ! which $tool > /dev/null 2>&1
			then
				echo "Can't find $tool and can't install it"
				echo "Please ${bold}install $tool manually${normal} from ${toolset_darwin_manual[$tool]}"
				exit 1
			fi
		else
			case $tool in
			kubectl|kustomize|yq )
				install_tool_os_independed $tool
				;;
			* )
				if [ ! -z "${TOOLS_VERSIONS[$tool]}" ]
				then
					brew install ${tool}@${TOOLS_VERSIONS[$tool]}
				else
					if [[ ! -z "${toolset_darwin[$tool]}" ]]
					then
						brew install ${toolset_darwin[$tool]}
					else
						brew install $tool
					fi
				fi
				;;
			esac
		fi
	done
}

function install_toolset_unsupported() {
	echo "You are running unsupported OS. This script is not able to install all dependencies for you"
	echo "Please install manually all required software:"
	for tool in $toolset
	do
		if ! which $tool > /dev/null 2>&1
		then
			echo -e "\t${bold}${tool}${normal}"
		fi
	done
	exit 1
}

function install_toolset() {
	toolset=$1
	os_type=$(uname -s)
	if [ "${os_type}" == "Linux" ]; then
		os_type=$(grep ^ID= /etc/os-release | sed -e 's/ID=//' -e 's/"//g')
	fi
	case $os_type in
		debian | ubuntu)
			install_toolset_debian "$toolset"
			install_toolset_os_linux "$toolset"
			install_helm
			;;
		rhel | centos | almalinux | rocky)
			install_toolset_enterprise_linux "$toolset"
			install_toolset_os_linux "$toolset"
			install_helm
			;;
		Darwin )
			install_toolset_os_darwin "$toolset"
			install_helm
			;;
		*)
			install_toolset_unsupported
			;;
	esac
}

function check_toolset() {
	toolset="$toolset_remote"
	if [ ! -z "${s2_remote_installation}" ] && [ "${s2_remote_installation}" == "N" ] && [ "$(uname -s)" != "Darwin" ]; then
		toolset="$toolset $toolset_local $toolset_remote_linux"
	fi
	if [ "$(uname -s)" == "Darwin" ]; then
		toolset="$toolset ${!toolset_darwin_manual[@]} ${!toolset_darwin[@]}"
	fi
}

function ask_question() {
	env_name=$1
	default_value=$2
	info_text="$3"

	if [ -z ${default_value} ]
	then
		echo -n "$info_text : "
	else
		echo -n "$info_text [${bold}${default_value}${normal}] : "
	fi
	read input
	if [ ! -z $input ]
	then
		eval "${env_name}=${input}"
	else
		eval "${env_name}=${default_value}"
	fi
}

function print_config() {
cat <<EOF
s2_gcp_key=${s2_gcp_key}
s2_gpg_key=${s2_gpg_key}
s2_deploy_dir=${s2_deploy_dir}
s2_deployment_name=${s2_deployment_name}
s2_remote_installation=${s2_remote_installation}
s2_name=${s2_name}
s2_instance=${s2_instance}
s2_bin_dir=${s2_bin_dir}
s2_fqdn=${s2_fqdn}
EOF

for key in ${!s2_dev_container_repo[@]}
do
	echo "s2_dev_container_repo[$key]=${s2_dev_container_repo[${key}]}"
	echo "s2_dev_container_tag[$key]=${s2_dev_container_tag[${key}]}"
	echo "s2_dev_container_orig_repo[$key]=${s2_dev_container_orig_repo[${key}]}"
done
}

function save_config() {
	if [ ! -d "$(dirname ${S2CTL_CONFIG})" ]
	then
		mkdir -p "$(dirname $S2CTL_CONFIG)"
	fi
	print_config > "${S2CTL_CONFIG}"
}

function create_dir() {
	if [ ! -d ${1} ]
	then
		${sudo} mkdir -p ${1}
		${sudo} chown $(whoami): ${1}
	fi
}

function backup_dir() {
	path_to_backup=$1
	backup_dir=$(echo $path_to_backup | awk -F / '{print $NF}')
	backup_date=$(date +%Y%m%d-%s)
	mkdir -p $s2_deploy_dir/backups
	if [ -d $path_to_backup ]
	then
		mv $path_to_backup $path_to_backup/../backups/${backup_date}-${backup_dir}
	fi
}

function get_bucket_name() {
	env_name=$1
	fullBucketName="${specs_bucket_prefix}-${env_name}-$(echo -n $env_name | sha256sum -t | awk '{print $1}')"
	bucketName=${fullBucketName:0:63}
	echo -n ${bucketName}
}

function get_gcloud_account() {
	account_name="$(jq -r '.client_email|split("@")[0]' < ${s2_gcp_key})"
	if [ $(gcloud config configurations list | grep -c -s "${account_name}\s") -eq 0 ] ; then
		gcloud config configurations create "${account_name}" --no-activate >/dev/null
	fi
	gcloud auth activate-service-account --configuration "${account_name}" --key-file=${s2_gcp_key} >/dev/null
	echo -n "${account_name}"
}

function check_s2ctl_is_valid() {
	local running_script="${1}"
	local from_specs_script="${2}"
	local running_script_sha=$(sha256sum "${running_script}" | awk '{print $1}')
	local from_specs_script_sha=$(sha256sum "${from_specs_script}" | awk '{print $1}')
	local counter=0
	local wait_limit=60

	if [ "${running_script_sha}" != "${from_specs_script_sha}" ]
	then
		echo
		echo "${bold}Local version  of s2ctl.sh is different from one downloaded with specs!"
		echo "It is strongly recomended to update s2ctl.sh to one downloaded with specs!"
		echo
		echo "Script execution will pause for ${wait_limit} seconds. Cancel it if you want to upgrade s2ctl.sh${normal}"
		echo
		while [ ${counter} -lt ${wait_limit} ]
		do
			if [ $(((wait_limit-counter)%10)) -eq 0 ]
			then
				echo -n "$((wait_limit-counter))"
			else
				echo -n "."
			fi
			counter=$((counter+1))
			sleep 1
		done
		echo
	fi
}

function download_specs() {
	get_deployment_specs=N
	kustomize_dir=${s2_deploy_dir}/kustomize
	if [ "$SKIP_SPECS_UPDATE" == "Y" ]
	then
		echo "Skipping specs download SKIP_SPECS_UPDATE"
		return 0
	fi
	if [ "$YES_TO_ALL" == "N" ]
	then
		if [ -d "${kustomize_dir}/environments/${s2_deployment_name}" ]
		then
			ask_question get_deployment_specs $get_deployment_specs "Deployment specs detected. Do you want to use remote kubernetes specs? Y/N"
		else
			get_deployment_specs=Y
		fi
	else
		get_deployment_specs=$YES_TO_ALL
	fi
	if [ "$get_deployment_specs" == "Y" ]
	then
		# Login using service key
		account_name="$(get_gcloud_account)"
		create_dir ${s2_deploy_dir}
		backup_dir ${kustomize_dir}
		echo "Downloading specs"
		mkdir -p ${kustomize_dir}
		gcloud storage --configuration "${account_name}" cp "gs://$(get_bucket_name ${s2_deployment_name})/${s2_deployment_name}.tgz" ${kustomize_dir}
		( cd ${kustomize_dir} && tar -xzf ${s2_deployment_name}.tgz )
		check_s2ctl_is_valid "${0}" "${kustomize_dir}/environments/${s2_deployment_name}/s2kustomize/scripts/s2ctl.sh"
	else
		echo "Skipping specs download"
	fi
}

function download_repo_tarball() {
	echo "Downloading tarball with docker images"
	account_name="$(get_gcloud_account)"
	gcloud storage --configuration "${account_name}" cp "gs://$(get_bucket_name ${s2_deployment_name})/s2registry.tar" ${s2_deploy_dir}
}

function f_kctl() {
        local max_retry=5
        local retry_counter=0
        local allow_errors=false
        if [ "${1}" == "allow_errors" ]
        then
                shift
                allow_errors=true
        fi
        while ! kubectl $*
        do
                if [ "${allow_errors}" == "false" ]
                then
                        sleep 1
                        retry_counter=$((retry_counter+1))
                        if [ $retry_counter -eq $max_retry ]
                        then
                                echo "ERROR: Could not use kubectl properly!" >&2
                                return 2
                        fi
                else
                        return 2
                fi
        done
}

function install_docker_credentials() {
	local namespace=$1
	kubectl -n ${namespace} create secret docker-registry s2-regcred \
		--docker-server="https://${docker_registry}" \
		--docker-username=_json_key \
		--docker-password="$(cat ${s2_gcp_key})" \
		--docker-email=$(jq .client_email <(cat ${s2_gcp_key})) \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl -n ${namespace} patch serviceaccount default -p '{"imagePullSecrets": [{"name": "s2-regcred"}]}'
}

function configure_kind_cluster() {
	kind_config_patch=""
	kustomize_dir=${s2_deploy_dir}/kustomize
	if [ -f "${kustomize_dir}/environments/${s2_deployment_name}/kind/patch.yaml" ]
	then
		kind_config_patch="${kustomize_dir}/environments/${s2_deployment_name}/kind/patch.yaml"
	fi
	log_path=$(spruce merge ${kustomize_dir}/kind-setup/kindconfig.yaml $kind_config_patch | grep -A 1 /var/log/s2 | grep hostPath | awk '{ print $2 }')
	stores_path=$(spruce merge ${kustomize_dir}/kind-setup/kindconfig.yaml $kind_config_patch | grep -A 1 /var/selector/storage | grep hostPath | awk '{ print $2 }')
	${sudo} mkdir -p ${log_path}
	for store in $(jq -r .stores[] ${kustomize_dir}/kind-setup/kindsetup.json)
	do
		${sudo} mkdir -p ${stores_path}/${store}
		if [[ "${store}" =~ (loki|obmp|prometheus/data|elasticsearch-data|gitea-shared-storage|chroma-data|openbao-data) ]]
		then
			${sudo} chmod 777 ${stores_path}/${store}
		fi
	done

	if [ $(kind get clusters | grep -c kind) -ne 0 ]
	then
		echo "Found running kind cluster. Skipping cluster creation"
	else
		# Ensure the config-dir gcp.json is a regular file before kind starts so Docker
		# doesn't silently bind-mount-create it as an empty directory (OPS-8538).
		local s2ctl_config_dir
		s2ctl_config_dir=$(dirname "${S2CTL_CONFIG}")
		if [ -d "${s2ctl_config_dir}/gcp.json" ]
		then
			${sudo} rm -rf "${s2ctl_config_dir}/gcp.json"
		fi
		if [ ! -e "${s2ctl_config_dir}/gcp.json" ]
		then
			${sudo} install -D -m 0600 "${s2_gcp_key}" "${s2ctl_config_dir}/gcp.json"
		fi
		kind create cluster --config <(spruce merge ${kustomize_dir}/kind-setup/kindconfig.yaml $kind_config_patch)
		while ! kubectl get serviceaccount default
		do
			echo "Waiting for creation of 'default' service account"
			sleep 10
		done
	fi
}

function get_list_of_apps() {
	find ${kustomize_dir}/environments/${s2_deployment_name} -maxdepth 2 -name kustomization.yaml \
		| sed -e "s;${kustomize_dir}/environments/${s2_deployment_name}/;;g" \
		-e 's;/kustomization.yaml;;g' | sort
}

function get_apps_namespace() {
	local app="${1}"
	grep 'namespace:' ${kustomize_dir}/environments/${s2_deployment_name}/${app}/kustomization.yaml \
		| awk '{ print $2 }' | sort -u
}

function configure_namespaces() {
	local set_s2_default_namespace=$1
	for app in $(get_list_of_apps)
	do
		local namespace=$(get_apps_namespace $app)
		kubectl create ns ${namespace} || echo "Namespace ${bold}${namespace}${normal} already exist - skipping"
		if [[ "${namespace}" == "s2" || "${namespace}" == "s2-system" ]]
		then
			yq '.metadata.namespace = "'"${namespace}"'"' "$s2_gpg_key" | kubectl apply -f -
		fi
	done
	if [ "$set_s2_default_namespace" == "Y" ]
	then
		kubectl config set-context --current --namespace=s2
	fi
}

function delete_object() {
	local objectString="$1"

	IFS="," read -r -a object <<< "$objectString"
	if [ -z "${object[1]}" ]
	then
		f_kctl delete "${object[0]}" "${object[2]}" --ignore-not-found=true
	else
		f_kctl delete -n "${object[1]}" "${object[0]}" "${object[2]}" --ignore-not-found=true
	fi

}

function remove_apisix() {
	local ingress_version="${1}"
	local objects_to_delete=""
	# Never delete apisix-gateway and apisix-gateway-udp services
	# as they may be using ephemeral IP
	# which will be lost on service deletion
	local apisix_one_objects="
		ClusterRole,,apisix-clusterrole
		ClusterRoleBinding,,apisix-clusterrolebinding
		ConfigMap,ingress-apisix,apisix
		ConfigMap,ingress-apisix,apisix-configmap
		ConfigMap,ingress-apisix,apisix-data-plane
		ConfigMap,ingress-apisix,s2-initiator
		CustomResourceDefinition,,apisixclusterconfigs.apisix.apache.org
		CustomResourceDefinition,,apisixconsumers.apisix.apache.org
		CustomResourceDefinition,,apisixglobalrules.apisix.apache.org
		CustomResourceDefinition,,apisixpluginconfigs.apisix.apache.org
		CustomResourceDefinition,,apisixroutes.apisix.apache.org
		CustomResourceDefinition,,apisixtlses.apisix.apache.org
		CustomResourceDefinition,,apisixupstreams.apisix.apache.org
		DaemonSet,ingress-apisix,apisix-data-plane
		Deployment,ingress-apisix,apisix
		Deployment,ingress-apisix,apisix-data-plane
		Deployment,ingress-apisix,apisix-ingress-controller
		Deployment,ingress-apisix,reloader-reloader
		Deployment,ingress-apisix,s2-redis
		IngressClass,,apisix
		Job,ingress-apisix,s2-configurator
		PodDisruptionBudget,ingress-apisix,apisix-etcd
		PriorityClass,,s2-network-apisix
		RoleBinding,ingress-apisix,apisix-s2-token-refresher
		RoleBinding,ingress-apisix,reloader-reloader-metadata-rolebinding
		RoleBinding,ingress-apisix,reloader-reloader-role-binding
		RoleBinding,ingress-apisix,s2-configurator
		RoleBinding,ingress-apisix,s2-configurator-auth
		Role,ingress-apisix,reloader-reloader-metadata-role
		Role,ingress-apisix,reloader-reloader-role
		Role,ingress-apisix,s2-configurator
		ServiceAccount,ingress-apisix,apisix-ingress-controller
		ServiceAccount,ingress-apisix,reloader-reloader
		ServiceAccount,ingress-apisix,s2-configurator-service-account
		Service,ingress-apisix,apisix-admin
		Service,ingress-apisix,apisix-etcd
		Service,ingress-apisix,apisix-etcd-headless
		Service,ingress-apisix,apisix-ingress-controller
		Service,ingress-apisix,apisix-prometheus-metrics
		Service,ingress-apisix,s2-redis
		StatefulSet,ingress-apisix,apisix-etcd"
	local apisix_two_objects="
		ClusterRole,,apisix-apisix-ingress-manager-role
		ClusterRole,,apisix-apisix-ingress-metrics-auth-role
		ClusterRole,,apisix-apisix-ingress-metrics-reader
		ClusterRoleBinding,,apisix-apisix-ingress-manager-rolebinding
		ClusterRoleBinding,,apisix-apisix-ingress-metrics-auth-rolebinding
		ConfigMap,ingress-apisix,apisix
		ConfigMap,ingress-apisix,apisix-ingress-config
		ConfigMap,ingress-apisix,s2-initiator
		CustomResourceDefinition,,apisixconsumers.apisix.apache.org
		CustomResourceDefinition,,apisixglobalrules.apisix.apache.org
		CustomResourceDefinition,,apisixpluginconfigs.apisix.apache.org
		CustomResourceDefinition,,apisixroutes.apisix.apache.org
		CustomResourceDefinition,,apisixtlses.apisix.apache.org
		CustomResourceDefinition,,apisixupstreams.apisix.apache.org
		CustomResourceDefinition,,backendtlspolicies.gateway.networking.k8s.io
		CustomResourceDefinition,,backendtrafficpolicies.apisix.apache.org
		CustomResourceDefinition,,consumers.apisix.apache.org
		CustomResourceDefinition,,gatewayclasses.gateway.networking.k8s.io
		CustomResourceDefinition,,gatewayproxies.apisix.apache.org
		CustomResourceDefinition,,gateways.gateway.networking.k8s.io
		CustomResourceDefinition,,grpcroutes.gateway.networking.k8s.io
		CustomResourceDefinition,,httproutepolicies.apisix.apache.org
		CustomResourceDefinition,,httproutes.gateway.networking.k8s.io
		CustomResourceDefinition,,pluginconfigs.apisix.apache.org
		CustomResourceDefinition,,referencegrants.gateway.networking.k8s.io
		CustomResourceDefinition,,tcproutes.gateway.networking.k8s.io
		CustomResourceDefinition,,tlsroutes.gateway.networking.k8s.io
		CustomResourceDefinition,,udproutes.gateway.networking.k8s.io
		CustomResourceDefinition,,xbackendtrafficpolicies.gateway.networking.x-k8s.io
		CustomResourceDefinition,,xlistenersets.gateway.networking.x-k8s.io
		DaemonSet,ingress-apisix,apisix
		Deployment,ingress-apisix,apisix
		Deployment,ingress-apisix,apisix-ingress-controller
		Deployment,ingress-apisix,reloader-reloader
		Deployment,ingress-apisix,s2-redis
		GatewayProxy,ingress-apisix,apisix-config
		IngressClass,,apisix
		Job,ingress-apisix,s2-configurator
		PriorityClass,,s2-network-apisix
		RoleBinding,ingress-apisix,apisix-apisix-ingress-leader-election-rolebinding
		RoleBinding,ingress-apisix,apisix-s2-token-refresher
		RoleBinding,ingress-apisix,reloader-reloader-metadata-rolebinding
		RoleBinding,ingress-apisix,reloader-reloader-role-binding
		RoleBinding,ingress-apisix,s2-configurator
		RoleBinding,ingress-apisix,s2-configurator-auth
		Role,ingress-apisix,apisix-apisix-ingress-leader-election-role
		Role,ingress-apisix,reloader-reloader-metadata-role
		Role,ingress-apisix,reloader-reloader-role
		Role,ingress-apisix,s2-configurator
		Secret,ingress-apisix,etcd-apisix
		ServiceAccount,ingress-apisix,apisix
		ServiceAccount,ingress-apisix,reloader-reloader
		ServiceAccount,ingress-apisix,s2-configurator-service-account
		Service,ingress-apisix,apisix-admin
		Service,ingress-apisix,apisix-ingress-controller
		Service,ingress-apisix,s2-redis"

	case "${ingress_version}" in
		"apisix-ingress-controller-v1")
			objects_to_delete="${apisix_one_objects}"
			;;
		"apisix-ingress-controller-v2")
			objects_to_delete="${apisix_two_objects}"
			;;
	esac
	for object in ${objects_to_delete}
	do
		delete_object "${object}"
	done
}

function migrate_apisix() {
	local namespace="${1}"
	local deployment_specs_dir="${2}"
	local desired_version="apisix-ingress-controller-v2"
	local deployed_version="apisix-ingress-controller-v2"

	# Check if ApiSix is installed
	if [ $(f_kctl -n "${namespace}" get deployments --no-headers | wc -l) -gt 0 ]
	then
		echo "Migrating ApiSix"
# REMEMBER - do not delete SERVICES!
		for annotation in $(f_kctl -n "${namespace}" get pods -o yaml | yq '.items.[].metadata.annotations."selector.ai/ingress"')
		do
			if [ "${annotation}" = "null" ] || [ "${annotation}" = "apisix-ingress-controller-v1" ]
			then
				deployed_version="apisix-ingress-controller-v1"
				continue
			fi
		done
		desired_version=$(kustomize ${k_build_params} ${deployment_specs_dir} | yq 'select(.metadata.name=="apisix" and (.kind=="Deployment" or .kind=="DaemonSet"))|.metadata.annotations."selector.ai/ingress"')
		if [ "${deployed_version}" != "${desired_version}" ]
		then
			remove_apisix "${deployed_version}"
		fi
	else
		echo "No ApiSix deployments detected."
	fi
	# Install CRDs first
	kustomize ${k_build_params} ${deployment_specs_dir} | yq 'select(.kind=="CustomResourceDefinition")' | kubectl apply -f - && sleep 5
	kustomize ${k_build_params} ${deployment_specs_dir} | kubectl apply -f -

}

function deploy_cert_manager() {
	local deployment_specs_dir="${1}"

	# Install CRDs first — trust-manager Certificate/Issuer need cert-manager.io CRDs established.
	kustomize ${k_build_params} ${deployment_specs_dir} | yq 'select(.kind=="CustomResourceDefinition")' | kubectl apply -f - && sleep 5
	kustomize ${k_build_params} ${deployment_specs_dir} | kubectl apply -f -
}

# Return Strimzi version from chart label or image (e.g. 0.51.0 / 1.0.1).
function get_strimzi_semver() {
	local chart="${1:-}"
	local image="${2:-}"
	if [[ "${chart}" =~ strimzi-kafka-operator-([0-9]+\.[0-9]+\.[0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "${image}" =~ -([0-9]+\.[0-9]+\.[0-9]+)([-:]|$) ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
}

# After graceful deletes: one prompt to force-clear all stuck Kafka leftovers.
# Force is never auto-approved (including -yes2all).
function confirm_force_delete_stuck_strimzi() {
	local operator_ns="${1}"
	local kafka_ns="${2}"
	local cluster="${3}"
	local operator="${4}"
	local cluster_label="strimzi.io/cluster=${cluster}"
	local stuck_kafka_pods stuck_operator_pods stuck_pvcs pvc
	local force_delete_stuck="N"

	stuck_kafka_pods="$(f_kctl allow_errors -n "${kafka_ns}" get pod -l "${cluster_label}" --no-headers 2>/dev/null || true)"
	stuck_operator_pods="$(f_kctl allow_errors -n "${operator_ns}" get pod -l "name=${operator}" --no-headers 2>/dev/null || true)"
	stuck_pvcs="$(f_kctl allow_errors -n "${kafka_ns}" get pvc -l "${cluster_label}" -o name 2>/dev/null || true)"

	if [ -z "${stuck_kafka_pods}${stuck_operator_pods}${stuck_pvcs}" ]
	then
		return 1
	fi

	echo ""
	echo "WARNING: Some Kafka-related resources did not terminate gracefully during wipe."
	echo "Force-delete may skip graceful shutdown and clear PVC finalizers."
	[ -n "${stuck_kafka_pods}" ] && echo "Stuck Kafka pods:"$'\n'"${stuck_kafka_pods}"
	[ -n "${stuck_operator_pods}" ] && echo "Stuck operator pods:"$'\n'"${stuck_operator_pods}"
	[ -n "${stuck_pvcs}" ] && echo "Stuck PVCs:"$'\n'"${stuck_pvcs}"
	echo ""

	if [ "${YES_TO_ALL}" == "Y" ]
	then
		echo "Skipping force-delete under -yes2all. Clean up stuck Kafka resources manually if needed."
		return 1
	fi

	ask_question force_delete_stuck "N" "Force-delete stuck Kafka resources listed above? Y/N"
	if [ "${force_delete_stuck}" != "Y" ] && [ "${force_delete_stuck}" != "y" ]
	then
		echo "Leaving stuck Kafka resources in place."
		return 1
	fi

	[ -n "${stuck_kafka_pods}" ] && \
		f_kctl allow_errors -n "${kafka_ns}" delete pod -l "${cluster_label}" \
			--force --grace-period=0 --ignore-not-found=true || true
	[ -n "${stuck_operator_pods}" ] && \
		f_kctl allow_errors -n "${operator_ns}" delete pod -l "name=${operator}" \
			--force --grace-period=0 --ignore-not-found=true || true
	for pvc in ${stuck_pvcs}
	do
		f_kctl allow_errors -n "${kafka_ns}" patch "${pvc}" \
			--type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
		f_kctl allow_errors -n "${kafka_ns}" delete "${pvc}" \
			--force --grace-period=0 --ignore-not-found=true || true
	done
	return 0
}

# Delete old Strimzi operator, Kafka CRs, and PVCs (DATA LOSS).
function wipe_strimzi_kafka_cluster() {
	local operator_ns="kafka"
	local kafka_ns="s2"
	local cluster="s2-kafka-cluster"
	local operator="strimzi-cluster-operator"
	local kustomize_root="${kustomize_dir}/environments/${s2_deployment_name}/s2kustomize/kustomize"
	local chart operator_path
	local cluster_label="strimzi.io/cluster=${cluster}"

	[ -d "${kustomize_root}/kafka/operator" ] || kustomize_root="${kustomize_dir}"

	echo "Deleting Strimzi operator, Kafka CRs, and PVCs (DATA LOSS)..."

	f_kctl allow_errors -n "${kafka_ns}" delete kafka "${cluster}" --ignore-not-found=true --timeout=60s || true
	f_kctl allow_errors -n "${kafka_ns}" delete kafkanodepool -l "${cluster_label}" --ignore-not-found=true --timeout=60s || true
	f_kctl allow_errors -n "${kafka_ns}" delete kafkanodepool kafka controller --ignore-not-found=true --timeout=60s || true
	f_kctl allow_errors -n "${kafka_ns}" wait --for=delete pod -l "${cluster_label}" --timeout=60s || true

	echo "Deleting PVCs with label ${cluster_label}..."
	f_kctl allow_errors -n "${kafka_ns}" delete pvc -l "${cluster_label}" \
		--ignore-not-found=true --timeout=30s || true

	chart="$(f_kctl allow_errors -n "${operator_ns}" get deployment "${operator}" -o jsonpath='{.metadata.labels.chart}' 2>/dev/null || true)"
	if [[ "${chart}" == strimzi-kafka-operator-0.45.* ]]
	then
		operator_path="${kustomize_root}/kafka-legacy/operator"
	else
		operator_path="${kustomize_root}/kafka/operator"
	fi

	if [ -d "${operator_path}" ]
	then
		kustomize ${k_build_params} "${operator_path}" | kubectl delete -f - --ignore-not-found=true || true
	else
		f_kctl allow_errors -n "${operator_ns}" delete deployment "${operator}" --ignore-not-found=true || true
	fi
	f_kctl allow_errors -n "${operator_ns}" wait --for=delete pod -l "name=${operator}" --timeout=60s || true

	# return 1 means nothing stuck / skipped .
	if ! confirm_force_delete_stuck_strimzi "${operator_ns}" "${kafka_ns}" "${cluster}" "${operator}"
	then
		echo "Nothing left to force-clean."
	fi
	echo "Strimzi wipe complete."
}

# If cluster is Strimzi 0.45/0.51 and specs want 1.0.x, print "ON_CLUSTER IN_SPECS" and return 0.
# Returns 1 when no wipe is needed.
function strimzi_v1_wipe_versions() {
	local kafka_specs="${kustomize_dir}/environments/${s2_deployment_name}/kafka"
	local operator="strimzi-cluster-operator"
	local rendered chart image on_cluster in_specs

	[ -d "${kafka_specs}" ] || return 1

	rendered="$(kustomize ${k_build_params} "${kafka_specs}")"
	chart="$(echo "${rendered}" | yq 'select(.kind=="Deployment" and .metadata.name=="'"${operator}"'")|.metadata.labels.chart' | head -n1)"
	image="$(echo "${rendered}" | yq 'select(.kind=="Deployment" and .metadata.name=="'"${operator}"'")|.spec.template.spec.containers[0].image' | head -n1)"
	in_specs="$(get_strimzi_semver "${chart}" "${image}")"
	[[ "${in_specs}" == 1.* ]] || return 1

	f_kctl allow_errors -n kafka get deployment "${operator}" >/dev/null 2>&1 || return 1
	chart="$(f_kctl -n kafka get deployment "${operator}" -o jsonpath='{.metadata.labels.chart}' 2>/dev/null || true)"
	image="$(f_kctl -n kafka get deployment "${operator}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
	on_cluster="$(get_strimzi_semver "${chart}" "${image}")"
	[[ "${on_cluster}" == 1.* ]] && return 1
	# Wipe on 0.51/0.45→1.0, or partial mix (1.0.1 + leftover 0.51/v1beta2). Skip pure 1.0.1.
	[[ "${on_cluster}" == 0.51.* || "${on_cluster}" == 0.45.* ]] \
		|| f_kctl allow_errors get crd -o jsonpath='{range .items[?(@.spec.group=="kafka.strimzi.io")]}{.metadata.labels.chart}{.status.storedVersions}{"\n"}{end}' 2>/dev/null | grep -qE '0\.(51|45)|v1beta2' \
		|| f_kctl allow_errors -n s2 get kafka,kafkanodepool,kafkaconnect,kafkatopic,kafkauser -o jsonpath='{range .items[*]}{.apiVersion}{"\n"}{end}' 2>/dev/null | grep -q 'v1beta2' \
		|| return 0

	echo "Strimzi on cluster is ${on_cluster:-mixed}, specs want ${in_specs} — wiping old Kafka."
	wipe_strimzi_kafka_cluster
}

function wait_for_job_complete() {
	local namespace="${1}"
	local job="${2}"
	local timeout="${3:-600}"

	if ! f_kctl allow_errors -n "${namespace}" get job "${job}" >/dev/null 2>&1
	then
		return 0
	fi

	echo "Waiting for job/${job} in namespace ${namespace} (timeout ${timeout}s)..."
	f_kctl -n "${namespace}" wait --for=condition=complete "job/${job}" --timeout="${timeout}s"
}

function deploy_s2_system() {
	local deployment_specs_dir="${1}"
	local namespace="${2}"

	kustomize ${k_build_params} ${deployment_specs_dir} | kubectl apply -f -
	# openbao-init triggers and waits for job/openbao-import-bootstrap when import auth is enabled.
	wait_for_job_complete "${namespace}" openbao-init 1200
}

function deploy_app() {
	local app=${1}
	local namespace=$(get_apps_namespace $app)
	install_docker_credentials $namespace
	f_kctl -n "$namespace" delete jobs --all
	case "${app}" in
		"mongodb"|"external-secrets")
			kustomize ${k_build_params} ${kustomize_dir}/environments/${s2_deployment_name}/${app} | kubectl apply --force-conflicts --server-side -f -
			;;
		"apisix")
			migrate_apisix "$namespace" "${kustomize_dir}/environments/${s2_deployment_name}/${app}"
			;;
		"cert-manager")
			deploy_cert_manager "${kustomize_dir}/environments/${s2_deployment_name}/${app}"
			;;
		"s2-system")
			deploy_s2_system "${kustomize_dir}/environments/${s2_deployment_name}/${app}" "${namespace}"
			;;
		*)
			kustomize ${k_build_params} ${kustomize_dir}/environments/${s2_deployment_name}/${app} | kubectl apply -f -
	esac

	echo "Wait up to 5 minutes for namespace to stabilize"
	local counter=0
	while [[ "${counter}" -lt 30 ]]
	do
		local pod_status
		pod_status="$(f_kctl get pods -n "$namespace" --no-headers)"
		local pod_count
		pod_count=$(echo "$pod_status" | awk '!/Completed/{n = split($2, a, "/"); if (n == 2 && a[1] != a[2]) print}' | wc -l)
		if [ "$pod_count" -eq 0 ]; then
			break
	fi
		echo "Still waiting for ${namespace} namespace..."
		sleep 10
		counter=$((counter+1))
	done
	if [[ "${counter}" -ge 30 ]]
	then
		echo "Waiting timetout for ${namespace} exceeded. Continuing with installation"
	fi
}

function deploy_apps() {
	for app in $(get_list_of_apps)
	do
		if [[ ! "${app}" =~ ^(s2ap|apps)$ ]]
		then
			deploy_app "${app}"
		fi
	done
}

function install_helm () {
	HELM_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
	if test "${NON_ROOT}" == "Y"; then
		curl "${HELM_INSTALL_SCRIPT_URL}" | USE_SUDO="false" HELM_INSTALL_DIR="${s2_bin_dir}" bash
	else
		curl "${HELM_INSTALL_SCRIPT_URL}" | bash
	fi
}

function install_teleport() {
	local version=$1
	local cluster_name=$2
	local env=$3
	local s2_inst=""
	local customer=""

	echo
	echo "${bold}Teleport Kube-Agent Installation${normal}"
	echo "================================="

	# Load config if it exists
	if [ -f "${S2CTL_CONFIG}" ]
	then
		source "${S2CTL_CONFIG}"
		echo "Loaded configuration from ${S2CTL_CONFIG}"
	fi

	# Get S2_INST from config (s2_instance variable in config file)
	if [ -n "${s2_instance}" ]
	then
		s2_inst="${s2_instance}"
	fi

	# If still empty, prompt user
	if [ -z "${s2_inst}" ]
	then
		ask_question s2_inst "" "Enter S2_INST (e.g., alkira-dev)"
	fi

	# Parse customer from S2_INST by stripping known environment/infrastructure suffixes
	# Known suffixes: prod, staging, stage, dev, poc, gke, sandbox, lab, lab1, lab2, pre-prod, cert-lab, etc.
	# e.g., 'alkira-dev' -> 'alkira'
	#       'comcast-bb-staging' -> 'comcast-bb'
	#       'marriott-dev-gke' -> 'marriott'
	#       'verizon-nec-prod' -> 'verizon-nec'
	#       'att-pre-prod' -> 'att'
	customer="${s2_inst}"
	# Order matters: check multi-word suffixes first, then single-word
	local env_suffixes_multi="pre-prod|cert-lab"
	local env_suffixes_single="prod|staging|stage|dev|poc|gke|sandbox|lab[0-9]*"
	# Keep stripping suffixes until no more match
	local prev_customer=""
	while [[ "${customer}" != "${prev_customer}" ]]
	do
		prev_customer="${customer}"
		# Try multi-word suffixes first
		if [[ "${customer}" =~ ^(.+)-(${env_suffixes_multi})$ ]]
		then
			customer="${BASH_REMATCH[1]}"
		# Then try single-word suffixes
		elif [[ "${customer}" =~ ^(.+)-(${env_suffixes_single})$ ]]
		then
			customer="${BASH_REMATCH[1]}"
		fi
	done

	# Validate required parameters
	if [ -z "${env}" ]
	then
		echo "${bold}ERROR:${normal} --env parameter is required for teleport installation"
		echo "Usage: $0 teleport --env <environment>"
		exit 1
	fi

	# Validate version format (semver-like)
	if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]
	then
		echo "${bold}ERROR:${normal} Invalid teleport version format: ${version}. Expected format: X.Y.Z or X.Y.Z-suffix"
		exit 1
	fi

	# Display values and prompt for confirmation
	echo
	echo "The following values will be used for Teleport installation:"
	echo -e "\t${bold}S2_INST${normal}:    ${s2_inst}"
	echo -e "\t${bold}ENV${normal}:        ${env}"
	echo -e "\t${bold}CUSTOMER${normal}:   ${customer}"
	echo -e "\t${bold}VERSION${normal}:    ${version}"
	echo -e "\t${bold}CLUSTER${normal}:    ${cluster_name}"
	echo

	local confirm="N"
	ask_question confirm "Y" "Are these values correct? Y/N"
	if [ "${confirm}" != "Y" ] && [ "${confirm}" != "y" ]
	then
		# Allow user to modify values
		ask_question s2_inst "${s2_inst}" "Enter S2_INST"
		ask_question env "${env}" "Enter ENV"
		ask_question customer "${customer}" "Enter CUSTOMER"
		ask_question version "${version}" "Enter VERSION"
		ask_question cluster_name "${cluster_name}" "Enter CLUSTER_NAME"
	fi

	# Verify required tools
	echo
	echo "Verifying required tools..."
	if ! which helm > /dev/null 2>&1
	then
		echo "helm not found. Installing..."
		install_helm
	fi
	if ! which kubectl > /dev/null 2>&1
	then
		echo "${bold}ERROR:${normal} kubectl not found. Please install kubectl first."
		exit 1
	fi
	if ! which kind > /dev/null 2>&1
	then
		echo "${bold}ERROR:${normal} kind not found. Please install kind first."
		exit 1
	fi

	# Validate kind cluster exists
	echo "Validating cluster ${cluster_name} exists..."
	if ! kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"
	then
		echo "${bold}ERROR:${normal} Cluster ${cluster_name} does not exist. Available clusters:"
		kind get clusters 2>/dev/null | sed 's/^/  - /' || echo "  (none)"
		exit 1
	fi

	# Verify kubectl context
	local current_context=$(kubectl config current-context 2>/dev/null || echo "")
	if [ -z "${current_context}" ]
	then
		echo "kubectl context not set. Setting to kind-${cluster_name}..."
		kubectl config use-context "kind-${cluster_name}" || {
			echo "${bold}ERROR:${normal} Failed to set kubectl context to kind-${cluster_name}"
			exit 1
		}
	fi

	# Build kubeClusterName
	local kube_cluster_name="${customer}-${env}-${cluster_name}"

	# Create teleport namespace if it doesn't exist
	echo "Ensuring teleport namespace exists..."
	kubectl create namespace teleport --dry-run=client -o yaml | kubectl apply -f - || true

	# Ensure imagePullSecret exists in teleport namespace
	echo "Ensuring imagePullSecret s2-regcred exists in teleport namespace..."
	if ! kubectl get secret s2-regcred -n teleport &>/dev/null
	then
		# Try to copy from s2 namespace first
		if kubectl get secret s2-regcred -n s2 &>/dev/null
		then
			echo "Copying s2-regcred secret from s2 namespace to teleport namespace..."
			kubectl get secret s2-regcred -n s2 -o yaml | \
				sed 's/namespace: s2/namespace: teleport/' | \
				sed '/^  uid:/d' | \
				sed '/^  resourceVersion:/d' | \
				sed '/^  selfLink:/d' | \
				kubectl apply -f - || {
				echo "${bold}ERROR:${normal} Failed to copy s2-regcred secret to teleport namespace"
				exit 1
			}
			echo "Successfully copied s2-regcred secret to teleport namespace"
		elif [ -n "${s2_gcp_key}" ] && [ -f "${s2_gcp_key}" ]
		then
			echo "Creating s2-regcred secret from GCP key..."
			install_docker_credentials teleport
		else
			echo "${bold}ERROR:${normal} Secret s2-regcred not found in s2 namespace and no GCP key available."
			echo "Please ensure S2AP is deployed first, or provide --path-to-gcp-key parameter."
			exit 1
		fi
	else
		echo "Secret s2-regcred already exists in teleport namespace"
	fi

	# Add helm repo
	echo "Configuring helm repository..."
	if ! helm repo list 2>/dev/null | grep -q "^teleport[[:space:]]"
	then
		helm repo add teleport https://charts.releases.teleport.dev || {
			echo "${bold}ERROR:${normal} Failed to add teleport helm repository"
			exit 1
		}
		echo "Teleport helm repository added"
	else
		echo "Teleport helm repository already exists"
	fi

	# Update helm repo
	helm repo update teleport || {
		echo "${bold}ERROR:${normal} Failed to update teleport helm repository"
		exit 1
	}
	echo "Helm repositories updated"

	# Check if teleport is already installed at the requested version
	local installed_version=""
	local needs_upgrade=true
	if helm list -n teleport -o json 2>/dev/null | grep -q "teleport-kube-agent"
	then
		installed_version=$(helm list -n teleport -o json | jq -r '.[] | select(.name=="teleport-kube-agent") | .chart' | sed 's/teleport-kube-agent-//')
		echo "Currently installed version: ${installed_version}"
		if [ "${installed_version}" == "${version}" ]
		then
			echo "Requested version ${version} is already installed."
			# Check if pods are running
			if kubectl get statefulset teleport-kube-agent -n teleport &>/dev/null
			then
				local ready_replicas=$(kubectl get statefulset teleport-kube-agent -n teleport -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
				local desired_replicas=$(kubectl get statefulset teleport-kube-agent -n teleport -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
				if [ "${ready_replicas}" == "${desired_replicas}" ] && [ "${ready_replicas}" != "0" ]
				then
					echo "All ${ready_replicas}/${desired_replicas} pods are running and ready."
					echo
					echo "${bold}Teleport is already installed and running at version ${version}. No action needed.${normal}"
					return 0
				else
					echo "Pods not fully ready (${ready_replicas}/${desired_replicas}). Will verify deployment..."
					needs_upgrade=false
				fi
			fi
		else
			echo "Upgrading from ${installed_version} to ${version}..."
		fi
	else
		echo "Teleport not currently installed. Installing version ${version}..."
	fi

	# Perform helm install/upgrade if needed
	if [ "${needs_upgrade}" = true ]
	then
		echo
		echo "Installing/upgrading teleport ${version} on cluster ${cluster_name}..."
		helm upgrade --install teleport-kube-agent teleport/teleport-kube-agent \
			--namespace teleport \
			--create-namespace \
			--version "${version}" \
			--set kubeClusterName="${kube_cluster_name}" \
			--set labels.s2_inst="${s2_inst}" \
			--set labels.env="${env}" \
			--set labels.customer="${customer}" \
			--set updater.enabled=false \
			--set kubernetesService.enabled=true \
			--set enterprise=true \
			--set highAvailability.replicaCount=2 \
			--set enterpriseImage=us-central1-docker.pkg.dev/s2-infra/s2images/s2-teleport-ent-distroless \
			--set imagePullSecrets[0].name=s2-regcred \
			--set joinParams.method=gcp \
			--set joinParams.tokenName=teleport-gke-join-token \
			--set proxyAddr=selector.teleport.sh:443 \
			--set roles=kube \
			--set updater.image=us-central1-docker.pkg.dev/s2-infra/s2images/s2-teleport-kube-agent-updater || {
			echo "${bold}ERROR:${normal} Failed to install/upgrade teleport ${version} on cluster ${cluster_name}"
			exit 1
		}
	fi

	# Wait for StatefulSet rollout to complete
	echo
	echo "Waiting for teleport pods to be ready (max 3 minutes)..."

	if ! kubectl rollout status statefulset/teleport-kube-agent -n teleport --timeout=180s 2>&1
	then
		echo "${bold}ERROR:${normal} Teleport rollout did not complete within 3 minutes"
		echo "Current pod status:"
		kubectl get pods -n teleport 2>&1 || true
		echo "StatefulSet status:"
		kubectl get statefulset teleport-kube-agent -n teleport 2>&1 || true
		echo "Pod events:"
		kubectl get events -n teleport --sort-by='.lastTimestamp' 2>&1 | tail -20 || true
		exit 1
	fi

	# Final verification
	local final_ready=$(kubectl get statefulset teleport-kube-agent -n teleport -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
	local final_desired=$(kubectl get statefulset teleport-kube-agent -n teleport -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
	echo "Teleport pods ready: ${final_ready}/${final_desired}"

	echo
	echo "${bold}Teleport installation completed successfully!${normal}"
}

function delete_jobs() {
	for JOB in $(kubectl -n s2 get jobs --no-headers=true | awk '{ print $1 }')
	do
		kubectl -n s2 delete job $JOB
	done
}

function update_kind_config_properties {
	dont_ask_s2_name=$1
	local config_properties_filepath="${s2_deploy_dir}"/kustomize/environments/"${s2_deployment_name}"/components/config/config.properties
	local overwrite_s2_instance="N"
	source "${config_properties_filepath}"
	if [ -z "$s2_instance" ] && [ "$dont_ask_s2_name" == 'Y' ]
	then
		echo "Overwrite for S2_INSTANCE not found. Going to use ${bold}S2_INSTANCE = ${S2_INSTANCE}${normal}"
	elif [ -z "$s2_instance" ]
	then
		echo "Overwrite for S2_INSTANCE not found. Would you like to change it? (original value was: ${S2_INSTANCE})"

		ask_question overwrite_s2_instance $overwrite_s2_instance "Would you like to change S2_INSTANCE value? (Curently set to ${S2_INSTANCE}) Y/N"
		if [[ "${overwrite_s2_instance}" != "N" ]]
		then
			ask_question s2_instance $S2_INSTANCE "Provide S2_INSTANCE name"
			S2_INSTANCE=$s2_instance
			sed -i "s;S2_INSTANCE=.*;S2_INSTANCE=${S2_INSTANCE};g" "${config_properties_filepath}"
		fi
	else
		echo "Overwrite for S2_INSTANCE found. Going to use ${bold}S2_INSTANCE = ${s2_instance}${normal} (original value was: ${S2_INSTANCE})"
		S2_INSTANCE=${s2_instance}
		sed -i "s;S2_INSTANCE=.*;S2_INSTANCE=${S2_INSTANCE};g" "${config_properties_filepath}"
	fi

	if [ -z "$s2_fqdn" ]
	then
		echo "s2_fqdn is not set, no overwrite for S2_NAME, S2_INGRESS_DOMAIN_MAIN, S2_INGRESS_DOMAIN_MON and S2_INGRESS_DOMAIN_ENGINE. "
		if [ -z "$s2_name" ]
		then
			echo "Overwrite for S2_NAME not found. Going to use ${bold}S2_NAME = ${S2_NAME}${normal}"
		else
			echo "Overwrite for S2_NAME found. Going to use ${bold}S2_NAME = ${s2_name}${normal} (original value was: ${S2_NAME})"
			S2_NAME=${s2_name}
			sed -i "s;S2_NAME=.*;S2_NAME=${S2_NAME};g" "${config_properties_filepath}"
		fi
	else
		echo "Overwrite for S2_FQDN found. Going to use ${bold}S2_FQDN = ${s2_fqdn}${normal} (original value was: ${S2_FQDN})"
		S2_FQDN=${s2_fqdn}
		sed -i "s/S2_INGRESS_DOMAIN_MON=.*$/S2_INGRESS_DOMAIN_MON=${s2_fqdn/\./-mon.}/" "${config_properties_filepath}"
		sed -i "s/S2_INGRESS_DOMAIN_ENGINE=.*$/S2_INGRESS_DOMAIN_ENGINE=${s2_fqdn/\./-engine.}/" "${config_properties_filepath}"
		sed -i "s/S2_INGRESS_DOMAIN_REGISTRY=.*$/S2_INGRESS_DOMAIN_REGISTRY=${s2_fqdn/\./-registry.}/" "${config_properties_filepath}"
		sed -i "s/S2_INGRESS_DOMAIN_MAIN=.*$/S2_INGRESS_DOMAIN_MAIN=${s2_fqdn}/" "${config_properties_filepath}"
		if [ -z "$s2_name" ]
		then
			sed -i "s;S2_NAME=.*;S2_NAME=https://"$s2_fqdn";g" "${config_properties_filepath}"
		else
			echo "Overwrite for S2_NAME found. Going to use ${bold}S2_NAME = ${s2_name}${normal} (original value was: ${S2_NAME})"
			S2_NAME=${s2_name}
			sed -i "s;S2_NAME=.*;S2_NAME=${S2_NAME};g" "${config_properties_filepath}"
		fi
	fi
}

function delete_old_resources() {
	local application="${1}"
	local specs_path="${s2_deploy_dir}/kustomize/environments/${s2_deployment_name}/${application}"

	kinds_from_specs="$(kustomize ${k_build_params} ${specs_path} | yq e -o json | jq -r .kind | sort -u)"
	deployed_version="$(kubectl -n s2 get cm s2-config -o jsonpath='{.data.S2_VERSION}')"

	echo "Checking for resources ${bold}older than ${deployed_version}${normal}"

	local objectsToDelete=$(
		for kind in $kinds_from_specs
		do
			if [ "${kind}" != "Job" ]
			then
				kubectl get $kind --all-namespaces -o jsonpath='{range .items[?(@.metadata.annotations.selector\.ai/component=="s2ap")]}{.kind}{","}{.metadata.namespace}{","}{.metadata.name}{","}{.metadata.annotations.s2ap\.selector\.ai/version}{"\n"}{end}' | grep -v ${deployed_version}
			fi
		done
	)
	if [ -z "$objectsToDelete" ]
	then
		echo "There are no detected obsolete objects"
	else
		echo "List of detected obsolete objects"
		for object in $objectsToDelete
		do
			local kind="$(echo $object | awk -F ',' '{print $1}')"
			local namespace="$(echo $object | awk -F ',' '{print $2}')"
			local name="$(echo $object | awk -F ',' '{print $3}')"
			local version="$(echo $object | awk -F ',' '{print $4}')"
			if [ -z "$version" ]
			then
				version="unknown"
			fi
			if [ -z "$namespace" ]
			then
				echo -e "kind: ${bold}${kind}${normal}\tname: ${bold}${name}${normal}\tversion: ${bold}${version}${normal}"
			else
				echo -e "kind: ${bold}${kind}${normal}\tname: ${bold}${name}${normal}\tversion: ${bold}${version}${normal}\tnamespace: ${bold}${namespace}${normal}"
			fi
		done
		ask_question "delete_obsolete" "N" "Do you want to delete objects from list? Y/N"
		if [ "${delete_obsolete}" == "Y" ]
		then
			echo "Deleting obsolete resources from list"
			for object in $objectsToDelete
			do
				delete_object $object
			done
		fi
	fi

}

function apply_s2ap_specs() {
	download_s2m_specs=$1
	wait_for_completed=$2
	apply_configuration=$3
	install_docker_credentials s2
	delete_jobs
	s2ap_base_path="${s2_deploy_dir}/kustomize/environments/${s2_deployment_name}/s2ap"

	if [ "${apply_configuration}" == "N" ]
	then
		kustomize ${k_build_params} ${s2ap_base_path} | yq e -o json | jq 'del( select(.kind == "Job"))' | kubectl apply -f -
	else
		kustomize ${k_build_params} ${s2ap_base_path} | kubectl apply -f -
	fi
	if [ ! -z "$wait_for_completed" ]
	then
		echo "Waiting for deployment to complete for max $wait_for_completed minutes"
		minutes_left=$wait_for_completed
		counter=0
		while true
		do
			local pod_status
			pod_status="$(f_kctl get pods -n s2 --no-headers)"
			local pod_count
			pod_count=$(echo "$pod_status" | awk '!/Completed/{n = split($2, a, "/"); if (n == 2 && a[1] != a[2]) print}' | wc -l)
			if [ "$pod_count" -eq 0 ]; then
				break
    		fi

			sleep 10
			echo -n "."
			counter=$((counter+1))
			if [ $counter -eq 6 ]
			then
				counter=0
				minutes_left=$((minutes_left-1))
				if [ $minutes_left -gt 0 ]
				then
					echo -e "\nGoing to wait not longer than $minutes_left minutes"
				else
					echo -e "\nDeadline exceeded!"
					exit 1
				fi
			fi
		done
		echo -e "\nDone"
		if [ "$download_s2m_specs" == "Y" ]
		then
			extract_from_s2deploy s2ctl_with_specs
		fi
	fi
}

function refresh_ingress_specs() {
	# Generate specs for manipulations
	local s2ap_base_path="${s2_deploy_dir}/kustomize/environments/${s2_deployment_name}/s2ap"
	local specs_file=$(mktemp)
	defer rm "${specs_file}"
	kustomize ${k_build_params} ${s2ap_base_path}  > ${specs_file}

	# Create list of objects
	local resources_list="ApisixPluginConfig ApisixRoute Ingress"

	# Delete all related specs
	for resource in $resources_list
	do
		kubectl -n s2 delete $resource --all
	done
	echo "Waiting 60s for establishing Ingress state"
	sleep 60
	# Render and apply Ingress definitions
	counter=0
	for resource in $resources_list
	do
        	if [[ $counter -eq 0 ]]
	        then
	                yqquery="select(.kind==\"${resource}\""
	        else
	                yqquery="${yqquery} or .kind==\"${resource}\""
	        fi
	        counter=$((counter+1))
	done
	yqquery="${yqquery})"

	yq e "${yqquery}" ${specs_file} | kubectl apply -f -
	echo "Waiting 60s for establishing Ingress state"
}

function extract_from_s2deploy() {
	parameter=$1
	config_dir="$s2_deploy_dir/config"

cat <<EOF | kubectl apply -n s2 -f -
apiVersion: v1
kind: Pod
metadata:
  name: s2ml-extractor
spec:
  containers:
  - name: runner
    image: $(kubectl -n s2 get sts s2-explorer -o=jsonpath='{.spec.template.spec.initContainers[0].image}')
    args:
    - sleep
    - "86400"
EOF
	counter=60
	while [ $counter -gt 0 ] && [ $(kubectl -n s2 get pods s2ml-extractor | grep -c Running) -ne 1 ]
	do
		echo "Waiting for pod s2ml-extractor"
		sleep 10
		counter=$((counter-1))
	done
	s2_repo_container=$(kubectl  -n s2 get pods --no-headers -o custom-columns=":metadata.name" -l app=s2-repo)
	kubectl cp s2/${s2_repo_container}:/usr/share/nginx/html/bin/linux/s2ctl $config_dir/s2ctl
	${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 $config_dir/s2ctl ${s2_bin_dir}/s2ctl
	if [ "${parameter}" == "s2ctl_with_specs" ]
	then
	        backup_dir "$config_dir"
	        mkdir -p "$config_dir"
		mkdir -p "$config_dir/base"
		mkdir -p "$config_dir/$s2_deployment_name"
		kubectl cp s2/s2ml-extractor:/deploy/scripts/get_reports.py $config_dir/get_reports.py
		${sudo} install -o ${os_user} -g ${os_user_group} -m 0755 $config_dir/get_reports.py ${s2_bin_dir}/get_reports.py
		kubectl cp s2/s2ml-extractor:/deploy/base/services "$config_dir/base/services"
		kubectl cp s2/s2ml-extractor:/deploy/base/s2ml-common "$config_dir/base/s2ml-common"
		kubectl cp s2/s2ml-extractor:/deploy/$s2_deployment_name/services "$config_dir/$s2_deployment_name/services"
		kubectl cp s2/s2ml-extractor:/deploy/$s2_deployment_name/s2ml "$config_dir/$s2_deployment_name/s2ml"
		(cd $config_dir; git init .; git add .; git commit -a -m "First Commit")
	fi
	kubectl -n s2 delete pod s2ml-extractor
}

function print_diff_version() {
	#Print s2ctl.sh and s2ctl version and build difference
	if ! which s2ctl > /dev/null 2>&1
	then
		echo "S2ctl binary doesnt exist in $PATH"
		exit 1
	fi
	echo "s2ctl.sh and s2ctl binary version difference Info"
	echo "================================================="
	bin_date=$( s2ctl version |grep BuildTime |awk '{print $3}' |awk -F'T' '{print $1}')
	if [ ${os_family} == "darwin" ]; then
		shfile_date=$(stat -f %Sm -t %Y-%m-%d s2ctl.sh)
		shfile_time=$(date -j -f "%Y-%m-%d"  $shfile_date +%s)
		bin_time=$(date -j -f "%Y-%m-%d" $bin_date +%s)
	else
		shfile_date=$(stat --printf="%y"  s2ctl.sh|awk  '{print $1}')
		shfile_time=$(date "+%s" -d $shfile_date)
		bin_time=$(date "+%s" -d $bin_date)
	fi

	diff_in_days=$((echo "($shfile_time-$bin_time)/86400") | bc)
	if [ -z "$bin_date" ] || [ -z "$shfile_date" ]; then
		echo "Could not fetch version timestamp for one of the files"
	fi

	if test $diff_in_days -eq 0; then
	    echo "Congrats !!! s2ctl binary and s2ctl.sh are on same version dated $shfile_date"
	elif test $diff_in_days -gt 0; then
	   echo "Shell Script s2ctl.sh is more recent than s2ctl binary by $diff_in_days days"
	elif test $diff_in_days -lt 0; then
	   echo "s2ctl Binary file is more recent than shell Script by ${diff_in_days#-} days"
	fi

	echo $DIFF
}


function apply_configs() {
	# Set S2_NAME env
 	export S2_NAME=$(kubectl -n s2 get cm s2-config -o jsonpath='{.data.S2_NAME}')
	echo $S2_NAME
	# Check if config folder with base specs is present
	config_dir="$s2_deploy_dir/config"
	if [ ! -d "${config_dir}/base" ]
	then
		echo "There is no folder with base configuration files"
		echo "Please execute \"$0 gets2mspecs\" first"
		exit 1
	fi
	TMPDIR=$(mktemp -d)
	defer rm -r "${TMPDIR}"

	if [ -z "$1" ]
	then
		echo "Applying all configurations"
		cp -r "${config_dir}/base/services" "${TMPDIR}"
		cp -r "${config_dir}/${s2_deployment_name}/services" "${TMPDIR}"
	else
		echo "Applying configuration for $1"
		mkdir -p "${TMPDIR}/services"
		if [ -d "${config_dir}/base/services/${1}" ]
		then
			cp -r "${config_dir}/base/services/${1}" "${TMPDIR}/services"
		fi
		if [ -d "${config_dir}/${s2_deployment_name}/services/${1}" ]
		then
			cp -r "${config_dir}/${s2_deployment_name}/services/${1}" "${TMPDIR}/services"
		fi
	fi

	# Render dedicated config
	for PATCHFILE in $( find ${TMPDIR}/services -type f -iname 'patch.*.yaml'; echo; find ${TMPDIR}/services -type f -iname 'patch.*.yml' )
	do
		echo "Found $PATCHFILE to apply"
		relative_path=$(echo $PATCHFILE | sed -e "s;${TMPDIR}/;;")
		relative_src_path=$(echo $PATCHFILE | sed -e "s;${TMPDIR}/;;" -e 's/patch.//g')
		if [ -f "${config_dir}/base/${relative_src_path}" ];
		then
			spruce merge "${config_dir}/base/${relative_src_path}" "${PATCHFILE}" > "${TMPDIR}/${relative_src_path}"
		else
			echo "Can't find ${relative_src_path} to patch with ${relative_path}"
		fi
		rm "${TMPDIR}/${relative_path}"
	done
	# Create ConfigMaps from dir
	for CONF_PATH in ${TMPDIR}/services/
	do
		for CONFIG in $( find ${CONF_PATH} -mindepth 1 -type d | sed 's#//*#/#g' )
		do
		    if [[ $CONFIG == *prometheus* ]]; then
				echo "$CONFIG: processing prometheus configmap apply"
				spruce merge "${CONFIG}/prometheus.yml" > "${CONFIG}/prometheus.yml.tmp" && mv "${CONFIG}/prometheus.yml.tmp" "${CONFIG}/prometheus.yml"
			fi
			CONFIG_NORMALIZED=$(echo $CONFIG | sed "s:${CONF_PATH}::g" | tr '/' '-')
			echo "Set configmap s2-${CONFIG_NORMALIZED}"
			kubectl create configmap s2-${CONFIG_NORMALIZED} --from-file=$CONFIG --dry-run=client -o yaml | grep -v creationTimestamp | kubectl apply -f -
		done
	done
}

function delete_kind_cluster() {
	delete_kind_setup=N
	if [ "$YES_TO_ALL" == "N" ]
	then
		ask_question delete_kind_setup $delete_kind_setup "Going to delete kind cluster. Proceed? Y/N"
	else
		delete_kind_setup=$YES_TO_ALL
	fi
	if [ "$delete_kind_setup" == "Y" ]
	then
		kind delete cluster
		if [ -f ${s2_bin_dir}/s2ctl ]
		then
			echo "Deleting ${bold}${s2_bin_dir}/s2ctl${normal}"
			${sudo} rm ${s2_bin_dir}/s2ctl
		fi
		if [ -f ${s2_bin_dir}/get_reports.py ]
		then
			echo "Deleting ${bold}${s2_bin_dir}/get_reports.py${normal}"
			${sudo} rm ${s2_bin_dir}/get_reports.py
		fi
	fi
}

function configure_cdpath() {
	# Prepare CDPATH entry
	entry="export CDPATH='.:/${s2_deploy_dir}/:'/${s2_deploy_dir}/config/${s2_deployment_name}/ #s2ctl.sh generated"
	# check if there is CDPATH already
	if ! grep '#s2ctl.sh generated' ~/.bashrc
	then
		sed -i "s;export CDPATH=.*#s2ctl.sh generated;${entry}/g" ~/.bashrc
	else
		echo $entry >> ~/.bashrc
	fi

	export ${entry}
}

function configure_env_and_tools(){
	echo "Using config file: ${bold}${S2CTL_CONFIG}${normal}"
	echo "If you want to use different file please set ${bold}S2CTL_CONFIG${normal} env variable"

	if [ -f ${S2CTL_CONFIG} ]
	then
		source ${S2CTL_CONFIG}
	fi

	echo "Determining toolset"
	check_toolset

	if ! which $toolset > /dev/null 2>&1
	then
		echo -e "Missing one of tools from list:\n\t${bold}$toolset${normal}"
		echo "Installing/updating required tools"
		install_toolset "$toolset"
		which $toolset
	fi

	# Requires jq to parse kubectl version
	echo "Checking tool versions"
	check_tools_version "${toolset}"

	# Requires jq to parse s2_deployment
	echo "Configuring environment"
	set_variables
}

function set_variables() {
	local gpg_key_default_path='~/.s2ctl/gpg.yaml'
	if [ -z ${gpg_key_default_path} ]
	then
		touch ~/.s2ctl/gpg.yaml
	fi

	### Check if kubeconfig already exists in s2ctl configuration folder, if so set KUBECONFIG variable
	if [ -f "$(dirname ${S2CTL_CONFIG})/kubeconfig" ]
	then
		export KUBECONFIG="$(dirname ${S2CTL_CONFIG})/kubeconfig"
	else
		get_kubeconfig
	fi

	for config_variable in "${!CONFIG_ENV_VARS[@]}"
	do
		if [ ! -z "${!config_variable}" ]
		then
			eval ${config_variable,,}="${!config_variable}"
		fi
	done

	if [ -z "$s2_gcp_key" ]
	then
		ask_question s2_gcp_key '~/.s2ctl/gcp.json' "Path to GCP JSON key"
	fi
	if [ -z "$s2_gpg_key" ]
	then
		ask_question s2_gpg_key "$gpg_key_default_path" "Path to GPG key"
	fi
	if [ -z "$s2_deploy_dir" ]
	then
		ask_question s2_deploy_dir '/opt/s2/deployments' "Directory to store deployment specs"
	fi
	if [ "$dont_ask_s2_name" == "N" ]
	then
		if [ -z "${s2_name+empty}" ]
		then
			ask_question s2_name '' "Custom ${bold}S2_NAME${normal} - url format. Provide only if you want to ${bold}overwrite value from ${s2_deploy_dir}/kustomize/environments/${s2_deployment_name}/s2ap${normal}"
		fi
		if [ -z "${s2_instance+empty}" ]
		then
			ask_question s2_instance '' "Custom ${bold}S2_INSTANCE${normal}. Provide only if you want to ${bold}overwrite value from ${s2_deploy_dir}/kustomize/environments/${s2_deployment_name}/s2ap${normal}"
		fi
	fi
	if [ -z "${s2_fqdn+empty}" ]
	then
		ask_question s2_fqdn '' "Custom ${bold}S2_FQDN${normal}. Provide only if you want to change fqdn of the setup"
	fi

	# Get deployment name
	if [ -z "${s2_deployment_name+empty}" ]
	then
		if [ -n "$s2_gcp_key" ] && [ -s "$s2_gcp_key" ]
		then
			s2_deployment_name=$(jq -r .client_email $s2_gcp_key | sed -e 's/customer-sa-//' -e 's/\@s2-infra.iam.gserviceaccount.com//')
		else
			ask_question s2_deployment_name '' "Provide s2 deployment name, for example "default""
		fi
	fi

	echo
	print_config
	echo
	save_config
}

function config_core_dns() {
	if [[ $COREDNS_CONFIG ]]; then
		echo "Apply coredns config from path: ${COREDNS_CONFIG}"
		if [[ ! -f "${COREDNS_CONFIG}" ]]
		then
			echo "Path ${COREDNS_CONFIG} does not exists. Script stopped."
			exit 1
		fi
		kubectl scale deployment -n kube-system coredns --replicas=0
		kubectl delete configmap -n kube-system coredns
		kubectl create configmap -n kube-system coredns --from-file=Corefile="${COREDNS_CONFIG}"
		kubectl scale deployment -n kube-system coredns --replicas=2
	fi
}

function check_installed_version() {
	if [ -f "${kustomize_dir}/environments/${s2_deployment_name}/components/config/config.properties" ]
	then
			echo "Installing version ${bold}"$(grep "S2_VERSION" "${kustomize_dir}/environments/${s2_deployment_name}/components/config/config.properties" | sed 's/.*=//')"${normal} of ${bold}${s2_deployment_name}${normal}"
	else
			echo "Deployment not found"
			exit 1
	fi
}

function get_kubeconfig() {
	echo "Creating new kubeconfig base on: ~/.kube/config"
	if [[ ! -f ~/.kube/config ]]
	then
		echo "There is no kubeconfig set on machine."
	else
		if kubectl config view --minify --flatten > "$(dirname ${S2CTL_CONFIG})/kubeconfig"
		then
				export KUBECONFIG="$(dirname ${S2CTL_CONFIG})/kubeconfig"
		else
				rm "$(dirname ${S2CTL_CONFIG})/kubeconfig" || echo "There is no $(dirname ${S2CTL_CONFIG})/kubeconfig file, skipping"
		fi
	fi
}

function env_connection_verify() {
	local config_properties_filepath="${s2_deploy_dir}"/kustomize/environments/"${s2_deployment_name}"/components/config/config.properties
	install_env=no
	RED='\033[0;31m'
	RESET='\033[0m'
	if kubectl get namespace s2 &> /dev/null
	then
		config_s2_name=$(cat ${config_properties_filepath} | grep S2_NAME | awk -F= '{print $2}')
		config_s2_setup=$(cat ${config_properties_filepath} | grep S2_SETUP | awk -F= '{print $2}')
		remote_s2_name=$(kubectl -n s2 get configmap s2-config -o=jsonpath="{.data.S2_NAME}")
		remote_s2_setup=$(kubectl -n s2 get configmap s2-config -o=jsonpath="{.data.S2_SETUP}")
		if kubectl -n s2 get configmap s2-config > /dev/null 2>&1
		then
			if [ "${config_s2_name}" != "${remote_s2_name}" ] || [ "${config_s2_setup}" != "${remote_s2_setup}" ]
			then
				echo  -e "${RED}${bold}!!!WARNING!!!${normal}${RESET}"
				ask_question install_env $install_env "It looks like your local config does not match kubernetes cluster that you want to perform installation on. Are you sure you want to do installation? (yes/no): "
				if [ "${install_env}" = "yes" ]
				then
					install_env=no
					echo -e "${RED}${bold}This may break installation on cluster ${remote_s2_name}.${normal}${RESET}"
					ask_question install_env $install_env "Are you REALLY SURE you want to do installation?(yes/no): "
					if [ "${install_env}" = "yes" ]
					then
						echo "Proceeding with the script."
					else
						echo "Installation canceled!"
						exit 1
					fi
				else
					echo "Installation canceled!"
					exit 1
				fi
			fi
		fi
fi
}

function upgrade_app() {
	local app_to_upgrade="${1}"
	local download_s2m_specs="${2}"
	local wait_for_completed="${3}"
	local wipe_versions=""
	local on_cluster=""
	local in_specs=""
	local confirm_wipe="N"

	echo
	echo "Upgrading ${app_to_upgrade}"
	echo

	# Strimzi 0.45/0.51 -> 1.0 requires wipe + kafka then s2ap. kafka-only upgrade cannot do this.
	if [ "${app_to_upgrade}" = "kafka" ] || [ "${app_to_upgrade}" = "s2ap" ]
	then
		if wipe_versions="$(strimzi_v1_wipe_versions)"
		then
			on_cluster="${wipe_versions%% *}"
			in_specs="${wipe_versions#* }"

			if [ "${app_to_upgrade}" = "kafka" ]
			then
				echo "ERROR: current Strimzi version is ${on_cluster} and upcoming is ${in_specs}."
				echo "Only kafka upgrade will not work for this jump. Run: $(basename "$0") upgrade s2ap"
				exit 1
			fi

			# s2ap upgrade: confirm wipe, then install kafka operator before s2ap.
			echo ""
			echo "WARNING: Strimzi on cluster is ${on_cluster}; specs want ${in_specs}."
			echo "This will DELETE Kafka ${on_cluster} (operator, CRs, PVCs) — DATA LOSS —"
			echo "then upgrade kafka and continue with s2ap to ${in_specs}."
			echo ""
			if [ "${YES_TO_ALL}" == "N" ]
			then
				ask_question confirm_wipe "N" "Delete Kafka ${on_cluster} and allow ${in_specs} upgrade (kafka + s2ap)? Y/N"
			else
				confirm_wipe="${YES_TO_ALL}"
			fi
			if [ "${confirm_wipe}" != "Y" ] && [ "${confirm_wipe}" != "y" ]
			then
				echo "Aborted: Kafka ${on_cluster} was not deleted."
				exit 1
			fi
			wipe_strimzi_kafka_cluster
			echo "Old Strimzi removed — upgrading kafka before s2ap."
			deploy_app kafka
		fi
	fi

	if [ "${app_to_upgrade}" = "s2ap" ]
	then
		apply_s2ap_specs ${download_s2m_specs} "${wait_for_completed}" "Y"
	else
		deploy_app "${app_to_upgrade}"
	fi
}


if [ $# -eq 0 ]
then
	echo "Illegal number of parameters"
	help
	exit 1
fi


if ! options=$(getopt -l "$(printf "%s:," "${!CONFIG_PARAMS_WITH_OPTIONS[@]}"),$(printf "%s," "${!CONFIG_PARAMS_NO_OPTIONS[@]}")", -o "" -a -n "$(basename $0)" -- "$@")
then
	echo "There was problem with parsing parameters"
	help
	exit 1
fi
eval set -- "$options"

while true
do
	case $1 in
		-yes2all|--yes2all)
			YES_TO_ALL=Y
			;;
		-no-setns|--no-setns)
			configure_s2_ns_as_default=N
			;;
		-download-s2mspecs|--download-s2mspecs)
			if [ -z "$wait_for_completed" ] ; then wait_for_completed=30; fi
			download_s2m_specs=Y
			;;
		-path-to-gcp-key|--path-to-gcp-key)
			shift
			S2_GCP_KEY="$1"
			;;
		-path-to-gpg-key|--path-to-gpg-key)
			shift
			S2_GPG_KEY="$1"
			;;
		-deployment-dir|--deployment-dir)
			shift
			S2_DEPLOY_DIR="$1"
			;;
		-fqdn|--fqdn)
			shift
			S2_FQDN="$1"
			;;
		-wait|--wait)
			shift
			wait_for_completed="$1"
			;;
		-remote|--remote)
			s2_remote_installation=Y
			;;
		-dont-ask-s2-name|--dont-ask-s2-name)
			dont_ask_s2_name=Y
			;;
		-bin-dir|--bin-dir)
			shift
			s2_bin_dir="$1"
			;;
		-config|--config)
			shift
			S2CTL_CONFIG="$1"
			;;
		-config-core-dns|--config-core-dns)
			shift
			COREDNS_CONFIG="$1"
			;;
		-skip-specs-update|--skip-specs-update)
			SKIP_SPECS_UPDATE=Y
			;;
		-non-root|--non-root)
			NON_ROOT=Y
			;;
		-env|--env)
			shift
			teleport_env="$1"
			;;
		-teleport-version|--teleport-version)
			shift
			teleport_version="$1"
			;;
		-cluster-name|--cluster-name)
			shift
			teleport_cluster_name="$1"
			;;
		--)
			shift
			break
			;;
	esac
	shift
done

# disable use of root user/group and sudo
# this requires that some dependencies are installed manually
if test "${NON_ROOT}" == "Y"; then
	sudo=""
	os_user_group="$(id -g)"
	os_user="$(id -u)"
else
	sudo="sudo"
fi

case $1 in
	"install")
		configure_env_and_tools
		download_specs
		update_kind_config_properties $dont_ask_s2_name
		check_installed_version
		if [[ "${s2_remote_installation}" == "N" ]]; then configure_kind_cluster; fi
		env_connection_verify
		configure_namespaces $configure_s2_ns_as_default
		config_core_dns
		deploy_apps
		apply_s2ap_specs ${download_s2m_specs} "${wait_for_completed}" "Y"
		;;
	"upgrade")
		configure_env_and_tools
		download_specs
		update_kind_config_properties $dont_ask_s2_name
		check_installed_version
		shift
		if [ -z "${1}" ]; then app_to_upgrade="s2ap"; else app_to_upgrade="${1}"; fi
		upgrade_app "${app_to_upgrade}" "${download_s2m_specs}" "${wait_for_completed}"
		delete_old_resources "${app_to_upgrade}"
		;;
	"download")
		configure_env_and_tools
		download_specs
		;;
	"uninstall")
		if [[ "${s2_remote_installation}" == "N" ]]; then delete_kind_cluster; fi
		if [ -f ${S2CTL_CONFIG} ] ; then rm ${S2CTL_CONFIG}; fi
		if [ -f "$(dirname ${S2CTL_CONFIG})/kubeconfig" ] ; then rm "$(dirname ${S2CTL_CONFIG})/kubeconfig"; fi
		;;
	"gets2mspecs")
		configure_env_and_tools
		extract_from_s2deploy s2ctl_with_specs
		;;
	"gets2ctl")
		configure_env_and_tools
		extract_from_s2deploy s2ctl_only
		;;
	"configureCDPATH")
		configure_env_and_tools
		configure_cdpath
		;;
	"depsinstall")
		install_toolset "$toolset"
		;;
	"applyConfig")
		shift
		configure_env_and_tools
		apply_configs "$1"
		;;
	"refreshIngress")
		configure_env_and_tools
		refresh_ingress_specs
		;;
	"deleteObsoleteResources")
		configure_env_and_tools
		delete_old_resources
		;;
	"teleport")
		install_teleport "${teleport_version}" "${teleport_cluster_name}" "${teleport_env}"
		;;
	"not-ready")
		kubectl get --show-kind pods,deploy,sts -n s2 | grep -v -e '0/0' -e '1/1' -e '2/2' -e '3/3'
		;;
	"watch")
		watch -n 10 -c "${0} not-ready"
		;;
	"versionInfo")
		print_diff_version
		;;
	*)
		help
		;;
esac
