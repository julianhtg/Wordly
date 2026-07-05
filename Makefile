WHISPER_VERSION := v1.9.1
XCF_URL := https://github.com/ggml-org/whisper.cpp/releases/download/$(WHISPER_VERSION)/whisper-$(WHISPER_VERSION)-xcframework.zip

.PHONY: vendor build test clean

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

build: vendor/whisper.xcframework
	swift build

test: vendor/whisper.xcframework
	swift test

clean:
	rm -rf .build build

FRAMEWORK_SLICE := vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework

.PHONY: release app run icon sign-setup

release: vendor/whisper.xcframework
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
	xattr -cr build/Wordly.app 2>/dev/null || true
	install_name_tool -add_rpath @executable_path/../Frameworks \
		build/Wordly.app/Contents/MacOS/Wordly 2>/dev/null || true
	@ID="$$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application[^"]*|Apple Development[^"]*|Wordly Local Signing)".*/\1/p' | head -1)"; \
	if [ -n "$$ID" ]; then \
		echo "Signing with stable identity: $$ID"; \
		codesign --force --deep --sign "$$ID" build/Wordly.app; \
	else \
		echo "No stable identity — ad-hoc signing. Permission grants will NOT"; \
		echo "survive rebuilds; run 'make sign-setup' once to fix that."; \
		codesign --force --deep --sign - build/Wordly.app; \
	fi

sign-setup:
	bash scripts/setup-signing.sh

run: app
	open build/Wordly.app
