# Load environment variables from .env
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# Project Settings
EXECUTABLE_NAME = AinsMLXServer
BUILD_PATH = .build/release/$(EXECUTABLE_NAME)
SWIFT ?= swift
XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
ifneq (,$(wildcard $(XCODE_DEVELOPER_DIR)))
export DEVELOPER_DIR := $(XCODE_DEVELOPER_DIR)
endif
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/clang-module-cache
SWIFTPM_CACHE_DIR = $(CURDIR)/.build/swiftpm-cache
SWIFTPM_CONFIG_DIR = $(CURDIR)/.build/swiftpm-config
SWIFTPM_SECURITY_DIR = $(CURDIR)/.build/swiftpm-security
SWIFTPM_RESOLVE_STAMP = .build/swiftpm-resolved.hash
MLX_SOURCE_ROOT = .build/checkouts/mlx-swift/Source/Cmlx
RESOURCES_DIR = Resources
MLX_METALLIB_PATH = $(RESOURCES_DIR)/mlx.metallib
METAL_TOOLCHAIN_ID ?= com.apple.dt.toolchain.Metal.32023.883
BUILD_MODE ?= debug
MODE ?=
FRONTEND_HASH_FILE = .build/frontend.hash
SWIFT_HASH_FILE = .build/swift.hash
EFFECTIVE_MODE = $(if $(strip $(MODE)),$(MODE),$(BUILD_MODE))
SWIFTPM_COMMON_FLAGS = --disable-sandbox --cache-path $(SWIFTPM_CACHE_DIR) --config-path $(SWIFTPM_CONFIG_DIR) --security-path $(SWIFTPM_SECURITY_DIR)
SWIFTPM_CHECKOUTS = .build/checkouts/mlx-swift .build/checkouts/vapor .build/checkouts/mlx-swift-lm .build/checkouts/Yams

# Default target (runs when just 'make' is called)
.PHONY: all
all: build-ui embed-assets build

