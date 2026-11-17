SHELL := /bin/bash
include config/sources.env
export

PROFILE ?= localnet
COMPOSE := docker compose --env-file config/sources.env
DOCKER_BUILD := DOCKER_BUILDKIT=1 docker build
HASH := \#
# A source's build context: the local checkout in <X>_SRC when set, else the
# git repository at the pinned commit. The Dockerfiles stay in images/ and go
# in on stdin, so they work with either context.
src_context = $(if $($(1)_SRC),$($(1)_SRC),$($(1)_REPO)$(HASH)$($(1)_REF))
src_commit = $(if $($(1)_SRC),$(shell git -C $($(1)_SRC) rev-parse --short=8 HEAD 2>/dev/null || echo unknown),$(shell printf %.8s $($(1)_REF)))

.PHONY: images image-atomone image-consumer image-gnoshard image-relayer sources-bump

images: image-atomone image-consumer image-gnoshard image-relayer

image-atomone:
	$(DOCKER_BUILD) -f - -t $(ATOMONE_IMAGE) \
		--build-arg MIN_VOTING_PERIOD=$(MIN_VOTING_PERIOD) \
		--build-arg COMMIT=$(call src_commit,ATOMONE) '$(call src_context,ATOMONE)' < images/atomone.Dockerfile

image-consumer:
	$(DOCKER_BUILD) -f - -t $(CONSUMER_IMAGE) \
		--build-arg COMMIT=$(call src_commit,VAAS) '$(call src_context,VAAS)' < images/vaas-consumer.Dockerfile

image-gnoshard:
	$(DOCKER_BUILD) -f - -t $(GNOSHARD_IMAGE) \
		--build-arg COMMIT=$(call src_commit,GNOSHARD) '$(call src_context,GNOSHARD)' < images/gnoshard.Dockerfile

# The relayer builds with its own Dockerfile.
image-relayer:
	$(DOCKER_BUILD) -t $(RELAYER_IMAGE) '$(call src_context,RELAYER)'

# Pin every remote source to the current head of its branch.
sources-bump:
	scripts/sources-bump.sh config/sources.env

# --- the localnet (PROFILE=localnet|devnet selects config/$(PROFILE).env) ---
.PHONY: up provider consumer smoke delegate relayer-restart propose owner-exec check-proposals status stop start clean logs

up:
	PROFILE=$(PROFILE) scripts/testnet.sh up

provider:
	PROFILE=$(PROFILE) scripts/testnet.sh provider

# make consumer C=ref|gno|photon
consumer:
	PROFILE=$(PROFILE) scripts/testnet.sh consumer $(C)

smoke:
	PROFILE=$(PROFILE) scripts/testnet.sh smoke

# A delegation reaches every consumer (repeatable, unlike smoke).
delegate:
	PROFILE=$(PROFILE) scripts/testnet.sh delegate

# Restart every relayer, then a delegation must still reach every consumer.
relayer-restart:
	PROFILE=$(PROFILE) scripts/testnet.sh relayer-restart

# make propose F=proposals/resume.json ARGS="consumer-id=1"
propose:
	PROFILE=$(PROFILE) scripts/testnet.sh propose $(F) $(ARGS)

# make owner-exec C=ref F=proposals/owner-exec-update-params.json
owner-exec:
	PROFILE=$(PROFILE) scripts/testnet.sh owner-exec $(C) $(F) $(ARGS)

# Every proposals/ template decodes against the running binaries.
check-proposals:
	PROFILE=$(PROFILE) scripts/testnet.sh check-proposals

status:
	PROFILE=$(PROFILE) scripts/testnet.sh status

stop:
	scripts/testnet.sh stop

start:
	PROFILE=$(PROFILE) scripts/testnet.sh start

clean:
	scripts/testnet.sh clean

# make logs S=atomone-0
logs:
	$(COMPOSE) --profile '*' logs -f --tail 100 $(S)
