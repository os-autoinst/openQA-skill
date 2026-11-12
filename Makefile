# Mirrors .github/workflows/ci.yml and the README "Development" block; change all three together.
SHELL_TESTS := $(wildcard tests/*/test-*.sh)

# CI pins these; a different version on PATH can flag or reformat differently.
RUFF_VERSION ?= 0.16.8
SHFMT_VERSION ?= 3.14.1

# Run ruff through uvx at the CI-pinned version when uv is available; otherwise use PATH and warn.
UV_AVAILABLE := $(shell uv --version >/dev/null 2>&1 && echo 1)
ifeq ($(UV_AVAILABLE),1)
RUFF ?= uvx ruff@$(RUFF_VERSION)
else
$(warning uv not found; using ruff from PATH, which may differ from CI's ruff $(RUFF_VERSION))
RUFF ?= ruff
endif

SHELLCHECK ?= shellcheck
SHFMT ?= shfmt

.PHONY: help
help: ## Display this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: all
all: help

.PHONY: test-scripts
test-scripts: ## Run the offline script test suites (tests/*/test-*.sh)
	@rc=0; for t in $(SHELL_TESTS); do bash "$$t" || rc=1; done; exit $$rc

.PHONY: check-repo
check-repo: ## Run the repository gates: skill structure and script flag index
	python3 tests/repo/check-skills.py
	python3 tests/repo/check-flags.py

.PHONY: test
test: ## Run every test suite and repository gate (CI "tests" job)
	@$(MAKE) -j test-scripts check-repo

.PHONY: check-ruff
check-ruff: ## Run ruff lint and format checks
	$(RUFF) check .
	$(RUFF) format --check .

.PHONY: check-shellcheck
check-shellcheck: ## Run shellcheck on the test suites
	$(SHELLCHECK) $(SHELL_TESTS)

.PHONY: check-shfmt
check-shfmt: ## Check shell formatting of the test suites
	$(SHFMT) -d $(SHELL_TESTS)

.PHONY: check-skills-spec
check-skills-spec: ## Advisory Agent Skills publish check via gh (CI does not fail on it)
	@gh skill publish --dry-run || echo "Advisory: gh skill publish reported findings (not a failure, matches CI)"

.PHONY: lint
lint: ## Run every lint check (CI "lint" job; check-skills-spec is advisory)
	@$(MAKE) -j check-ruff check-shellcheck check-shfmt check-tool-versions

.PHONY: tidy
tidy: ## Format code and fix fixable lint findings
	$(RUFF) format .
	$(RUFF) check --fix .

.PHONY: check-tool-versions
check-tool-versions: ## Warn if the PATH tools differ from the CI-pinned versions
	@v=$$(shfmt --version 2>/dev/null); \
	if [ "$$v" != "v$(SHFMT_VERSION)" ] && [ "$$v" != "$(SHFMT_VERSION)" ]; then \
		echo "Warning: shfmt $$v on PATH but CI pins $(SHFMT_VERSION); formatting may differ"; \
	fi

.PHONY: check-all
check-all: ## Run every check: tests, lint and the advisory spec check
	@$(MAKE) test
	@$(MAKE) lint
	@$(MAKE) check-skills-spec
