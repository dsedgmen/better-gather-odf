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

BASE ?= registry.redhat.io/odf4/odf-must-gather-rhel9:latest
OVERLAY_IMAGE ?= better-gather-odf:latest

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

.PHONY: image-overlay
image-overlay:
	podman build --build-arg BASE=$(BASE) -t $(OVERLAY_IMAGE) -f Dockerfile.overlay .
