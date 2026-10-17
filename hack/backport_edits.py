#!/usr/bin/env python3
"""Re-apply the --since work to an ODF release branch.

Called by hack/backport.sh. Edits upstream's own files, matching the text as
it exists on that branch, and reports whether each edit applied so a branch
where upstream has moved fails loudly rather than silently collecting
everything.
"""

from __future__ import annotations

import pathlib
import re
import sys

results: list[tuple[str, str, bool]] = []


def record(name, status, ok=True):
    results.append((name, status, ok))


CS = "collection-scripts"

# --------------------------------------------------------------------------
# utils.sh: resolve the window to an absolute instant
# --------------------------------------------------------------------------
p = pathlib.Path(f"{CS}/utils.sh")
if not p.exists():
    record("utils.sh", "file absent", False)
else:
    t = p.read_text()
    if "get_since_cutoff" in t:
        record("utils.sh: cutoff", "already applied")
    elif "parse_since_time() {" in t:
        t = t.replace(
            "parse_since_time() {\n    local FILTER_ARGS=\"\"\n",
            "parse_since_time() {\n    local FILTER_ARGS=\"\"\n\n"
            "    # LOG_FILTER_ARGS and JCTL_FILTER_ARGS below cover oc adm inspect\n"
            "    # and journalctl, which is everything oc itself can bound.\n"
            "    # Collection that copies whole directories has to apply the window\n"
            "    # itself, and needs a fixed point to compare mtimes against.\n"
            "    # SC1091 as well as source=: this repo's CI runs shellcheck without\n"
            "    # -x, so it cannot follow the file even when told where it is.\n"
            "    # shellcheck source=collection-scripts/since_common.sh disable=SC1091\n"
            '    source "$(dirname "${BASH_SOURCE[0]}")/since_common.sh"\n'
            "    get_since_cutoff\n"
            "    since_report_header\n", 1)
        p.write_text(t)
        record("utils.sh: cutoff", "applied")
    else:
        record("utils.sh: cutoff", "NO MATCH", False)

# --------------------------------------------------------------------------
# gather_ceph_logs: bound the directory copies
# --------------------------------------------------------------------------
HELPERS = '''
# The debug pods are created by pre-install.sh and live for the whole gather,
# so they can be exec'd into as well as rsync'd from.
debug_pod_for_node() {
    # head -1: a node can have more than one debug pod if an earlier run left
    # one behind, and returning two names turns every subsequent oc call into
    # a confusing failure.
    oc get pods -n "${ns}" --no-headers | grep "${1//./}-debug" | awk '{print $1}' | head -1
}

# Pull a log directory out of a node's debug pod, limited to the --since
# window when one was requested.
#
# These used to be plain "oc rsync", which has no way to express a time
# bound, so every run collected every log the node had ever kept. On a busy
# Ceph cluster /var/log/ceph is the single largest thing this image collects.
# copy_pod_dir_since streams a find|tar instead, so out-of-window files are
# never transferred; with no window it falls back to a plain copy.
rsync_node_dir_since() {
    local node="$1" src="$2" dest="$3" label="$4"
    copy_pod_dir_since "${ns}" "$(debug_pod_for_node "${node}")" "" \\
        "${src}" "${dest}" "ceph_logs/${label}_${node}"
}
'''

RSYNC = re.compile(
    r'^(?P<indent>[ \t]*)oc rsync -n "\$\{ns\}" '
    r'"\$\(oc get pods -n "\$\{ns\}" --no-headers \| grep "\$\{node//\./\}"?-debug"? '
    r"\| awk '\{print \$1\}'\)\":(?P<src>\S+) (?P<dest>\S+)[ \t]*$",
    re.M)

LABELS = {
    "CEPH_DAEMON_LOG_OUTPUT_DIR": "ceph_daemon_log",
    "CSI_LOG_OUTPUT_DIR": "csi_log",
    "CRASH_OUTPUT_DIR": "crash",
}

p = pathlib.Path(f"{CS}/gather_ceph_logs")
if not p.exists():
    record("gather_ceph_logs", "file absent", False)
elif "rsync_node_dir_since" in p.read_text():
    record("gather_ceph_logs", "already applied")
