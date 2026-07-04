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
