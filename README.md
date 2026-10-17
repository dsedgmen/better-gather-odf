better-gather-odf
=================

A fork of [red-hat-storage/odf-must-gather](https://github.com/red-hat-storage/odf-must-gather)
in which `--since` bounds the Ceph log collection. Sibling of
[better-gather](https://github.com/dsedgmen/better-gather) (OpenShift) and
[better-gather-cnv](https://github.com/dsedgmen/better-gather-cnv).

## What was wrong

ODF was in better shape than the OpenShift image to start with: `utils.sh
parse_since_time()` already feeds `LOG_FILTER_ARGS` to thirteen `oc adm
inspect` calls and `JCTL_FILTER_ARGS` to two `journalctl --since` calls. Both
work.

The gap was `gather_ceph_logs`, which pulled **ten whole host directories**
out of per-node debug pods with `oc rsync` — `/var/log/ceph`,
`/var/lib/rook/<ns>/log`, the three CSI log directories, `/var/lib/cephcsi`,
crash dumps — with no time bound at all. `oc rsync` has no way to express
one. On a busy cluster this is the single largest thing the image collects.

## What changed

Seven of those ten now go through `copy_pod_dir_since` from the vendored
`since_common.sh`, which streams a `find -newermt | tar` out of the debug pod
instead, so out-of-window files are never transferred. With no `--since` it
falls back to a plain copy and behaves exactly as before.

The other three are deliberate and annotated in place:

- the two `journal_<node>.gz` / `kernel_<node>.gz` files are produced moments
  earlier by `journalctl --since "${JCTL_FILTER_ARGS}"`, so they are already
  bounded, and they are single files rather than directories;
- the `ceph_kernel_debug` copy is a snapshot of `/sys/kernel/debug/ceph`
  taken seconds before, so it is point-in-time state, not history.

## Measured on a live cluster

ODF 4.18.29 on OCP 4.18.54, three nodes, `--since 30m`:

```
baseline master-0: 64 files in /var/lib/rook/openshift-storage/log, 8 in window

ceph_logs/ceph_daemon_log_master-0   find-newermt   kept=8   skipped=56
ceph_logs/csi_rbd_master-0           find-newermt   kept=5   skipped=25
ceph_logs/csi_cephfs_master-0        find-newermt   kept=1   skipped=15

files collected older than the cutoff: 0
```

Every run writes `<base>/since-report.txt` accounting for each collection
site, including the ones a window does not apply to, so nothing looks
silently skipped.

## Testing a change

```console
$ hack/try-on-cluster.sh --since 30m -- -cl      # ceph logs, no image build
$ hack/try-on-cluster.sh --dry-run -- -cl
$ make check                                      # shellcheck + bats
$ make image-overlay BASE=<the odf must-gather image your cluster advertises>
```

`make check` bootstraps `bats`, `shellcheck` and `shfmt` from the
distribution via `hack/tools-from-packages.sh`, with no root and no downloads
from GitHub. `bats-support`/`bats-assert` are not packaged anywhere, so
`tests/bats_assert_fallback.bash` supplies the assertions used here.

## The vendored library

`collection-scripts/since_common.sh` is a verbatim copy of the canonical file
in [better-gather](https://github.com/dsedgmen/better-gather); update it with
`hack/sync-since-lib.sh` *in that repo*, not by editing it here.
`tests/vendored_lib.bats` fails if the copy has drifted, if it has grown a
dependency on a `common.sh` this repo does not have, or if a collection
script calls a library function without sourcing the library — that last one
fails silently on a cluster and cost a wasted run before it was caught.

## Images

CI builds the overlay image and pushes it to ghcr.io on `main`, on every
`release-*` branch, and on a `v*` tag. Pull requests build and smoke-test but
publish nothing.

| ref | tags |
| --- | --- |
| `main` | `:latest`, `:main-<sha>` |
| `release-4.18` | `:4.18`, `:release-4.18` |
| `v1.2.3` | `:v1.2.3`, `:latest` |

A release branch deliberately does not move `:latest`, so `--image …:4.18`
keeps getting the 4.18 collection scripts whatever happens on main.

**The packages are private**, inheriting the repository's visibility, so a
cluster needs a pull secret. Create one in the namespace must-gather will run
in, with a PAT that has `read:packages`:

```console
$ oc create namespace must-gather-run
$ oc create secret docker-registry ghcr \
    --docker-server=ghcr.io \
    --docker-username=dsedgmen \
    --docker-password=<PAT with read:packages> \
    -n must-gather-run
$ oc secrets link default ghcr --for=pull -n must-gather-run

$ oc adm must-gather \
    --run-namespace must-gather-run \
    --image=ghcr.io/dsedgmen/better-gather-odf:4.18 \
    --since 30m
```

`--run-namespace` matters: without it the pod runs in a fresh temporary
namespace that has no pull secret.

To avoid the secret entirely, make the package public in the repository's
package settings — note that publishes the collection scripts, since they are
in the image layers.

## Release branches

`release-4.18` through `release-4.22`. Upstream has no `release-4.23` —
it goes straight from 4.22 to 5.0 — so there is nothing to backport onto.

On each branch, 7 of the 9 `oc rsync` calls in `gather_ceph_logs` become
bounded copies; the two that remain are the journal and kernel `.gz` files,
already bounded by `journalctl --since` and single files besides. 40 tests
pass on every branch.

## Staying current with upstream

```console
$ git fetch upstream && git rebase upstream/main
```

---

ODF must-gather
=================

`odf-must-gather` is a tool built on top of [OpenShift must-gather](https://github.com/openshift/must-gather)
that expands its capabilities to gather Openshift Container Storage for information.

### Usage
```sh
oc adm must-gather --image=registry.redhat.io/odf4/odf-must-gather-rhel9:v4.18 -- /usr/bin/gather -arg1 -arg2
```

**Note**: For the time being the image in the above link is not from the latest upstream code and hence does not support args. This message will be updated along with the link when the image is up to date.

List of arguments that can be passed to the odf-must-gather are:
```
-o,  --odf                Collect ODF logs (includes content from arguments -n, -c, -cl, -cs & -ns)
-d,  --dr                 Collect DR logs
-pc, --provider           Collect openshift-storage-client logs from a provider/consumer cluster
-n,  --noobaa             Collect noobaa logs
-c,  --ceph               Collect ceph commands and pod logs
-cl, --ceph-logs          Collect ceph daemon, kernel, journal logs and crash reports
-ns, --namespaced         Collect namespaced resources
-cs, --clusterscoped      Collect clusterscoped resources
-m,  --minimal            Collect storagecluster, cephcluster CRDs and operator CSVs
-h,  --help               Print this help message
```

## Description:

ODF must-gather can run in modular mode and can collect JUST
the resources you require to collect. You can use the args
listed above to achieve that. If no arg is supplied the script
will run in FULL collection mode and will gather all the resources
from your cluster. This might take longer on some environments.

Note: Provide each arg separately and do not chain them like:
```
$ oc adm must-gather --image=<odf-must-gather-image> -- /usr/bin/gather  -dpnc          # Wrong
$ oc adm must-gather --image=<odf-must-gather-image> -- /usr/bin/gather -d -p -n -c     # Correct
```
Examples:
```
$ oc adm must-gather --image=<odf-must-gather-image> -- /usr/bin/gather -d -n --ceph    # Collect DR, noobaa and ceph logs only.
$ oc adm must-gather --image=<odf-must-gather-image> -- /usr/bin/gather -h              # Print help
```

The command above will create a local directory with a dump of the ODF state.

**Note**: This command will only get data related to the ODF part of the OpenShift cluster.

The dump consists of:
- The ODF Operator namespaces (and its children objects)
- All namespaces (and their children objects) that belong to any ODF resources
- All ODF CRD's definitions
- All namespaces that contains ceph and noobaa
- Output of the following ceph commands
    ```
    ceph status
    ceph health detail
    ceph osd tree
    ceph osd stat
    ceph osd dump
    ceph mon stat
    ceph mon dump
    ceph df
    ceph report
    ceph osd df tree
    ceph fs dump
    ceph fs ls
    ceph pg dump
    ceph health detail
    ceph osd crush show-tunables
    ceph osd crush dump
    ceph mgr dump
    ceph mds stat
    ceph versions
    ```

In order to get data about other parts of the cluster (not specific to ODF) you should
run `oc adm must-gather` (without passing a custom image). Run `oc adm must-gather -h` to see more options.

### Building locally for testing
You need to be autheticated against the OpenShift registry CI, registry.ci.openshift.org in order to be able to pull the images in the `Dockerfile`.

Before proceeding make sure you have `oc` (OpenShift cli) installed.

Follow these steps to authenticate:

- Navigate to the OpenShift console for `app.ci` cluster located [here](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/).
- Login using SSO
- Go to your profile name in the top right and select "Copy login command".
- Copy the displayed TOKEN
- Run `ODF_MG_TOKEN=YOUR_TOKEN_HERE make local`. 

See [here](https://github.com/red-hat-storage/odf-must-gather/pull/76) for more options on building locally.

### How to Contribute

- Refer and follow the standards mentioned in [ODF-MUST-GATHER How to Contribute](./CONTRIBUTING.md)
- Tag the Pull Request with `must-gather`
