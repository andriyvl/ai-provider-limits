.PHONY: all build test preview run clean project build-macos

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

clean:
	@rm -rf .build dist ProviderLimits.xcodeproj
