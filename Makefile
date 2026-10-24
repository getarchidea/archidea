# Archidea's commands, the way a package.json's scripts are elsewhere: `make` lists them.
# SwiftPM compiles (Package.swift, incrementally); scripts/bundle.sh packs the result into build/Archidea.app.

SHELL := /bin/bash
.DEFAULT_GOAL := help

APP := build/Archidea.app
# `make dev` runs with a profile of its own, so trying things never touches your own tabs and sign-ins.
DATA ?= $(CURDIR)/build/dev-data
# The toolchain's swift-format (Swift 6), else a separately installed one.
SWIFT_FORMAT := $(shell command -v swift-format >/dev/null 2>&1 && echo swift-format || echo swift format)
FORMATTED := Sources Tests Package.swift
# Always Apple silicon, as the engine is: a shell under Rosetta (CodeQL's tracer runs one) would build for x86_64.
export ARCHIDEA_TRIPLE := arm64-apple-macosx

.PHONY: help setup build release-build bundle dev run watch test lint format package clean release release-minor release-major

help: ## Lists the commands
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

setup: ## Checks the toolchain, fetches the engine and uBlock Origin, installs the dev tools (Brewfile)
	@scripts/setup.sh

build: ## Debug build → build/Archidea.app
	@$(MAKE) --no-print-directory bundle CONFIG=debug

release-build: ## Optimised build → build/Archidea.app
	@$(MAKE) --no-print-directory bundle CONFIG=release

bundle:
	@[ -d "vendor/engine/Chromium Framework.framework" ] || scripts/fetch-engine.sh
	@[ ! -d Sources/Dev ] || echo "note: development hooks now live in Sources/Archidea/Dev; move Sources/Dev there to keep them" >&2
	swift build -c $(CONFIG) --triple $(ARCHIDEA_TRIPLE) --product Archidea
	@scripts/bundle.sh $(CONFIG)

dev: build ## Runs the debug build here in the terminal: its own profile (build/dev-data), the trace on; ⌃C quits
	DRIFT_DATA_DIR="$(DATA)" DRIFT_TRACE=1 $(APP)/Contents/MacOS/Archidea

run: build ## Opens the debug build like any app, with your own profile
	open $(APP)

watch: ## `make dev` that rebuilds and restarts whenever a source, translation or plist changes
	@command -v watchexec >/dev/null || { echo "make watch needs watchexec: make setup (or brew install watchexec)" >&2; exit 1; }
	watchexec --restart --watch Sources --watch Resources --exts swift,strings,plist -- $(MAKE) --no-print-directory dev

test: ## Unit tests (swift test)
	@[ -d "vendor/engine/Chromium Framework.framework" ] || scripts/fetch-engine.sh
	swift test

lint: ## Reports what swift-format would change
	$(SWIFT_FORMAT) lint --recursive --parallel $(FORMATTED)

format: ## Formats the code with swift-format (.swift-format)
	$(SWIFT_FORMAT) format --in-place --recursive --parallel $(FORMATTED)

package: release-build ## Disk image and update zip in build/release, as a release has them
	scripts/package.sh arm64

clean: ## Removes the build output (keeps the downloaded engine and the dev profile)
	rm -rf .build $(APP) build/.engine-stamp build/release

# Tag a release and push it; GitHub builds and publishes it (.github/workflows/release.yml).
#   make release              next patch version
#   make release-minor        next minor version
#   make release v=1.2.3      a given version
release: ## Tags the next patch release (v=x.y.z for a given one) and pushes it
	@scripts/release-tag.sh $(if $(v),$(v),$$(python3 scripts/changelog.py next patch))

release-minor: ## Tags the next minor release and pushes it
	@scripts/release-tag.sh $$(python3 scripts/changelog.py next minor)

release-major: ## Tags the next major release and pushes it
	@scripts/release-tag.sh $$(python3 scripts/changelog.py next major)
