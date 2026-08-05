# Portfolio — web-only Flutter site.
#
# RELEASE targets compile to WebAssembly (--wasm). Flutter still emits the
# JavaScript build alongside it as an automatic fallback for browsers without
# WasmGC — notably every browser on iOS — so there is no reason to ship a
# release without this flag.
#
# DEV is different: debug builds compile through DDC, not wasm, so `--wasm`
# does not belong on the development loop.

.PHONY: dev dev-dtd build serve check test analyze fmt clean size

# ─────────────────────────────────────────────────────────────────────────────
# dev-dtd — THE development loop. Use this, not `dev`.
#
# Verified on Flutter 3.44.7 stable. Every line exists because the obvious
# alternative was tried and failed.
#
# WHY `-d web-server` AND NOT `-d chrome`:
#   `flutter run -d chrome` spawns NO Dart Tooling Daemon (DTD) from the CLI —
#   confirmed by counting DTD instances before and after launch: unchanged.
#   Without DTD there is no widget tree, no runtime errors, and no agent-driven
#   hot reload. Native targets spawn a `dart development-service` that provides
#   this; the web target does not. `-d chrome` also launches an isolated Chrome
#   that external browser automation cannot reach.
#
# ⚠️ MANUAL STEP — this cannot be automated:
#   After this target starts, open http://localhost:8099 in YOUR normal Chrome
#   and click the Dart logo in the toolbar to attach the debugger. Until you do,
#   no VM service exists, so no DTD is published and all live tooling is dead.
#   Requires the Dart Debug Extension:
#     https://chromewebstore.google.com/detail/dart-debug-extension/eljbmlghnomdjgdjmbdekegdkbabckhm
#
# WHAT YOU GET, AND WHAT YOU DON'T:
#   ✅ widget tree, runtime errors, hot reload (state preserved)
#   ❌ flutter_driver screenshots/taps — NOT SUPPORTED ON WEB, at all. Pixels
#      come from the Playwright MCP server instead (see .mcp.json). That is a
#      separate browser running a separate instance of this same app.
# ─────────────────────────────────────────────────────────────────────────────
dev-dtd:
	@echo "→ http://localhost:8099"
	@echo "→ open it in YOUR Chrome, then click the Dart logo to attach DTD"
	flutter run -d web-server --web-port 8099

# Plain Chrome run. Fine for eyeballing; gives NO DTD, so no live tooling.
dev:
	flutter run -d chrome

# Production build.
build:
	flutter build web --wasm --release

# Serve the production build locally, with the same headers Cloudflare sends.
serve: build
	@echo "http://localhost:8000"
	@cd build/web && python3 -m http.server 8000 --bind 127.0.0.1

# Everything that must pass before a commit.
check: analyze test

analyze:
	flutter analyze

# In a browser, not on the Dart VM: anything touching a browser API (here
# `package:web`, via the stats overlay) fails to compile for the VM target, so
# the test file never loads.
test:
	flutter test --platform chrome

fmt:
	dart format lib test

# Report what a visitor actually downloads, gzipped — the number that matters
# for first paint, not the on-disk build size. This is a site whose job is to
# impress someone who may leave during a slow load, so watch it.
size: build
	@echo "gzipped payload:"
	@for f in build/web/main.dart.wasm build/web/main.dart.js \
	          build/web/canvaskit/skwasm.wasm; do \
		[ -f "$$f" ] && printf "  %6.2f MB  %s\n" \
			$$(gzip -c "$$f" | wc -c | awk '{print $$1/1048576}') "$$f"; \
	done; true

clean:
	flutter clean
