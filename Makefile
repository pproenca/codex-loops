.PHONY: setup test build release proof proof-live clean-release

RELEASE_NAME ?= agent_loops
RELEASE_CTL = _build/prod/rel/$(RELEASE_NAME)/bin/$(RELEASE_NAME)

setup:
	mix local.hex --if-missing --force
	mix local.rebar --if-missing --force
	mix deps.get
	@if command -v pnpm >/dev/null 2>&1; then pnpm install --frozen-lockfile; else echo "pnpm not found; skipping Node workspace install"; fi

test:
	mix test

build:
	mix compile --warnings-as-errors

release:
	MIX_ENV=prod mix deps.get --only prod
	MIX_ENV=prod mix release $(RELEASE_NAME) --overwrite
	test -x "$(RELEASE_CTL)"

proof: release
	scripts/proof-release.sh

proof-live: release
	scripts/proof-release-live.sh

clean-release:
	rm -rf _build/prod/rel/$(RELEASE_NAME)
