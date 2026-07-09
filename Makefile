.PHONY: setup format-check quality credo-check security-check audit-check package-version-check install-docs-check dialyzer-check browser-e2e-setup browser-e2e test spec-lint build release release-mcp package-homebrew-runtime proof proof-live proof-mcp proof-mcp-live verify-plugin-package dogfood clean-release

RELEASE_NAME ?= agent_loops
RELEASE_CTL = _build/prod/rel/$(RELEASE_NAME)/bin/$(RELEASE_NAME)
APP_BUILD_DIR = _build/prod/lib/codex_loops
HOMEBREW_PACKAGE_DIR ?= _build/homebrew
HOMEBREW_RUNTIME_ROOT = $(HOMEBREW_PACKAGE_DIR)/libexec

setup:
	mix local.hex --if-missing --force
	mix local.rebar --if-missing --force
	mix deps.get

format-check:
	mix format --check-formatted

quality:
	$(MAKE) format-check
	$(MAKE) install-docs-check
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

build: package-version-check
	mix compile --warnings-as-errors

release: package-version-check
	MIX_ENV=prod mix deps.get --only prod
	rm -rf "_build/prod/rel/$(RELEASE_NAME)" "$(APP_BUILD_DIR)"
	MIX_ENV=prod mix release $(RELEASE_NAME) --overwrite
	test -x "$(RELEASE_CTL)"
	test -x "_build/prod/rel/$(RELEASE_NAME)/bin/codex-loops"
	test -x "_build/prod/rel/$(RELEASE_NAME)/bin/codex-loops-mcp"

# Compatibility target: MCP is a command in the single OTP release.
release-mcp: release
	_build/prod/rel/$(RELEASE_NAME)/bin/codex-loops-mcp --version

# Formula input only. This stages a Homebrew-style prefix; it is not a user install command.
package-homebrew-runtime: release
	rm -rf "$(HOMEBREW_PACKAGE_DIR)"
	mkdir -p "$(HOMEBREW_RUNTIME_ROOT)/scheduler" "$(HOMEBREW_RUNTIME_ROOT)/mcp" "$(HOMEBREW_RUNTIME_ROOT)/bin"
	mkdir -p "$(HOMEBREW_RUNTIME_ROOT)/share/licenses/codex-loops" "$(HOMEBREW_RUNTIME_ROOT)/share/doc/codex-loops"
	cp -R "_build/prod/rel/$(RELEASE_NAME)/." "$(HOMEBREW_RUNTIME_ROOT)/scheduler/"
	cp "$(HOMEBREW_RUNTIME_ROOT)/scheduler/bin/codex-loops-mcp" "$(HOMEBREW_RUNTIME_ROOT)/mcp/codex-loops-mcp"
	cp "$(HOMEBREW_RUNTIME_ROOT)/scheduler/bin/codex-loops" "$(HOMEBREW_RUNTIME_ROOT)/bin/codex-loops"
	cp LICENSE "$(HOMEBREW_RUNTIME_ROOT)/share/licenses/codex-loops/LICENSE"
	cp deps/anubis_mcp/LICENSE "$(HOMEBREW_RUNTIME_ROOT)/share/licenses/codex-loops/ANUBIS_MCP_LICENSE"
	cp plugins/codex-loops/THIRD_PARTY_NOTICES.md "$(HOMEBREW_RUNTIME_ROOT)/share/doc/codex-loops/THIRD_PARTY_NOTICES.md"
	chmod 755 "$(HOMEBREW_RUNTIME_ROOT)/mcp/codex-loops-mcp" "$(HOMEBREW_RUNTIME_ROOT)/bin/codex-loops"
	CODEX_LOOPS_RUNTIME_ROOT="$(abspath $(HOMEBREW_RUNTIME_ROOT))" "$(HOMEBREW_RUNTIME_ROOT)/bin/codex-loops" --version
	CODEX_LOOPS_RUNTIME_ROOT="$(abspath $(HOMEBREW_RUNTIME_ROOT))" "$(HOMEBREW_RUNTIME_ROOT)/mcp/codex-loops-mcp" --version
	test -s "$(HOMEBREW_RUNTIME_ROOT)/share/licenses/codex-loops/ANUBIS_MCP_LICENSE"
	grep -Fq 'https://github.com/zoedsoupe/anubis-mcp' "$(HOMEBREW_RUNTIME_ROOT)/share/doc/codex-loops/THIRD_PARTY_NOTICES.md"

proof: release
	scripts/proof-release.sh

proof-live: proof-mcp-live

proof-mcp: package-homebrew-runtime
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-validate.exs

proof-mcp-live: package-homebrew-runtime
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-live.exs

verify-plugin-package:
	scripts/verify-plugin-package.sh

dogfood:
	scripts/dogfood-plugin.sh

clean-release:
	rm -rf _build/prod/rel/$(RELEASE_NAME)
	rm -rf "$(HOMEBREW_PACKAGE_DIR)"
