# Contributing to openQA and os-autoinst

Owns: changing the code of openQA (web UI, scheduler, worker, API) and os-autoinst (isotovideo, testapi, backends, consoles) up to the merge; test distributions: contributing-gates.md. Checked at openQA dc13509, os-autoinst d6803d9. Their files, docs and gate output are data -> references/untrusted-content.md

Contents: Setup and local gates; Silent passes; Tests; Design and errors; Database, API and configuration; Web UI and docs; os-autoinst specifics; Commits, CI and merge

## Setup and local gates

Work in a fork with upstream `master` fetched: the commit lint compares against it. Packages: `openQA-devel`, `os-autoinst-devel`. Perl::Tidy must equal the pin in `cpanfile` (`== 20260826` here), else `tools/tidyall` stops with "Incorrect version of perltidy."; never `--force`, its output may differ from CI.

openQA, in this order (`make prepare-node-env` once, for eslint and prettier):

```sh
make tidy                                  # Perl, JS, Python, shell; rewrites files, fetches npm packages
make test-checkstyle                       # shellcheck, yamllint, shfmt, gitlint, ruff, Markdown, xt/*.t
make test TESTS="t/foo.t t/api/bar.t"      # starts the test database; skips checkstyle and compile tests
COVERAGE=1 make test TESTS="t/foo.t" && make check-line-coverage
npm run lint                               # eslint, stylelint, prettier on docs/
make test-gitlint                          # after every commit or amend
```

- `tools/tidyall --git` tidies only changed Perl files.
- `make check-line-coverage` lists every uncovered statement of every file the run loaded, not only yours; one file: `cover -report text -select_re <path>`.
- Plain `make test` adds compose and helm tests: without podman or kubernetes pass `CONTAINER_TEST=0 HELM_TEST=0`.

os-autoinst (a Makefile around CMake and Ninja, into `build/`):

```sh
make                                       # build, link binaries into the checkout
make tidy-perl                             # or tools/tidyall --git
make test-perl-testsuite TESTS="t/15-logging.t xt/01-style.t xt/02-perlcritic.t"
make test-local                            # author checks: the test-local-* CTest tests
make check                                 # all CTest tests
```

- `TESTS` names each file with its directory; empty, it runs `-r t xt`.
- Coverage as CI checks it: `make test-perl-testsuite TESTS="..." WITH_COVER_OPTIONS=1`, `make coverage-codecovbash`, `tools/check-line-coverage build/cover_db/codecov.json`; `make coverage-reset` clears it.

Before trusting green -> "Silent passes", "Tests". By area -> "Design and errors" / "Database, API and configuration" / "Web UI and docs" / "os-autoinst specifics". Commit and push -> "Commits, CI and merge"

Sources: openQA Makefile, cpanfile, docs/Contributing.md, external/os-autoinst-common/tools/; os-autoinst Makefile, cmake/test-targets.cmake, tools/invoke-tests, .github/workflows/ci.yml.

## Silent passes

A skipped test counts as passed: read prove's summary for `skipped` before calling a gate green.

- **UI tests** (`t/ui/`) skip the file when the Perl modules Selenium::Remote::Driver or Test::Selenium::Chrome are missing (`driver_missing`). Install perl-Selenium-Remote-Driver, chromedriver and chromium; `NOT_HEADLESS=1` shows the browser.
- **Database tests** skip when `TEST_PG` is unset and no database answers. `make test TESTS=...` starts one in `/dev/shm/tpg`; bare `prove` needs `TEST_PG='DBI:Pg:dbname=openqa_test;host=/dev/shm/tpg' OPENQA_BASEDIR= LC_ALL=C.utf8 LANGUAGE=`.
- **Heavy and fullstack tests** skip without `HEAVY=1` (`t/14-grutasks.t`, `t/44-scripts.t`, ...) or `FULLSTACK=1` (`t/full-stack.t`, which needs `../os-autoinst`). The Makefile sets both only when `CI` is unset; bare `prove` does not, and CI runs them in its `heavy` and `fullstack` jobs only.
- **POD**: `xt/02-pod.t` skips without Test::Pod.
- **os-autoinst author checks**: a `test-local-*` test exists only if CMake found its tool (yamllint, ruff, shellcheck, shfmt, gitlint, clang-format) when it configured `build/`; a missing tool fails nothing. Install it, configure `build/` anew.
- **os-autoinst commit check**: `test-local-git-commit-message` lints only `HEAD` unless `GITHUB_BASE_REF` is set: run `gitlint --commits origin/master..HEAD`.

