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

# --- better-gather-odf: shell lint and tests -------------------------------
# Self-contained and BG_-prefixed so it cannot collide with upstream's
# variables, which differ between release branches.
BG_LOCALBIN ?= $(shell pwd)/tmp/bin
BG_BATS ?= $(BG_LOCALBIN)/bats
BG_SHELLCHECK ?= $(BG_LOCALBIN)/shellcheck
BG_SCRIPT_DIRS := collection-scripts/ hack/ tests/
# BG_BASE has no default on purpose. This image adds only shell scripts,
# so all of its CVE exposure comes from whatever it is layered on, and the
# public ODF must-gather image has not been rebuilt since July last year.
# Pass the image your cluster advertises, or build one with image-base.
BG_BASE ?=
BG_BASE_IMAGE ?= better-gather-odf-base:4.21
BG_MAX_BASE_AGE_DAYS ?= 60
BG_IMAGE ?= better-gather-odf:latest

$(BG_LOCALBIN)/%:
	./hack/tools-from-packages.sh $*

.PHONY: bats-lint
bats-lint: $(BG_SHELLCHECK)
	find $(BG_SCRIPT_DIRS) -type f -not -path '*/vendor/*' \
		-exec grep -Eq '^#!.*/(env +)?(ba|da|k|z)?sh\b' {} \; -exec $(BG_SHELLCHECK) -x {} +

.PHONY: bats-test
bats-test: $(BG_BATS)
	$(BG_BATS) tests/*.bats

.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-base
image-base:
	podman build -t $(BG_BASE_IMAGE) -f Dockerfile.base .

.PHONY: check-base
check-base:
	@test -n "$(BG_BASE)" || { echo "set BG_BASE to the ODF must-gather image your cluster advertises, or build a 4.21 one with make image-base"; exit 2; }
	./hack/check-base.sh --max-age $(BG_MAX_BASE_AGE_DAYS) $(BG_BASE)

.PHONY: image-overlay
image-overlay:
	@test -n "$(BG_BASE)" || { echo "set BG_BASE to the ODF must-gather image your cluster advertises, or build a 4.21 one with make image-base"; exit 2; }
	podman build --build-arg BASE=$(BG_BASE) \
		--build-arg BASE_BUILT="$$(./hack/check-base.sh --warn-only $(BG_BASE) 2>/dev/null | sed -n 's/^built: \([0-9-]*\).*/\1/p' | grep . || echo unknown)" \
		-t $(BG_IMAGE) -f Dockerfile.overlay .
