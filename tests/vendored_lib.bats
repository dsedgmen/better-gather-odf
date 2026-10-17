#!/usr/bin/env bats
# The vendored since_common.sh must stay identical to the canonical copy in
# dsedgmen/better-gather. Drift should fail the suite rather than rot quietly;
# hack/sync-since-lib.sh in that repo is what updates it.

load test_helper

@test "vendored since_common.sh is present" {
	[ -f "$SCRIPT_DIR/since_common.sh" ]
}

@test "vendored since_common.sh is self-contained" {
	# It must not source common.sh: this repo has utils.sh instead, which is
	# the whole reason the library was made standalone.
	run grep -E '^\s*(source|\.)\s' "$SCRIPT_DIR/since_common.sh"
	refute_output --partial "common.sh"
}

@test "vendored since_common.sh matches the canonical copy if it is checked out" {
	canonical="${PROJECT_ROOT}/../better-gather/collection-scripts/since_common.sh"
	if [ ! -f "$canonical" ]; then
		skip "better-gather is not checked out alongside this repo"
	fi
	run cmp -s "$canonical" "$SCRIPT_DIR/since_common.sh"
	assert_success
}

@test "utils.sh resolves the window for file collection" {
	run grep -c "get_since_cutoff" "$SCRIPT_DIR/utils.sh"
	assert_success
	assert_output "1"
}

@test "gather_ceph_logs no longer rsyncs log directories unbounded" {
	# The journal .gz files and the debugfs copy are deliberate exceptions and
	# are annotated as such; everything else must go through the library.
	# seven call sites, excluding the function definition itself
	run bash -c "grep -c '^ *rsync_node_dir_since ' '$SCRIPT_DIR/gather_ceph_logs'"
	assert_success
	assert_output "7"
}

@test "every script calling the library also sources it" {
	# gather runs each gather_* as a separate script, so functions defined in
	# a parent shell are not inherited. Forgetting the source is silent: the
	# collection runs, logs nothing unusual, and gathers nothing.
	cd "$SCRIPT_DIR"
	local missing=""
	for f in gather_*; do
		if grep -qE '\b(copy_pod_dir_since|pod_tar_dirs_since|filter_names_since|since_find_predicate|trim_jsonl_since|since_report)\b' "$f"; then
			grep -q 'since_common.sh' "$f" || missing="$missing $f"
		fi
	done
	[ -z "$missing" ] || {
		echo "scripts use the library but never source it:$missing" >&2
		false
	}
}