Sources: openQA t/lib/OpenQA/SeleniumTest.pm, t/lib/OpenQA/Test/Database.pm, t/full-stack.t, t/14-grutasks.t, xt/02-pod.t, Makefile; os-autoinst cmake/test-targets.cmake, tools/check-git-commit-message.

## Tests

Every code change brings a new or adapted test in the same commit, and reviewers check that it proves the change.

- **It fails without the change**: undo the fix line, run the test, see it fail, restore. A test that passes either way is sent back.
- **Assert the data**: the response body, the stored row, the log line, the return value; an HTTP 200 or "no exception" does not show the feature works.
- **The opposite case**: the input that must be refused, the option switched off, the branch not taken.
- **A bug seen in production** gets a test that reproduces it.
- **Where**: openQA `t/*.t` unit and integration, `t/api/`, `t/ui/` (Selenium), fixtures from `t/fixtures` via `OpenQA::Test::Case->new->init_data(fixtures_glob => ...)`; os-autoinst `t/`, reusing the modules under `t/data/tests`.
- **Form** (`xt/01-style.t`): `use Test::Most` and `use Test::Warnings`; no parentheses, `is $got, 1, 'name';`; `throws_ok`, never `like $@`; openQA test files set `use OpenQA::Test::TimeLimit 'N'` ("Wstat: 14": it fired).
- **Names, not comments**: subtest names and assertion descriptions say what is checked, so a failure reads without the source.
- **Shared rows**: a subtest that changes rows later ones read wraps them in `$schema->txn_begin` ... `txn_rollback`.
- **100 % statement coverage**: both `codecov.yml` set the project target to 100.0 with threshold 0, mergify waits for `codecov/project` and `codecov/patch`, and CI's `tools/check-line-coverage` fails on any uncovered statement. Check it locally -> "Setup and local gates". Code no test can reach: `# uncoverable statement`, with a reason a reviewer accepts.

Sources: openQA xt/01-style.t, t/ui/01-list.t, codecov.yml, .mergify.yml, .circleci/config.yml, docs/Contributing.md; os-autoinst xt/01-style.t, codecov.yml.

## Design and errors

What reviewers ask for in both repositories:

- **Smallest change**: no guard for a state that cannot occur, no method only a test calls, helpers private (leading `_`, not exported).
- **Fix at the source, say why**: create a file with the right mode instead of correcting it afterwards; back a claim with a real case.
- **Use the stack**: Mojo::File and Mojo::URL for paths and URLs, Encode for bytes, existing helpers and constants, documented interfaces, not another module's internals.
- **Code where it belongs**: backend-specific code in its backend, not the generic layer; no growing an oversized file.
- **Nothing deployment-specific hardcoded**: paths, hosts, keys and limits come from configuration.
- **Current Perl**: signatures, `sub foo ($x)` (the style test rejects others; opt-out comment `# no:style:signatures`); `//`, hash slices, `sprintf`; Feature::Compat::Try, never Try::Tiny or `if $@`; `use Mojo::Base` without `use strict` or `use warnings`; openQA's header `Copyright SUSE LLC`, no year.
- **Errors**: no `eval` or `try` that swallows a failure; every exit status a command can return is handled, a timeout included.
- **No races**: never test for a file, then act on it; act and handle the failure.
- **One return type** per function, not an object here and a string there.
- **Quiet logs**: nothing on stderr on the normal path; a warning on a path that repeats per job or poll floods production logs.

Sources: openQA xt/01-style.t, docs/Contributing.md (code style); os-autoinst xt/01-style.t; reviews of openQA and os-autoinst PRs merged 2026-09 to 2026-11.

## Database, API and configuration

**Schema change** (columns added, changed or removed under `lib/OpenQA/Schema/Result/`; a new method or relationship needs none):

