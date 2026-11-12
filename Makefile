.PHONY: generate build run test clean release dmg screenshots icon

generate:
	@xcodegen generate >/dev/null

# Build and open a development copy. It's signed with the Developer ID (like
# releases), so macOS remembers the folder access you grant it between builds.
run: generate
	@xcodebuild -project RepoRadar.xcodeproj -scheme RepoRadar -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/dd \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
		DEVELOPMENT_TEAM=5HQ5V9NP82 OTHER_CODE_SIGN_FLAGS="--timestamp=none" -quiet build
	@pkill -x RepoRadar || true
	@sleep 1
	@open build/dd/Build/Products/Debug/RepoRadar.app

build: generate
	@xcodebuild -project RepoRadar.xcodeproj -scheme RepoRadar -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -quiet build

# Run the unit tests. The git tests make throwaway repos in a temporary folder.
test: generate
	@xcodebuild test -project RepoRadar.xcodeproj -scheme RepoRadar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -quiet

clean:
	rm -rf build RepoRadar.xcodeproj

# Ship a release: bump version, commit, tag, push -> CI builds/notarizes/publishes.
#   make release VERSION=1.2.3
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	@scripts/cut-release.sh $(VERSION)

# Build a local notarized test DMG (does not publish).
dmg:
	@scripts/release.sh

# Renders the panel and its popovers with demo repos into build/screenshots,
# for the README and website and for checking the design.
screenshots: generate
	@SCREENSHOTS="$(CURDIR)/build/screenshots" TEST_RUNNER_SCREENSHOTS="$(CURDIR)/build/screenshots" \
		xcodebuild test -project RepoRadar.xcodeproj -scheme RepoRadar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:RepoRadarTests/ScreenshotTests -quiet
	@echo "Screenshots in build/screenshots"

# Redraws the app icon from the mascot into the asset catalog.
icon: generate
	@TEST_RUNNER_ICON_DIR="$(CURDIR)/RepoRadar/Assets.xcassets/AppIcon.appiconset" \
		xcodebuild test -project RepoRadar.xcodeproj -scheme RepoRadar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:RepoRadarTests/ScreenshotTests/testAppIcon -quiet
	@echo "Icon written to RepoRadar/Assets.xcassets/AppIcon.appiconset"
