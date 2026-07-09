.PHONY: setup format-check quality credo-check security-check audit-check package-version-check dialyzer-check browser-e2e-setup browser-e2e test spec-lint build release release-mcp check-burrito-tools proof proof-live proof-mcp proof-mcp-live verify-plugin-package dogfood clean-release

RELEASE_NAME ?= agent_loops
RELEASE_CTL = _build/prod/rel/$(RELEASE_NAME)/bin/$(RELEASE_NAME)
APP_BUILD_DIR = _build/prod/lib/codex_loops
PLUGIN_SCHEDULER_DIR = plugins/codex-loops/scheduler
PLUGIN_MCP_DIR = plugins/codex-loops/mcp
MCP_RELEASE_NAME = codex_loops_mcp
MCP_BURRITO_TARGET ?= native
MCP_BURRITO_BIN = burrito_out/$(MCP_RELEASE_NAME)_$(MCP_BURRITO_TARGET)
MCP_DIST_DIR = _build/prod/mcp
MCP_DIST_BIN = $(MCP_DIST_DIR)/codex-loops-mcp
MCP_PLUGIN_BIN = $(PLUGIN_MCP_DIR)/codex-loops-mcp
BURRITO_DEP_DIR = deps/burrito
BURRITO_ZIG_ARTIFACTS = $(BURRITO_DEP_DIR)/.zig-cache $(BURRITO_DEP_DIR)/zig-out $(BURRITO_DEP_DIR)/payload.foilz $(BURRITO_DEP_DIR)/src/payload.foilz.xz $(BURRITO_DEP_DIR)/src/_metadata.json
UNAME_S = $(shell uname -s)
HOMEBREW_ZIG_0_15 = /opt/homebrew/opt/zig@0.15/bin/zig

ifeq ($(origin ZIG), undefined)
ifeq ($(UNAME_S),Darwin)
ZIG = $(shell if [ -x "$(HOMEBREW_ZIG_0_15)" ]; then printf '%s' "$(HOMEBREW_ZIG_0_15)"; else command -v zig 2>/dev/null; fi)
else
ZIG = $(shell command -v zig 2>/dev/null)
endif
endif

ZIG_PATH = $(if $(ZIG),$(dir $(ZIG)):$(PATH),$(PATH))

setup:
	mix local.hex --if-missing --force
	mix local.rebar --if-missing --force
	mix deps.get

format-check:
	mix format --check-formatted

quality:
	$(MAKE) format-check
	$(MAKE) audit-check
	$(MAKE) build
	$(MAKE) credo-check
	$(MAKE) security-check
	$(MAKE) test

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

build: package-version-check
	mix compile --warnings-as-errors

release: package-version-check
	MIX_ENV=prod mix deps.get --only prod
	rm -rf "_build/prod/rel/$(RELEASE_NAME)" "$(APP_BUILD_DIR)"
	MIX_ENV=prod mix release $(RELEASE_NAME) --overwrite
	test -x "$(RELEASE_CTL)"
	test -x "_build/prod/rel/$(RELEASE_NAME)/bin/codex-loops"
	mkdir -p "$(PLUGIN_SCHEDULER_DIR)"
	rm -rf "$(PLUGIN_SCHEDULER_DIR)/bin" "$(PLUGIN_SCHEDULER_DIR)"/erts-* "$(PLUGIN_SCHEDULER_DIR)/lib" "$(PLUGIN_SCHEDULER_DIR)/releases"
	cp -R "_build/prod/rel/$(RELEASE_NAME)/." "$(PLUGIN_SCHEDULER_DIR)/"
	scripts/harden-release.py "$(PLUGIN_SCHEDULER_DIR)" "$(RELEASE_NAME)"
	test -x "$(PLUGIN_SCHEDULER_DIR)/bin/$(RELEASE_NAME)"

check-burrito-tools:
	@command -v xz >/dev/null || { echo "Burrito MCP build requires xz on PATH."; exit 1; }
	@test -n "$(ZIG)" || { echo "Burrito MCP build requires zig 0.15.2; install with 'brew install zig@0.15' or set ZIG=/path/to/zig."; exit 1; }
	@test "$$($(ZIG) version)" = "0.15.2" || { echo "Burrito MCP build requires zig 0.15.2, found $$($(ZIG) version) at $(ZIG)."; exit 1; }

release-mcp: package-version-check check-burrito-tools
	MIX_ENV=prod mix deps.get --only prod
	rm -rf "_build/prod/rel/$(MCP_RELEASE_NAME)" "$(MCP_BURRITO_BIN)" "$(MCP_DIST_BIN)" "$(APP_BUILD_DIR)" $(BURRITO_ZIG_ARTIFACTS)
	mkdir -p "$(BURRITO_DEP_DIR)/.zig-cache/c"
	PATH="$(ZIG_PATH)" BURRITO_TARGET=$(MCP_BURRITO_TARGET) MIX_ENV=prod mix release $(MCP_RELEASE_NAME) --overwrite
	test -x "$(MCP_BURRITO_BIN)"
	cache_dir="$$("$(MCP_BURRITO_BIN)" maintenance directory)"; \
		case "$$cache_dir" in \
			*/.burrito/$(MCP_RELEASE_NAME)_*) rm -rf "$$cache_dir" ;; \
			*) echo "Refusing to remove unexpected Burrito cache directory: $$cache_dir"; exit 1 ;; \
		esac
	mkdir -p "$(MCP_DIST_DIR)"
	cp "$(MCP_BURRITO_BIN)" "$(MCP_DIST_BIN)"
	chmod 744 "$(MCP_DIST_BIN)"
	mkdir -p "$(PLUGIN_MCP_DIR)"
	cp "$(MCP_DIST_BIN)" "$(MCP_PLUGIN_BIN)"
	chmod 744 "$(MCP_PLUGIN_BIN)"
	rm -rf burrito_out
	test -x "$(MCP_DIST_BIN)"
	test -x "$(MCP_PLUGIN_BIN)"

proof: release
	scripts/proof-release.sh

proof-live: proof-mcp-live

proof-mcp: release release-mcp
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-validate.exs

proof-mcp-live: release release-mcp
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-live.exs

verify-plugin-package:
	scripts/verify-plugin-package.sh

dogfood:
	scripts/dogfood-plugin.sh

clean-release:
	rm -rf _build/prod/rel/$(RELEASE_NAME)
	rm -rf _build/prod/rel/$(MCP_RELEASE_NAME)
	rm -f "$(MCP_BURRITO_BIN)"
	rm -f "$(MCP_DIST_BIN)"
	rm -rf burrito_out
	rm -rf $(BURRITO_ZIG_ARTIFACTS)
	rm -rf "$(PLUGIN_SCHEDULER_DIR)/bin" "$(PLUGIN_SCHEDULER_DIR)"/erts-* "$(PLUGIN_SCHEDULER_DIR)/lib" "$(PLUGIN_SCHEDULER_DIR)/releases"