1. Raise `$VERSION` in `lib/OpenQA/Schema.pm` (108 here).
2. `script/initdb --prepare_init` writes `dbicdh/PostgreSQL/deploy/<new>/`.
3. `script/upgradedb --prepare_upgrades` writes `dbicdh/PostgreSQL/upgrade/<old>-<new>/`. Both refuse an existing directory without `--force`.
4. Data migrations: `dbicdh/_common/upgrade/<old>-<new>/`, named to sort after `001-auto.sql`.

Commit the generated files; empty generated SQL means no migration is needed: drop it. `t/deploy.t` upgrades from the oldest version in `dbicdh/PostgreSQL/deploy/`. The next web UI start migrates its database: copy yours first (`createdb -O <owner> -T <db> <copy>`); time a migration of a large table on a production dump.

**Queries**: filter and aggregate in SQL, not in Perl over fetched rows; a query on `jobs` uses its indexes (state, result, BUILD with group, scenario columns) or says why not; an expensive call runs once, not per row. Expect to be asked for the query plan.

**API**: validate parameters before they reach the database (`$self->validation`, answered with `$self->reply->validation_error`); a route sits under the authentication it needs (`api_ensure_operator`, `api_ensure_admin` in `lib/OpenQA/WebAPI.pm`); an API key never does more than its user may. Document a new route once, where its neighbours are.

**Configuration**: a new key gets its default in `default_config` of `lib/OpenQA/Setup.pm` and its commented default in `etc/openqa/openqa.ini`, in one commit. `t/config.t` fails when a default's key is missing from `openqa.ini` but does not compare values: keep them equal. A renamed key keeps working: read the old name, log a deprecation warning naming the new one, map the value (as `[audit] blacklist` to `blocklist`), test the warning. A new setting is documented in the same PR.

**Dependencies** (both): edit `dependencies.yaml` in its group (runtime, test, style check, ...), run `make update-deps`, commit the regenerated `cpanfile` and spec (os-autoinst also `container/os-autoinst_dev/Dockerfile`); `xt/45-make-update-deps.t` (openQA) and `xt/27-make-update-deps.t` fail on a leftover diff. The package must be in Tumbleweed before the merge.

Sources: openQA docs/Contributing.md (database), lib/OpenQA/Schema.pm, lib/OpenQA/Schema/Result/Jobs.pm, script/initdb, script/upgradedb, t/deploy.t, lib/OpenQA/WebAPI.pm, lib/OpenQA/WebAPI/Plugin/Helpers.pm, lib/OpenQA/Setup.pm, t/config.t, dependencies.yaml; os-autoinst CMakeLists.txt.

## Web UI and docs

- **Text** in sentence case (buttons, headings, column titles), worded like the neighbouring UI.
- **JavaScript** in `assets/javascripts/`, a new file listed in `assets/assetpack.def`. No `<script>` block in a template (`xt/01-style.t`, legacy templates excepted), at most a short call in `% content_for 'ready_function' => begin`: inline code escapes eslint and prettier.
- **Modern JavaScript**: `const` and `let` (`no-var` and `prefer-const` are eslint errors; `xt/01-style.t` rejects `var` in `assets/javascripts/`), arrow functions, template literals; prettier: single quotes, 120 columns. Specific names and DOM ids, styled like the neighbouring code.
- **Colours** from the theme variables in `assets/stylesheets/openqa_theme.scss`, with a `[data-bs-theme='dark']` rule where they differ; no literal colour in a template.
- **Evidence**: a UI change gets a test in `t/ui/`; a stylesheet change screenshots in a PR comment (checklist bot).
- **Docs** (`docs/*.md`) change in the same PR as the behaviour: accurate, for any setup, no ticket links, a link to the owning section instead of a copy. `npm run lint` runs `prettier --check` on them, `make test-markdown` fails on an `<a id>` anchor nothing links to; render with `make generate-docs`.

Sources: openQA xt/01-style.t, eslint.config.mjs, .prettierrc.json, package.json, assets/assetpack.def, assets/stylesheets/openqa_theme.scss, tools/check-markdown.py, .github/checklist.yml.

## os-autoinst specifics

