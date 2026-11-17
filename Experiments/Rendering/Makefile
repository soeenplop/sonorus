SHELL := /bin/sh
SWIFT ?= swift
BUILD_DIR ?= $(CURDIR)/.build
CACHE_DIR := $(BUILD_DIR)/cache
export CLANG_MODULE_CACHE_PATH := $(CACHE_DIR)/clang
export SWIFT_MODULECACHE_PATH := $(CACHE_DIR)/swift
export SWIFTPM_MODULECACHE_OVERRIDE := $(CACHE_DIR)/swiftpm
SWIFT_FLAGS = --scratch-path "$(BUILD_DIR)" --cache-path "$(CACHE_DIR)/packages" --disable-sandbox

.PHONY: build lint format test run

build:
	$(SWIFT) build $(SWIFT_FLAGS)

lint:
	$(SWIFT) format lint --strict --recursive Package.swift Sources Tests

test:
	$(SWIFT) test $(SWIFT_FLAGS)

format:
	$(SWIFT) format format --in-place --recursive Package.swift Sources Tests

# make run T=VariantA ARGS="--duration 5"
run:
	$(SWIFT) run $(SWIFT_FLAGS) $(T) $(ARGS)

testapp:
	$(SWIFT) build $(SWIFT_FLAGS) -c release --product TestWindows
	./bundle-testwindows.sh release
