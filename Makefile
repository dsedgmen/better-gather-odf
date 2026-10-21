all: images
.PHONY: all local docker-rancher-build docker-engine-build

# Include the library makefile
include $(addprefix ./vendor/github.com/openshift/build-machinery-go/make/, \
	golang.mk \
	targets/openshift/images.mk \
)

IMAGE_REGISTRY :=registry.svc.ci.openshift.org
IMG_TAG ?= odf-mg

# This will call a macro called "build-image" which will generate image specific targets based on the parameters:
# $0 - macro name
# $1 - target name
# $2 - image ref
# $3 - Dockerfile path
# $4 - context directory for image build
$(call build-image,odf-must-gather,$(IMAGE_REGISTRY)/ocp/4.14:odf-must-gather, ./Dockerfile,.)

$(call verify-golang-versions,Dockerfile)

docker-rancher-build:
	docker context use rancher-desktop
	docker build . -t $(IMG_TAG) --platform=linux/amd64

docker-engine-build:
	docker build . -t $(IMG_TAG) --platform=linux/amd64

local:
ifndef ODF_MG_TOKEN
	@echo "ERROR: The ODF_MG_TOKEN environment variable is not set."
	@exit 1
endif

	@echo "Logging in to the cluster with token: $(ODF_MG_TOKEN)"
	@oc login --token=$(ODF_MG_TOKEN) --server=https://api.ci.l2s4.p1.openshiftapps.com:6443 1>/dev/null

	@echo "Logging into the CI image registry..."
	@REGISTRY_AUTH_FILE=~/.docker/config.json oc registry login --registry registry.ci.openshift.org 2>/dev/null

	@echo "Will be using $(IMG_TAG) as the image tag, you can change this using IMG_TAG env var."

	@echo "Building the image..."

ifdef RANCHER
	@make docker-rancher-build
else
	@make docker-engine-build
endif


# ---------------------------------------------------------------------------
# better-gather-odf additions
# ---------------------------------------------------------------------------

LOCALBIN ?= $(shell pwd)/tmp/bin
BATS ?= $(LOCALBIN)/bats
SHELLCHECK ?= $(LOCALBIN)/shellcheck
SHFMT ?= $(LOCALBIN)/shfmt
SCRIPT_DIRS := collection-scripts/ hack/ tests/

# BASE has no default on purpose. This image adds only shell scripts, so all
# of its CVE exposure comes from whatever it is layered on; the supported ODF
# image needs a subscription and the community one was built in July last
# year. Pass the image your cluster advertises, or build a current one with
# image-base.
BASE ?=
OVERLAY_IMAGE ?= better-gather-odf:latest
BASE_IMAGE ?= better-gather-odf-base:latest
MAX_BASE_AGE_DAYS ?= 60

.PHONY: tools-from-packages
tools-from-packages:
	./hack/tools-from-packages.sh

$(LOCALBIN)/%:
	./hack/tools-from-packages.sh $*

.PHONY: bats-test
bats-test: $(BATS)
	$(BATS) tests/*.bats

.PHONY: bats-lint
bats-lint: $(SHELLCHECK)
	find $(SCRIPT_DIRS) -type f -not -path '*/vendor/*' \
		-exec grep -Eq '^#!.*/(env +)?(ba|da|k|z)?sh\b' {} \; -exec $(SHELLCHECK) -x {} +

# Does not collide with upstream's targets or with build-machinery-go's
# `test`, which attaches test-unit and hard-requires a Go toolchain.
.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-base
image-base:
	podman build -t $(BASE_IMAGE) -f Dockerfile.base .

.PHONY: check-base
check-base:
	@test -n "$(BASE)" || { echo "set BASE to the image your cluster advertises, or build one with make image-base"; exit 2; }
	./hack/check-base.sh --max-age $(MAX_BASE_AGE_DAYS) $(BASE)

.PHONY: image-overlay
image-overlay:
	@test -n "$(BASE)" || { echo "set BASE to the image your cluster advertises, or build one with make image-base"; exit 2; }
	podman build --build-arg BASE=$(BASE) \
		--build-arg BASE_BUILT="$$(./hack/check-base.sh --warn-only $(BASE) 2>/dev/null | sed -n 's/^built: \([0-9-]*\).*/\1/p' | grep . || echo unknown)" \
		-t $(OVERLAY_IMAGE) -f Dockerfile.overlay .
