# MyBuddy — one entry point for the checks. Runs on a Mac with the Command Line Tools (Swift 6),
# Go, JDK 21 and the Android SDK. Run from the repository root:  make test
SHELL := /bin/bash
JAVA_HOME ?= $(firstword $(wildcard /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home) $(shell /usr/libexec/java_home -v 21 2>/dev/null))
export JAVA_HOME

MAC := apps/macos/MyBuddyMac
ANDROID := apps/android/MyBuddyAndroid
CONNECT := services/connect-api

.PHONY: help test protocol-check test-go test-go-postgres test-mac test-android lint-android \
        build-mac-app build-android interop-host secret-scan

help:
	@echo "make test              protocol + Go + Swift + Android unit tests"
	@echo "make protocol-check    MBH1 vectors regenerate byte-identically; fixtures are current"
	@echo "make test-go           gofmt, go vet, go test -race (connect-api)"
	@echo "make test-go-postgres  Postgres store contract on a throw-away cluster"
	@echo "make test-mac          Swift Testing suites (Keychain tests need an unlocked session)"
	@echo "make test-android      JVM unit tests;  make lint-android  Android lint"
	@echo "make build-mac-app     build/MyBuddy.app (release, ad-hoc signed)"
	@echo "make build-android     debug APK"
	@echo "make interop-host      loopback test host for pairing the Android emulator (10.0.2.2)"
	@echo "make secret-scan       fail on likely credentials in files that would be committed"

test: protocol-check test-go test-mac test-android

protocol-check:
	cd protocol/tools/vectorgen && go run . -check ../../vectors/mbh1-v1.json
	@tmp=$$(mktemp -d) && cp -R protocol/fixtures "$$tmp/before" && python3 -I protocol/tools/make_fixtures.py >/dev/null \
	  && diff -r "$$tmp/before" protocol/fixtures && rm -rf "$$tmp" && echo "fixtures up to date"

test-go:
	cd $(CONNECT) && test -z "$$(gofmt -l .)" && go vet ./... && go test -race ./...

test-go-postgres:
	$(CONNECT)/scripts/pg-test.sh

test-mac:
	$(MAC)/scripts/test.sh

test-android:
	cd $(ANDROID) && ./gradlew testDebugUnitTest

lint-android:
	cd $(ANDROID) && ./gradlew lintDebug

build-mac-app:
	$(MAC)/scripts/build-app.sh

build-android:
	cd $(ANDROID) && ./gradlew assembleDebug

interop-host:
	swift run --package-path $(MAC) MyBuddyInteropHost --advertise 10.0.2.2

secret-scan:
	scripts/secret-scan.sh
