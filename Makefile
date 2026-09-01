.PHONY: help app macker helper sign run fetch-runtime reset cli dist install bundle pkg check sync-runtime sync-runtime-latest test smoke

# VERSION=1.2.3 make dist
# CERT_NAME='Developer ID Application: …' NOTARIZE=1 VERSION=1.2.3 make dist
# VERSION=1.2.3 make pkg
# make sync-runtime ARGS='containerization 0.42.0'
# make sync-runtime ARGS='kata 3.28.0'
PREFIX ?= /usr/local

help:
	@echo "app                   build and ad-hoc sign the debug daemon"
	@echo "macker                build the CLI and macker-helper"
	@echo "helper                build macker-helper"
	@echo "run                   build, sign, and start the debug daemon"
	@echo "fetch-runtime         download the pinned kernel + vminit into the daemon store"
	@echo "reset                 wipe images/containers/volumes/networks (keeps kernel)"
	@echo "cli                   release CLI prefix in dist/cli"
	@echo "dist                  CLI prefix + tarball + SHA256SUMS"
	@echo "                       CERT_NAME + NOTARIZE=1: Developer ID + notarytool"
	@echo "install               copy dist/cli to PREFIX ($(PREFIX))"
	@echo "bundle                release .app in dist/ (VERSION=... optional)"
	@echo "pkg                   release .app + dist/MackerDaemon.pkg"
	@echo "check                 fail if RuntimePin and the submodule tag differ"
	@echo "sync-runtime          show or apply pins (ARGS='containerization 0.42.0')"
	@echo "sync-runtime-latest   bump pins to GitHub latest stable"
	@echo "test                  run unit tests (no MicroVM)"
	@echo "smoke                 signed daemon + alpine run/exec/-p (SMOKE_SKIP_VM=1 skips VMs)"

app:
	swift build --product mackerd
	./scripts/sign-app.sh

macker: helper
	swift build --product macker

helper:
	swift build --product macker-helper

sign:
	./scripts/sign-app.sh

run: app
	./.build/debug/mackerd

fetch-runtime:
	./scripts/fetch-runtime.sh

reset:
	./scripts/reset-store.sh

cli:
	./scripts/package-cli.sh

dist: cli
	./scripts/package-cli.sh archive

install: cli
	PREFIX="$(PREFIX)" DESTDIR="$(DESTDIR)" ./scripts/package-cli.sh install

bundle:
	./scripts/package.sh

pkg:
	./scripts/package.sh pkg

check:
	./scripts/sync-runtime.sh --check

sync-runtime:
	./scripts/sync-runtime.sh $(ARGS)

sync-runtime-latest:
	./scripts/sync-runtime.sh --latest

test:
	swift test

smoke: app macker
	./scripts/smoke.sh
