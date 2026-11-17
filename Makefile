SHELL := /bin/sh
SWIFT ?= swift
BUILD_DIR ?= $(CURDIR)/.build
CACHE_DIR := $(BUILD_DIR)/cache
export CLANG_MODULE_CACHE_PATH := $(CACHE_DIR)/clang
export SWIFT_MODULECACHE_PATH := $(CACHE_DIR)/swift
export SWIFTPM_MODULECACHE_OVERRIDE := $(CACHE_DIR)/swiftpm
SWIFT_FLAGS = --scratch-path "$(BUILD_DIR)" --cache-path "$(CACHE_DIR)/packages" --disable-sandbox

.PHONY: lint format test build app check

lint:
	$(SWIFT) format lint --strict --recursive Package.swift Sources Tests

format:
	$(SWIFT) format format --in-place --recursive Package.swift Sources Tests

test:
	$(SWIFT) test $(SWIFT_FLAGS)

build:
	$(SWIFT) build $(SWIFT_FLAGS) --product Sonorus

app: build
	./scripts/bundle-app.sh "$(BUILD_DIR)"

check: lint test build
