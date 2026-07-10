.PHONY: help setup test analyze build build-apk build-ios bundle sim-ios deploy-ios clean
.DEFAULT_GOAL := help

help:             ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

setup:            ## Fetch dependencies
	flutter pub get

test:             ## Run unit tests
	flutter test

analyze:          ## Static analysis
	flutter analyze

build: build-apk  ## Build the release app (alias for build-apk)

build-apk:        ## Release APK (android/app/build outputs)
	flutter build apk --release

build-ios:        ## Release iOS build (no codesign; needs Xcode signing to archive)
	flutter build ios --release --no-codesign

bundle:           ## Release Android App Bundle for Play Store
	flutter build appbundle --release

sim-ios:          ## Boot an iPhone simulator and run the app on it
	@UDID=$$(xcrun simctl list devices available | grep -iE 'iPhone' | grep -oE '[0-9A-F-]{36}' | head -1); \
	if [ -z "$$UDID" ]; then echo "No iPhone simulator found. Create one in Xcode > Settings > Platforms."; exit 1; fi; \
	xcrun simctl boot $$UDID 2>/dev/null || true; \
	open -a Simulator; \
	xcrun simctl bootstatus $$UDID; \
	flutter run -d $$UDID

deploy-ios:       ## Install & run release build on the cabled iPhone (needs Xcode signing)
	@UDID=$$(flutter devices 2>/dev/null | grep ' ios ' | grep -v simulator | head -1 | awk -F'•' '{print $$2}' | xargs); \
	if [ -z "$$UDID" ]; then echo "No physical iPhone found. Plug it in via cable and trust this Mac."; exit 1; fi; \
	echo "Deploying to $$UDID"; \
	flutter run --release -d $$UDID

clean:            ## Remove build artifacts
	flutter clean