# Build frontend and copy to Public folder
.PHONY: build-ui
build-ui:
	@echo "🎨 Building SvelteKit frontend..."
	@CURRENT_HASH="$$(find frontend \
		-path 'frontend/build' -prune -o \
		-path 'frontend/.svelte-kit' -prune -o \
		-path 'frontend/node_modules' -prune -o \
		-type f -print | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $$1}')"; \
	OLD_HASH="$$(cat $(FRONTEND_HASH_FILE) 2>/dev/null || true)"; \
	if [ "$$CURRENT_HASH" = "$$OLD_HASH" ] && [ -d Public ] && [ -n "$$(ls -A Public 2>/dev/null)" ]; then \
		echo "✅ Frontend build unchanged; skipping"; \
	else \
		(cd frontend && npm run build); \
		echo "📂 Copying built files to Public folder..."; \
		mkdir -p Public; \
		rm -rf Public/*; \
		cp -r frontend/build/* Public/; \
		if [ ! -f Public/index.html ]; then \
			echo "❌ Frontend build did not produce Public/index.html"; \
			exit 1; \
		fi; \
		mkdir -p .build; \
		printf '%s\n' "$$CURRENT_HASH" > $(FRONTEND_HASH_FILE); \
		echo "✅ Frontend build and deployment complete"; \
	fi

.PHONY: build-swift-if-needed
build-swift-if-needed:
	@$(MAKE) --no-print-directory ensure-swift-deps
	@CURRENT_HASH="$$(find Package.swift Package.resolved Sources \
		-path '.build' -prune -o \
		-type f -print | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $$1}')"; \
	OLD_HASH="$$(cat $(SWIFT_HASH_FILE) 2>/dev/null || true)"; \
	BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) --show-bin-path )"; \
	if [ "$$CURRENT_HASH" = "$$OLD_HASH" ] && [ -x "$$BIN_PATH/$(EXECUTABLE_NAME)" ]; then \
		echo "✅ Swift sources unchanged; skipping swift build"; \
	else \
		echo "🧱 Building Swift executable..."; \
		mkdir -p $(SWIFTPM_CACHE_DIR) $(SWIFTPM_CONFIG_DIR) $(SWIFTPM_SECURITY_DIR); \
		$(SWIFT) build $(SWIFTPM_COMMON_FLAGS); \
		mkdir -p .build; \
		printf '%s\n' "$$CURRENT_HASH" > $(SWIFT_HASH_FILE); \
	fi

.PHONY: ensure-swift-deps
ensure-swift-deps:
	@DEPS_READY=1; \
	MISSING_DEPS=""; \
	for dep in $(SWIFTPM_CHECKOUTS); do \
		if [ ! -d "$$dep" ]; then \
			DEPS_READY=0; \
			MISSING_DEPS="$$MISSING_DEPS $$dep"; \
			break; \
		fi; \
	done; \
	RESOLVE_HASH="$$(shasum -a 256 Package.swift Package.resolved 2>/dev/null | shasum -a 256 | awk '{print $$1}')" ; \
	OLD_RESOLVE_HASH="$$(cat $(SWIFTPM_RESOLVE_STAMP) 2>/dev/null || true)"; \
	if [ "$$DEPS_READY" = "1" ] && [ "$$RESOLVE_HASH" = "$$OLD_RESOLVE_HASH" ]; then \
		echo "✅ Swift package dependencies unchanged; skipping resolve"; \
	else \
		if [ "$$DEPS_READY" != "1" ]; then \
			echo "ℹ️ Missing Swift package checkouts:$${MISSING_DEPS}"; \
		fi; \
		if [ "$$RESOLVE_HASH" != "$$OLD_RESOLVE_HASH" ]; then \
			echo "ℹ️ Package manifest/resolution changed; will resolve again"; \
		fi; \
		echo "📦 Resolving Swift package dependencies..."; \
		mkdir -p $(SWIFTPM_CACHE_DIR) $(SWIFTPM_CONFIG_DIR) $(SWIFTPM_SECURITY_DIR); \
		$(SWIFT) package $(SWIFTPM_COMMON_FLAGS) resolve; \
		mkdir -p .build; \
		printf '%s\n' "$$RESOLVE_HASH" > $(SWIFTPM_RESOLVE_STAMP); \
	fi

# Convert assets to Swift code for embedding
.PHONY: embed-assets
embed-assets:
	@echo "📦 Embedding static assets into Swift code..."
	python3 scripts/embed_assets.py

# Build in release mode
.PHONY: build
build:
	@$(MAKE) --no-print-directory ensure-swift-deps
	@$(MAKE) --no-print-directory build-metallib MODE=release
	@echo "🚀 Building $(EXECUTABLE_NAME) in release mode..."
	$(SWIFT) build --disable-sandbox -c release
	@echo "✅ Build complete: $(BUILD_PATH)"

.PHONY: build-metallib
build-metallib:
	@case "$(EFFECTIVE_MODE)" in \
		debug|release) echo "🔧 Building mlx.metallib for $(EFFECTIVE_MODE)...";; \
		*) echo "❌ Unsupported build mode: $(EFFECTIVE_MODE)"; exit 1;; \
	esac; \
	$(MAKE) --no-print-directory ensure-swift-deps; \
	mkdir -p "$(RESOURCES_DIR)"; \
	METAL_TOOLCHAIN_ID="$(METAL_TOOLCHAIN_ID)" scripts/build_mlx_metallib.sh "$(MLX_SOURCE_ROOT)" "$(MLX_METALLIB_PATH)"

.PHONY: link-metallib
link-metallib:
	@case "$(EFFECTIVE_MODE)" in \
		debug) BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) --show-bin-path )";; \
		release) BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) -c release --show-bin-path )";; \
		*) echo "❌ Unsupported build mode: $(EFFECTIVE_MODE)"; exit 1;; \
	esac; \
	if [ ! -f "$(MLX_METALLIB_PATH)" ]; then \
		echo "❌ Missing $(MLX_METALLIB_PATH)"; \
		echo "💡 Run 'make build-metallib MODE=$(EFFECTIVE_MODE)' once to generate it."; \
		exit 1; \
	fi; \
	ln -sf "$(CURDIR)/$(MLX_METALLIB_PATH)" "$$BIN_PATH/mlx.metallib"

# Run server (using default config.yaml)
.PHONY: run
run: build-ui embed-assets build-swift-if-needed
	@echo "🌐 Starting server..."
	@if [ ! -f Public/index.html ]; then \
		echo "⚠️ Public/index.html is missing; embedded UI will fall back to the 404 page."; \
	fi
	@$(MAKE) --no-print-directory ensure-swift-deps
	@$(MAKE) --no-print-directory link-metallib BUILD_MODE=debug
	@BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) --show-bin-path )"; \
	"$$BIN_PATH/$(EXECUTABLE_NAME)"

# Run server with a custom configuration file (e.g., make run-config c=custom_config.yaml)
.PHONY: run-config
run-config:
	@if [ -z "$(c)" ]; then \
		echo "❌ Error: Please provide a configuration file path. (Usage: make run-config c=config_path.yaml)"; \
		exit 1; \
	fi
	@echo "🌐 Starting server... (Config: $(c))"
	@$(MAKE) --no-print-directory ensure-swift-deps
	@CURRENT_HASH="$$(find Package.swift Package.resolved Sources \
		-path '.build' -prune -o \
		-type f -print | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $$1}')"; \
	OLD_HASH="$$(cat $(SWIFT_HASH_FILE).release 2>/dev/null || true)"; \
	BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) -c release --show-bin-path )"; \
	if [ "$$CURRENT_HASH" = "$$OLD_HASH" ] && [ -x "$$BIN_PATH/$(EXECUTABLE_NAME)" ]; then \
		echo "✅ Swift sources unchanged; skipping swift build"; \
	else \
		echo "🧱 Building Swift executable..."; \
		mkdir -p $(SWIFTPM_CACHE_DIR) $(SWIFTPM_CONFIG_DIR) $(SWIFTPM_SECURITY_DIR); \
		$(MAKE) --no-print-directory ensure-swift-deps; \
		$(SWIFT) build $(SWIFTPM_COMMON_FLAGS) -c release; \
		mkdir -p .build; \
		printf '%s\n' "$$CURRENT_HASH" > $(SWIFT_HASH_FILE).release; \
	fi
	@$(MAKE) --no-print-directory link-metallib BUILD_MODE=release
	@BIN_PATH="$$( $(SWIFT) build $(SWIFTPM_COMMON_FLAGS) -c release --show-bin-path )"; \
	"$$BIN_PATH/$(EXECUTABLE_NAME)" -c $(c)

# Test OpenAI API endpoint (run in a separate terminal while server is running)
.PHONY: test-chat
test-chat:
	@echo "🧪 Sending test request to OpenAI-compatible API..."
	curl -X POST http://localhost:8382/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model": "codestral", "messages": [{"role": "user", "content": "Fibonacci sequence python code"}], "temperature": 0.2}'
	@echo "\n✅ Request complete"

# Release target (Create a GitHub release locally)
# Usage: make release v=v0.1.0
.PHONY: release
release: all
	@if [ -z "$(v)" ]; then \
		echo "❌ Error: Please provide a version tag. (Usage: make release v=v0.1.0)"; \
		exit 1; \
	fi
	@if [ -z "$(GITHUB_TOKEN)" ]; then \
		echo "❌ Error: GITHUB_TOKEN is not set in .env"; \
		exit 1; \
	fi
	@echo "🏷️ Creating git tag $(v)..."
	git tag $(v)
	git push origin $(v)
	@echo "🚀 Creating GitHub Release $(v)..."
	@BINARY_NAME="AinsMLXServer-$(v)-macos-arm64"; \
	cp $(BUILD_PATH) ./$$BINARY_NAME; \
	GH_TOKEN=$(GITHUB_TOKEN) gh release create $(v) ./$$BINARY_NAME --title "Release $(v)" --notes "Automated release from Makefile"
	@rm -f AinsMLXServer-$(v)-macos-arm64
	@echo "✅ Release $(v) published successfully!"

# Clear build cache
.PHONY: clean
clean:
	@echo "🧹 Cleaning build folders..."
	$(SWIFT) package clean
	rm -rf .build
	rm -rf Public/*
	rm -rf frontend/build
	@echo "✅ Clean complete!"
