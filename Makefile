.PHONY: build ci release setup assets-build format-check native-build native-test native-quality quality credo-check security-check audit-check package-version-check install-docs-check dialyzer-check browser-e2e-setup browser-e2e test spec-lint dev-bundle dist proof-dist-install proof proof-live proof-mcp proof-mcp-live verify-plugin-package dogfood clean-release

RELEASE_NAME ?= agent_loops
RELEASE_CTL = _build/prod/rel/$(RELEASE_NAME)/bin/$(RELEASE_NAME)
APP_BUILD_DIR = _build/prod/lib/codex_loops
DEV_BUNDLE_DIR ?= _build/dev-bundle
DIST_DIR ?= _build/dist
CARGO ?= cargo
NATIVE_MANIFEST = native/codex-loops/Cargo.toml
NATIVE_BIN = native/codex-loops/target/release/codex-loops

setup:
	mix local.hex --if-missing --force
	mix local.rebar --if-missing --force
	mix deps.get

# Public developer gate: compile the project from a clean checkout.
build: setup package-version-check native-build assets-build
	mix compile --warnings-as-errors

assets-build:
	mix tailwind codex_loops

# Public CI gate: every deterministic, credential-free check and end-to-end proof.
ci: setup quality dialyzer-check browser-e2e verify-plugin-package proof-dist-install proof proof-mcp

format-check:
	mix format --check-formatted
	$(CARGO) fmt --manifest-path $(NATIVE_MANIFEST) -- --check

native-build:
	$(CARGO) build --locked --release --manifest-path $(NATIVE_MANIFEST)

native-test:
	$(CARGO) test --locked --manifest-path $(NATIVE_MANIFEST)

native-quality:
	$(CARGO) fmt --manifest-path $(NATIVE_MANIFEST) -- --check
	$(CARGO) clippy --locked --all-targets --all-features --manifest-path $(NATIVE_MANIFEST) -- -D warnings
	$(CARGO) test --locked --manifest-path $(NATIVE_MANIFEST)
	@find native/codex-loops/src -name '*.rs' \
		-exec sh -c 'for file do bash .agents/skills/rust-implement/scripts/lint.sh "$$file" || exit 1; done' sh {} +

quality: setup format-check install-docs-check audit-check build native-quality credo-check security-check test

credo-check:
	mix credo

security-check:
	mix sobelow --router lib/workflow/web/router.ex --private --compact --threshold medium --exit medium --skip --ignore Config.HTTPS,Config.CSP

audit-check:
	mix deps.audit
	mix hex.audit

package-version-check:
	mix run --no-start scripts/sync-package-version.exs --check
	mix run --no-start scripts/check-package-version.exs --check

install-docs-check:
	scripts/check-install-docs.sh

dialyzer-check:
	mix dialyzer

browser-e2e-setup:
	npm --prefix assets install
	npx --prefix assets playwright install chromium

browser-e2e: browser-e2e-setup
	CODEX_LOOPS_BROWSER_E2E=1 mix test --only browser_e2e

test: spec-lint
	mix test

spec-lint:
	scripts/check-spec.sh SPEC.md

release: setup package-version-check assets-build
	MIX_ENV=prod mix deps.get --only prod
	rm -rf "_build/prod/rel/$(RELEASE_NAME)" "$(APP_BUILD_DIR)"
	MIX_ENV=prod mix release $(RELEASE_NAME) --overwrite
	test -x "$(RELEASE_CTL)"

# Compatibility target: MCP is a mode of the native control-plane binary.
dev-bundle: release native-build
	rm -rf "$(DEV_BUNDLE_DIR)"
	mkdir -p "$(DEV_BUNDLE_DIR)/bin" "$(DEV_BUNDLE_DIR)/libexec/scheduler" "$(DEV_BUNDLE_DIR)/share/skills"
	cp "$(NATIVE_BIN)" "$(DEV_BUNDLE_DIR)/bin/codex-loops"
	cp -R "_build/prod/rel/$(RELEASE_NAME)/." "$(DEV_BUNDLE_DIR)/libexec/scheduler/"
	cp -R plugins/codex-loops/skills/codex-loops "$(DEV_BUNDLE_DIR)/share/skills/codex-loops"
	scripts/write-runtime-manifest.sh "$(DEV_BUNDLE_DIR)/share/codex-loops/runtime.json" "$$(tr -d '[:space:]' < VERSION)" "$$(rustc -vV | sed -n 's/^host: //p')"
	test -x "$(DEV_BUNDLE_DIR)/bin/codex-loops"
	test -x "$(DEV_BUNDLE_DIR)/libexec/scheduler/bin/agent_loops"
	test -f "$(DEV_BUNDLE_DIR)/share/skills/codex-loops/SKILL.md"
	test -f "$(DEV_BUNDLE_DIR)/share/codex-loops/runtime.json"

dist: dev-bundle
	scripts/package-dist.sh "$(abspath $(DEV_BUNDLE_DIR))" "$(abspath $(DIST_DIR))" "$$(tr -d '[:space:]' < VERSION)"

proof-dist-install: dev-bundle
	scripts/proof-dist-install.sh "$(abspath $(DEV_BUNDLE_DIR))"

proof: dev-bundle
	scripts/proof-release.sh

proof-live: proof-mcp-live

proof-mcp: dev-bundle
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-validate.exs

proof-mcp-live: dev-bundle
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-live.exs

verify-plugin-package:
	scripts/verify-plugin-package.sh

dogfood:
	scripts/dogfood-plugin.sh

clean-release:
	rm -rf _build/prod/rel/$(RELEASE_NAME)
	rm -rf "$(DEV_BUNDLE_DIR)" "$(DIST_DIR)"
