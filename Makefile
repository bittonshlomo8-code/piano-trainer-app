.PHONY: setup icon xcode build dmg release open test clean help

VERSION ?= $(shell defaults read "$(PWD)/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Install all prerequisites (Homebrew, create-dmg, xcodegen, icon)
	@bash scripts/setup.sh

icon: ## Regenerate app icon from scripts/make-icon.swift
	@swift scripts/make-icon.swift

xcode: ## (Re)generate PianoTrainer.xcodeproj via xcodegen
	@xcodegen generate --spec project.yml --project .

open: xcode ## Generate Xcode project and open it
	@open PianoTrainer.xcodeproj

build: ## Build release .app bundle → dist/Piano Trainer.app
	@bash scripts/build-app.sh

dmg: build ## Build and package as DMG → dist/PianoTrainer-$(VERSION).dmg
	@bash scripts/make-dmg.sh

test: ## Run unit tests
	@swift test --parallel

clean: ## Remove build artifacts
	@rm -rf dist
	@echo "Cleaned dist/"

release: ## Tag vVERSION and push — triggers the GitHub Actions release workflow
	@test -n "$(VERSION)" || (echo "Set VERSION=x.y.z"; exit 1)
	@git diff --quiet HEAD || (echo "Commit or stash uncommitted changes first"; exit 1)
	@echo "Tagging v$(VERSION)…"
	@git tag "v$(VERSION)" -m "Release v$(VERSION)"
	@git push origin "v$(VERSION)"
	@echo "✓ Pushed tag v$(VERSION) — GitHub Actions will build and release."
