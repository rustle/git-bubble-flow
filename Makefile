# Dev loop for git-bubble-flow.
#
# Everything in the container goes through `compose run --rm dev`, so the host
# only needs Docker. The `macos-*` targets build natively for the same reason a
# Homebrew formula does: that is the artifact macOS users install.

COMPOSE ?= docker compose
PREFIX  ?= /usr/local
SHIMS   := git-verify-bubble git-land-bubble git-rebase-bubble git-bubble-absorb git-stack-bubble bubble-flow-setup
RUN     := $(COMPOSE) run --rm dev
DIST    ?= dist

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: image
image: ## Build the dev/CI image
	$(COMPOSE) build dev

.PHONY: shell
shell: image ## Interactive shell in the dev image
	$(RUN) bash

.PHONY: build
build: image ## Debug build inside the container
	$(RUN) swift build

.PHONY: test
test: image ## Swift unit tests inside the container
	$(RUN) swift test

.PHONY: conformance
conformance: image ## Run the bats conformance suite against the built binary
	$(RUN) ./test/run-tests.sh

.PHONY: check
check: test conformance ## Unit tests + conformance

.PHONY: static
static: ## Fully-static Linux binaries for both arches into $(DIST)/
	docker build -f docker/Dockerfile --target dist --output type=local,dest=$(DIST) .
	@ls -l $(DIST)

.PHONY: macos-build
macos-build: ## Release build on the host (macOS)
	swift build -c release

.PHONY: macos-check
macos-check: ## Unit tests + conformance on the host (macOS)
	swift test
	./test/run-tests.sh

.PHONY: install
install: ## Build a release binary and install it with its symlinks into $(PREFIX)/bin
	swift build -c release --product git-bubble-flow
	install -d "$(PREFIX)/bin"
	install -m 0755 "$$(swift build -c release --show-bin-path)/git-bubble-flow" "$(PREFIX)/bin/git-bubble-flow"
	@for s in $(SHIMS); do ln -sf git-bubble-flow "$(PREFIX)/bin/$$s"; done
	@echo "Installed into $(PREFIX)/bin. Run 'bubble-flow-setup' inside a repository."

.PHONY: uninstall
uninstall: ## Remove an installation from $(PREFIX)/bin
	rm -f "$(PREFIX)/bin/git-bubble-flow"
	@for s in $(SHIMS); do rm -f "$(PREFIX)/bin/$$s"; done

.PHONY: clean
clean: ## Remove build output
	rm -rf .build $(DIST)
	-$(COMPOSE) down -v
