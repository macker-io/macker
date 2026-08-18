.PHONY: help app macker helper sign run fetch-runtime reset bundle pkg check sync-runtime sync-runtime-latest

# VERSION=1.2.3 make -C daemon pkg
# make -C daemon sync-runtime ARGS='containerization 0.42.0'
# make -C daemon sync-runtime ARGS='kata 3.28.0'

help:
	@echo "app                   build and ad-hoc sign the debug daemon"
	@echo "macker                build the CLI and macker-helper"
	@echo "helper                build macker-helper"
	@echo "run                   build, sign, and start the debug daemon"
	@echo "fetch-runtime         download the pinned kernel + vminit into the daemon store"
	@echo "reset                 wipe images/containers/volumes/networks (keeps kernel)"
	@echo "bundle                release .app in dist/ (VERSION=... optional)"
	@echo "pkg                   release .pkg in dist/ (VERSION=... optional)"
	@echo "check                 fail if RuntimePin and the submodule tag differ"
	@echo "sync-runtime          show or apply pins (ARGS='containerization 0.42.0')"
	@echo "sync-runtime-latest   bump pins to GitHub latest stable"

app:
	swift build --product App
	./scripts/sign-app.sh

macker: helper
	swift build --product macker

helper:
	swift build --product macker-helper

sign:
	./scripts/sign-app.sh

run: app
	./.build/debug/App

fetch-runtime:
	./scripts/fetch-runtime.sh

reset:
	./scripts/reset-store.sh

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
