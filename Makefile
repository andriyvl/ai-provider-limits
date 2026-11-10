.PHONY: all build test preview run install clean project build-macos

all: build

project:
	@xcodegen generate

build:
	@./scripts/build-app.sh

build-macos: project
	@xcodebuild -project ProviderLimits.xcodeproj -scheme "AI Limits" -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO


test:
	@swift test

preview:
	@swift run provider-limits

run: build
	@open "dist/AI Limits.app"

# Copies the app into /Applications so Launchpad and Spotlight list it, then relaunches it from there.
install: build
	@pkill -x "AI Limits" || true
	@rm -rf "/Applications/AI Limits.app"
	@ditto "dist/AI Limits.app" "/Applications/AI Limits.app"
	@open "/Applications/AI Limits.app"
	@echo "Installed: /Applications/AI Limits.app"

clean:
	@rm -rf .build dist ProviderLimits.xcodeproj
