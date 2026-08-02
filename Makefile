WHISPER_VERSION := v1.9.1
XCF_URL := https://github.com/ggml-org/whisper.cpp/releases/download/$(WHISPER_VERSION)/whisper-$(WHISPER_VERSION)-xcframework.zip

.PHONY: vendor build test clean no-dupes

# iCloud (this repo lives on the synced Desktop) drops "<name> 2.swift" conflict
# copies into Sources/, which fail the build with a cryptic "ambiguous use of
# 'init()'" instead of naming the real problem. Catch it up front.
no-dupes:
	@dupes="$$(find Sources Tests -name '* [0-9].swift' 2>/dev/null)"; \
	if [ -n "$$dupes" ]; then \
		echo "iCloud conflict copies found — delete these, then rebuild:"; \
		echo "$$dupes"; exit 1; \
	fi
	@# Same thing happens to the vendored framework inside .build, where it
	@# produces an even less obvious failure. Those are build artifacts, so
	@# just remove them.
	@find .build -maxdepth 5 -name '* [0-9].framework' -exec rm -rf {} + 2>/dev/null || true

vendor: vendor/whisper.xcframework

vendor/whisper.xcframework:
	mkdir -p vendor
	curl -L -o vendor/xcf.zip $(XCF_URL)
	cd vendor && unzip -q xcf.zip && rm xcf.zip
	@# release zip may nest the framework under build-apple/ — normalize
	@if [ -d vendor/build-apple/whisper.xcframework ]; then \
		mv vendor/build-apple/whisper.xcframework vendor/ && rm -rf vendor/build-apple; \
	fi
	@test -d vendor/whisper.xcframework || { echo "xcframework layout unexpected — inspect vendor/"; exit 1; }

build: no-dupes vendor/whisper.xcframework
	swift build

test: no-dupes vendor/whisper.xcframework
	swift test

clean:
	rm -rf .build build

FRAMEWORK_SLICE := vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework

.PHONY: release app run icon sign-setup

release: no-dupes vendor/whisper.xcframework
	swift build -c release

icon: Resources/AppIcon.icns

Resources/AppIcon.icns:
	swift scripts/make-icon.swift

app: release Resources/AppIcon.icns
	rm -rf build/Wordly.app
	mkdir -p build/Wordly.app/Contents/MacOS build/Wordly.app/Contents/Frameworks build/Wordly.app/Contents/Resources
	cp .build/release/Wordly build/Wordly.app/Contents/MacOS/
	cp Resources/Info.plist build/Wordly.app/Contents/
	cp Resources/AppIcon.icns build/Wordly.app/Contents/Resources/
	cp -R $(FRAMEWORK_SLICE) build/Wordly.app/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks \
		build/Wordly.app/Contents/MacOS/Wordly 2>/dev/null || true
	@ID="$$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application[^"]*|Apple Development[^"]*|Wordly Local Signing)".*/\1/p' | head -1)"; \
	if [ -n "$$ID" ]; then echo "Signing with stable identity: $$ID"; \
	else echo "No stable identity — ad-hoc signing (grants won't survive rebuilds; run 'make sign-setup')"; ID="-"; fi; \
	signed=0; \
	for attempt in 1 2 3; do \
		xattr -cr build/Wordly.app 2>/dev/null || true; \
		if codesign --force --deep --sign "$$ID" build/Wordly.app 2>/dev/null; then signed=1; break; fi; \
		echo "codesign hit an iCloud xattr race; stripping and retrying ($$attempt)…"; \
	done; \
	[ $$signed = 1 ] || { echo "codesign failed after 3 tries"; exit 1; }

sign-setup:
	bash scripts/setup-signing.sh

run: app
	open build/Wordly.app
