.PHONY: build app run test test-live screenshots icon dist clean

build:            ## Debug build
	swift build

app:              ## Release .app bundle in build/
	scripts/build-app.sh

run: app          ## Build and launch
	open build/Letterbox.app

test:             ## Offline unit tests
	swift test

test-live:        ## Also probe real mail servers and the Claude CLI (no logins)
	LETTERBOX_LIVE=1 LETTERBOX_LIVE_AI=1 swift test

screenshots: app  ## Regenerate docs/screenshots from built-in demo data
	rm -rf build/shots
	build/Letterbox.app/Contents/MacOS/Letterbox --snapshot "$(CURDIR)/build/shots"
	mkdir -p docs/screenshots
	for f in build/shots/*.png; do sips -Z 2200 "$$f" --out docs/screenshots/ >/dev/null; done

icon:             ## Regenerate the app icon
	rm -rf build/AppIcon.iconset build/AppIcon.icns
	swift scripts/make-icon.swift build/AppIcon.iconset docs/icon.png

dist:             ## Universal, zipped release build
	UNIVERSAL=1 scripts/build-app.sh
	cd build && ditto -c -k --keepParent Letterbox.app Letterbox.zip
	@echo "build/Letterbox.zip"

clean:
	rm -rf .build build
