#!/usr/bin/env bash
#
# Run the working tree's collection scripts against a live cluster without
# building or pushing an image.
#
# The scripts are tarred up, carried into a stock must-gather pod, unpacked
# to /tmp/better-gather-odf and run from there. Because every collection script
# sources "$(dirname "$0")/common.sh", running them from that directory picks
# up the modified common.sh and since_common.sh automatically.
#
# Turns a change-test cycle from "build, push, pull, run" into about a minute.
#
# ODF's entrypoint is `gather`, which takes mode flags, so pass those after
# `--`. gather calls pre-install.sh and sources utils.sh by PATH lookup, so
# the unpack directory is prepended to PATH.
#
#   hack/try-on-cluster.sh --since 30m -- -cl       # ceph logs only
#   hack/try-on-cluster.sh --since 30m -- -o        # odf mode
#   hack/try-on-cluster.sh --dry-run -- -cl
#
# Why base64: oc joins everything after `--` with spaces and drops the result
# into an *unquoted* heredoc (pkg/cli/admin/mustgather/mustgather.go,
# buildPodCommand), so the outer shell would expand $VAR and $(...) in a
# plain inline script. base64's alphabet gives it nothing to act on.

set -eu -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r PROJECT_ROOT
declare -r POD_DIR="/tmp/better-gather-odf"

usage() {
	sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

dry_run=false
script=""
declare -a oc_args=()
declare -a script_args=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage 0 ;;
	--dry-run)
		dry_run=true
		shift
		;;
	--)
		shift
		script_args=("$@")
		break
		;;
	--since | --since-time | --dest-dir | --timeout | --node-name | --run-namespace | --image)
		oc_args+=("$1=$2")
		shift 2
		;;
	--*) # any other oc flag, passed through as given
		oc_args+=("$1")
		shift
		;;
	*)
		if [[ -z "$script" ]]; then
			script="$1"
		else
			script_args+=("$1")
		fi
		shift
		;;
	esac
done

# ODF always runs through its own entrypoint.
script="${script:-gather}"

if [[ ! -f "$PROJECT_ROOT/collection-scripts/$script" ]]; then
	echo "ERROR: collection-scripts/$script does not exist" >&2
	exit 1
fi

payload="$(tar czf - -C "$PROJECT_ROOT" collection-scripts | base64 -w0)"

# The launcher goes into the pod base64-encoded as well, not inlined into the
# command. oc drops the command into an *unquoted* heredoc, so a bare $PATH
# would be expanded on this machine and the pod would be handed the laptop's
# PATH. Anything containing a shell metacharacter -- the PATH export, and any
# argument the caller passed -- has to travel inside the encoding.
launcher="#!/bin/bash
set -eu
export PATH=${POD_DIR}:\$PATH
echo 'INFO: running ${script} from the working tree'
exec ${POD_DIR}/${script}"
for arg in ${script_args+"${script_args[@]}"}; do
	launcher+=" $(printf '%q' "$arg")"
done
launcher+="
"
launcher_b64="$(printf '%s' "$launcher" | base64 -w0)"

for blob in "$payload" "$launcher_b64"; do
	if ! [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]]; then
		echo "ERROR: payload is not pure base64; oc's heredoc would mangle it" >&2
		exit 1
	fi
done

# Single argv element, so oc's strings.Join leaves it intact. Everything the
# shell could act on is inside the two base64 blobs.
remote_cmd="echo '${payload}' | base64 -d >/tmp/bg.tgz"
remote_cmd+=" && mkdir -p ${POD_DIR}"
remote_cmd+=" && tar xzf /tmp/bg.tgz -C ${POD_DIR} --strip-components=1"
remote_cmd+=" && chmod +x ${POD_DIR}/*"
remote_cmd+=" && echo '${launcher_b64}' | base64 -d >/tmp/bg-run.sh"
remote_cmd+=" && bash /tmp/bg-run.sh"

if [[ "$dry_run" == true ]]; then
	echo "oc adm must-gather ${oc_args[*]-} -- <${#payload} char payload>"
	echo
	echo "--- in-pod command (payload elided) ---"
	local_view="${remote_cmd/${payload}/<base64 of collection-scripts/>}"
	echo "${local_view/${launcher_b64}/<base64 of launcher>}"
	echo
	echo "--- launcher (decoded) ---"
	printf '%s\n' "$launcher"
	exit 0
fi

echo "INFO: carrying $(tar tzf <(base64 -d <<<"$payload") | grep -c . ) files into the pod"
exec oc adm must-gather ${oc_args+"${oc_args[@]}"} -- "$remote_cmd"