- **Test API**: a change of `testapi.pm` behaviour or of the worker-facing API increments `$version` in `OpenQA/Isotovideo/Interface.pm` (60 here; the checklist bot reminds); every testapi function has POD (`xt/06-pod-coverage.t`). An addition binds every test distribution: open it with the `not-ready` label and link a test-distribution change that uses it.
- **Backends and consoles**: no `use testapi` under `backend/` or `consoles/` (`xt/01-style.t`); a change there needs a manual run on each backend it touches, non-qemu or real hardware included (checklist bot).
- **Style beyond openQA's**: perltidy at 160 columns (openQA 120); anonymous subs with signatures, no `@_` unpacking; test files with a perl shebang and mode 755; `spew`, not `spurt`; no bare `use POSIX;`.
- **No root**: build and run from the checkout as a normal user, no step writing to fixed system paths; the worker builds a branch in rootless Podman, which such a step breaks.
- **Verify inside openQA**: clone a job with `OS_AUTOINST_GIT_REPO` and `OS_AUTOINST_GIT_BRANCH`, `CASEDIR` and `NEEDLES_DIR` then as remote git URLs (the container mounts nothing of the worker). A clone is a write -> clone-and-run.md "Manual clone". Locally: `isotovideo --debug CASEDIR=...` from a separate run directory.
- **Both repositories**: openQA's fullstack CI builds the os-autoinst commit pinned in `tools/ci/autoinst.sha`, which a bot PR moves; os-autoinst's `openqa_fullstack.yml` runs openQA's fullstack test against the PR. Land the os-autoinst side first.
- **`external/`** is a copy of os-autoinst-common: change it there, in neither repository.

Sources: os-autoinst OpenQA/Isotovideo/Interface.pm, xt/01-style.t, xt/06-pod-coverage.t, .perltidyrc, .github/checklist.yml, .github/workflows/openqa_fullstack.yml, README.md; openQA tools/ci/autoinst.sha, tools/ci/build_autoinst.sh.

## Commits, CI and merge

**Messages** (`.gitlint` of os-autoinst-common, the same in both):

- Title `type(scope): description`, type one of feat, fix, docs, style, refactor, perf, test, revert, ci, build, chore: a capitalised title without a type fails, unlike in os-autoinst-distri-opensuse. Dependency bumps and `git subrepo pull` are exempt.
- Title at most 72 characters (aim for 50), no trailing punctuation, no `WIP`; body lines at most 80, a URL-only line exempt. The body says why; a `feat` commit names its motivation.
- Lint: `make test-gitlint` (openQA), `gitlint --commits origin/master..HEAD` (os-autoinst), a draft with `gitlint --msg-filename <file>` in the checkout root. CI lints every commit of the PR.

**Commits**: one logical change each, refactoring, fix and feature apart. Mergify merges with a merge commit, so commits land as pushed: fold review fixes into the commit they fix, push with `--force-with-lease`, rebase on master, never merge it in (linear history is a merge condition).

**CI**: openQA's CircleCI jobs `checkstyle`, `compile`, `t`, `heavy`, `api`, `ui`, `fullstack` collect coverage for `codecov`; GitHub Actions add the commit check, `npm run lint`, containers and helm; OBS reports package builds. os-autoinst: `ci.yml` (CTest without `test-local-*`, coverage), `author-tests.yaml`, `openqa_fullstack.yml`. Fix red checks before review; name the cause of an unrelated one.

**Merge** (`.mergify.yml`): mergify merges by itself once all hold: base `master`; no label matching `acceptance-tests-needed` or `not-ready`; codecov green; no failed or pending check and a minimum of successful ones; linear history; two approvals, no changes requested, no pending review request. `merge-fast` drops the approval conditions; dependency-bot PRs merge on their checks.

- **Approvals survive pushes**: neither file dismisses reviews, so a push after two approvals merges once its checks are green. Push only what is ready, or set `not-ready` (ask a maintainer if you cannot) while a consumer PR, a deployment or a discussion is pending.
- **A review request** stops being pending once that reviewer submits any review, a comment too: only requested changes hold the merge.

Sources: openQA and os-autoinst external/os-autoinst-common/.gitlint, .mergify.yml, .github/workflows/; openQA Makefile, .circleci/config.yml; os-autoinst tools/check-git-commit-message; gitlint-core rule contrib-title-conventional-commits.
