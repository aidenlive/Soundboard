# Soundboard · make targets. `make help` lists them.
# Linux runs the engine, tokens, site and repository checks; macOS adds the Swift build and tests.

SHELL      := /bin/bash
UNAME      := $(shell uname -s)
BUILD      ?= engine/build
SITE_PORT  ?= 8052
COMPOSE    := docker compose -f deploy/compose.yaml
HAVE_SWIFT := $(shell [ "$(UNAME)" = "Darwin" ] && command -v swift >/dev/null 2>&1 && echo yes)

.PHONY: help setup dev build test validate up down site site-serve dist e2e shots tokens demo figure \
        deps-check tokens-check site-check logins-check typecheck lint release-check

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | column -t -s $$'\t'

setup: ## Check the toolchain; generate the Xcode project if XcodeGen is installed
	@for t in cmake node python3 git; do command -v $$t >/dev/null && echo "ok      $$t" || echo "missing $$t"; done
	@for t in xcodegen swift docker google-chrome; do command -v $$t >/dev/null && echo "ok      $$t" || echo "optional $$t"; done
	@if command -v xcodegen >/dev/null; then (cd platforms/apple && xcodegen); fi

dev: ## macOS: open the Xcode project. Elsewhere: serve the docs site
ifeq ($(UNAME),Darwin)
	@[ -d platforms/apple/Soundboard.xcodeproj ] || (cd platforms/apple && xcodegen)
	open platforms/apple/Soundboard.xcodeproj
else
	@$(MAKE) --no-print-directory site-serve
endif

build: ## Build the engine; on macOS also the Swift package
	cmake -S engine -B $(BUILD) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(BUILD) -j
ifeq ($(HAVE_SWIFT),yes)
	swift build
endif

test: build ## Engine tests; on macOS also swift test
	ctest --test-dir $(BUILD) --output-on-failure
ifeq ($(HAVE_SWIFT),yes)
	swift test
endif

validate: ## Every check, in order, then the tests (what CI runs)
	@echo "== 1/7 lockfile platform check (dependency pins)"; node tools/deps/check.mjs
	@echo "== 2/7 design-token check";  python3 design/tokens/generate.py --check
	@echo "== 3/7 site check";          node tools/site/build.mjs --check
	@echo "== 4/7 dev-logins check";    node tools/logins/check.js
	@echo "== 5/7 typecheck";           $(MAKE) --no-print-directory typecheck
	@echo "== 6/7 lint";                node tools/station/check.mjs
	@echo "== 7/7 tests";               ctest --test-dir engine/build-validate --output-on-failure
ifeq ($(HAVE_SWIFT),yes)
	swift test
endif
	@echo "validate: green"

typecheck: ## Engine with warnings as errors; Swift on macOS; syntax of every tool script
	@cmake -S engine -B engine/build-validate -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-Werror" >/dev/null
	@cmake --build engine/build-validate -j >/dev/null && echo "engine: compiles with -Werror"
ifeq ($(HAVE_SWIFT),yes)
	swift build
endif
	@for f in $$(find tools -name '*.mjs' -o -name '*.js' | sort); do node --check $$f || exit 1; done; echo "tools: node syntax ok"
	@python3 -m py_compile design/tokens/generate.py tools/site/routing_figure.py && echo "tools: python syntax ok"

release-check: ## Lint with the release rules (the git tag must exist)
	node tools/station/check.mjs --release

tokens: ## Regenerate Swift, tokens.css, tokens.json and DESIGN.md from the token JSON
	python3 design/tokens/generate.py

site: tokens ## Regenerate public/ and index.html
	node tools/site/build.mjs

site-serve: ## Serve public/ at localhost:8052
	SITE_PORT=$(SITE_PORT) node tools/site/serve.mjs

e2e: ## Check every site page, link, asset and anchor; render top pages in Chrome
	node tools/site/e2e.mjs

shots: ## Retake docs/screenshot.png and review shots in dist/shots/
	node tools/shots/shots.mjs

demo: build ## Run the routing prototype; WAVs in out/
	mkdir -p out && $(BUILD)/sbe_routing_demo out

figure: demo ## Refresh the landing page's routing figure from the prototype
	python3 tools/site/routing_figure.py out && node tools/site/build.mjs

up: ## Serve the docs site in Docker at localhost:8052
	$(COMPOSE) up -d --build site

down: ## Stop the Docker services
	$(COMPOSE) down

dist: ## dist/soundboard-<version>.zip + .sha256 from tracked files at HEAD
	node tools/dist/dist.mjs