else:
    t = p.read_text()

    # Source the library: gather runs this as a separate script, so functions
    # from the parent shell are not inherited.
    t = t.replace(
        'BASE_COLLECTION_PATH=${BASE_COLLECTION_PATH:-"$(pwd)"}',
        'BASE_COLLECTION_PATH=${BASE_COLLECTION_PATH:-"$(pwd)"}\n\n'
        "# gather runs this as a separate script, so shell functions defined\n"
        "# there are not inherited.\n"
        "# shellcheck source=collection-scripts/since_common.sh disable=SC1091\n"
        'source "$(dirname "$0")/since_common.sh"\n'
        "get_since_cutoff", 1)

    converted = skipped = 0

    def rewrite(m):
        global converted, skipped
        src, dest = m.group("src"), m.group("dest")
        bare = dest.strip('"${}')
        # .gz files were produced moments ago by journalctl --since, and the
        # ceph_kernel_debug copy is a snapshot of /sys/kernel/debug taken
        # seconds before: state, not history. Neither is a log directory.
        if src.endswith(".gz") or "ceph_kernel_debug" in src:
            skipped += 1
            return m.group(0)
        converted += 1
        label = LABELS.get(bare, bare.lower().replace("_output_dir", ""))
        return (f'{m.group("indent")}rsync_node_dir_since "${{node}}" '
                f'{src} {dest} {label}')

    t, n = RSYNC.subn(rewrite, t)
    if converted == 0:
        record("gather_ceph_logs: rsync -> bounded", "NO MATCH", False)
    else:
        p.write_text(t)
        # Insert the helpers just inside the namespace loop, where ${ns} exists.
        t = p.read_text()
        anchor = re.search(r"^for ns in \$namespaces; do\n(.*\n)", t, re.M)
        if anchor:
            t = t[:anchor.end()] + HELPERS + t[anchor.end():]
            p.write_text(t)
            record("gather_ceph_logs: rsync -> bounded",
                   f"applied ({converted} bounded, {skipped} left alone)")
        else:
            record("gather_ceph_logs: helpers", "NO MATCH (no ns loop)", False)

# --------------------------------------------------------------------------
# Makefile
# --------------------------------------------------------------------------
MAKEFILE_BLOCK = """
# --- better-gather-odf: shell lint and tests -------------------------------
# Self-contained and BG_-prefixed so it cannot collide with upstream's
# variables, which differ between release branches.
BG_LOCALBIN ?= $(shell pwd)/tmp/bin
BG_BATS ?= $(BG_LOCALBIN)/bats
BG_SHELLCHECK ?= $(BG_LOCALBIN)/shellcheck
BG_SCRIPT_DIRS := collection-scripts/ hack/ tests/
BG_BASE ?= quay.io/ocs-dev/ocs-must-gather:latest
BG_IMAGE ?= better-gather-odf:latest

$(BG_LOCALBIN)/%:
\t./hack/tools-from-packages.sh $*

.PHONY: bats-lint
bats-lint: $(BG_SHELLCHECK)
\tfind $(BG_SCRIPT_DIRS) -type f -not -path '*/vendor/*' \\
\t\t-exec grep -Eq '^#!.*/(env +)?(ba|da|k|z)?sh\\b' {} \; -exec $(BG_SHELLCHECK) -x {} +

.PHONY: bats-test
bats-test: $(BG_BATS)
\t$(BG_BATS) tests/*.bats

.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-overlay
image-overlay:
\tpodman build --build-arg BASE=$(BG_BASE) -t $(BG_IMAGE) -f Dockerfile.overlay .
"""

mk = pathlib.Path("Makefile")
if not mk.exists():
    record("Makefile", "absent", False)
elif "bats-check" in mk.read_text():
    record("Makefile: bats targets", "already applied")
else:
    mk.write_text(mk.read_text().rstrip("\n") + "\n" + MAKEFILE_BLOCK)
    record("Makefile: bats targets", "applied")

width = max((len(r[0]) for r in results), default=10)
for name, status, ok in results:
    print(f"  [{'ok ' if ok else 'FAIL'}] {name:<{width}}  {status}")

if [r for r in results if not r[2]]:
    print("\nrequired edit(s) did not apply", file=sys.stderr)
    sys.exit(1)
