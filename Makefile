.PHONY: setup test build release proof proof-live proof-mcp proof-mcp-live verify-plugin-package dogfood clean-release

RELEASE_NAME ?= agent_loops
RELEASE_CTL = _build/prod/rel/$(RELEASE_NAME)/bin/$(RELEASE_NAME)
PLUGIN_SCHEDULER_DIR = plugins/codex-loops/scheduler

setup:
	mix local.hex --if-missing --force
	mix local.rebar --if-missing --force
	mix deps.get

test:
	mix test

build:
	mix compile --warnings-as-errors

release:
	MIX_ENV=prod mix deps.get --only prod
	rm -rf "_build/prod/rel/$(RELEASE_NAME)"
	MIX_ENV=prod mix release $(RELEASE_NAME) --overwrite
	test -x "$(RELEASE_CTL)"
	mkdir -p "$(PLUGIN_SCHEDULER_DIR)"
	rm -rf "$(PLUGIN_SCHEDULER_DIR)/bin" "$(PLUGIN_SCHEDULER_DIR)"/erts-* "$(PLUGIN_SCHEDULER_DIR)/lib" "$(PLUGIN_SCHEDULER_DIR)/releases"
	cp -R "_build/prod/rel/$(RELEASE_NAME)/." "$(PLUGIN_SCHEDULER_DIR)/"
	test -x "$(PLUGIN_SCHEDULER_DIR)/bin/$(RELEASE_NAME)"

proof: release
	scripts/proof-release.sh

proof-live: proof-mcp-live

proof-mcp: release
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-validate.exs

proof-mcp-live: release
	MIX_ENV=dev mix run --no-start scripts/proof-mcp-live.exs

verify-plugin-package:
	scripts/verify-plugin-package.sh

dogfood:
	scripts/dogfood-plugin.sh

clean-release:
	rm -rf _build/prod/rel/$(RELEASE_NAME)
	rm -rf "$(PLUGIN_SCHEDULER_DIR)/bin" "$(PLUGIN_SCHEDULER_DIR)"/erts-* "$(PLUGIN_SCHEDULER_DIR)/lib" "$(PLUGIN_SCHEDULER_DIR)/releases"
