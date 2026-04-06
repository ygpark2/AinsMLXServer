# Project Settings
EXECUTABLE_NAME = AinsMLXServer
BUILD_PATH = .build/release/$(EXECUTABLE_NAME)

# Default target (runs when just 'make' is called)
.PHONY: all
all: build-ui embed-assets build

# Build frontend and copy to Public folder
.PHONY: build-ui
build-ui:
	@echo "🎨 Building SvelteKit frontend..."
	cd frontend && npm run build
	@echo "📂 Copying built files to Public folder..."
	mkdir -p Public
	rm -rf Public/*
	cp -r frontend/build/* Public/
	@echo "✅ Frontend build and deployment complete"

# Convert assets to Swift code for embedding
.PHONY: embed-assets
embed-assets:
	@echo "📦 Embedding static assets into Swift code..."
	python3 scripts/embed_assets.py

# Build in release mode
.PHONY: build
build:
	@echo "🚀 Building $(EXECUTABLE_NAME) in release mode..."
	swift build -c release
	@echo "✅ Build complete: $(BUILD_PATH)"

# Run server (using default config.yaml)
.PHONY: run
run: build
	@echo "🌐 Starting server..."
	./$(BUILD_PATH)

# Run server with a custom configuration file (e.g., make run-config c=custom_config.yaml)
.PHONY: run-config
run-config: build
	@if [ -z "$(c)" ]; then \
		echo "❌ Error: Please provide a configuration file path. (Usage: make run-config c=config_path.yaml)"; \
		exit 1; \
	fi
	@echo "🌐 Starting server... (Config: $(c))"
	./$(BUILD_PATH) -c $(c)

# Test OpenAI API endpoint (run in a separate terminal while server is running)
.PHONY: test-chat
test-chat:
	@echo "🧪 Sending test request to OpenAI-compatible API..."
	curl -X POST http://localhost:8080/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model": "codestral", "messages": [{"role": "user", "content": "Fibonacci sequence python code"}], "temperature": 0.2}'
	@echo "\n✅ Request complete"

# Clear build cache
.PHONY: clean
clean:
	@echo "🧹 Cleaning build folders..."
	swift package clean
	rm -rf .build
	rm -rf Public/*
	rm -rf frontend/build
	@echo "✅ Clean complete!"
