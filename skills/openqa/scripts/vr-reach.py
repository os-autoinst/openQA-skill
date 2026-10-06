#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# What the commits of a distri branch reach - test modules, schedules, loaders, unit tests - read offline from the checkout.
"""Map the committed changes of an os-autoinst distri branch to what runs them.

Reads the checkout and its git history only, no network. A verification run
fetches the pushed branch, so only commits count: BASE...HEAD.

lib/ changes are traced per sub: the subs whose code changed, then every file
that calls one of them and names its package (or calls it as a method that only
one lib file defines), up to MAX_DEPTH lib levels. A change outside any sub, or
to a hook or constructor every test class has, reaches every file that names
the package; that is not followed further. Schedule lookups reuse
check-schedule.py; loadtest() and loadtest_kernel() calls with a literal module
are the loader sites.

The checkout may be someone else's branch: every printed path and name is
sanitised and quoted where it lands in a command, files are read only inside
the checkout, and git runs without fsmonitor, external diff, textconv, colour
or filter drivers.
"""

import importlib.util
import os
import re
import shlex
import subprocess
import sys
from collections import deque

from _sanitize import ArgumentParser, one_lines

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_DEPTH = 3
MAX_LIB_SUBS = 200
MAX_USERS = 60
MAX_FILE_BYTES = 2 * 1024 * 1024
QUIET = {
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_NO_LAZY_FETCH": "1",
    "GIT_ALLOW_PROTOCOL": "",
    "GIT_TERMINAL_PROMPT": "0",
}

# Every test class has these: a change to one reaches whatever uses the package.
GENERIC = re.compile(r"^(?:run|new|test_flags|cleanup|\w+_hook)$")
NO_RUN = re.compile(
    r"^(?:\.github/|docs?/|tools/|t/data/|Makefile$|cpanfile$|\.[^/]+$)|(?:^|/)[^/]+\.md$"
)
LOADER = re.compile(r"^(?:lib/main_\w+\.pm|products/[^/]+/main\.pm)$")
_SUB = re.compile(r"^\s*sub\s+([A-Za-z_]\w*)")
_PACKAGE = re.compile(r"^\s*package\s+([A-Za-z_][\w:]*)\s*;", re.MULTILINE)
_POD = re.compile(r"^=[a-zA-Z]")
_POD_END = re.compile(r"^=cut\b")
_COMMENT = re.compile(r"^\s*(?:#|$)")
# Imports and export lists name subs without running them; use constant/base/parent do run.
_DECLARATION = re.compile(
    r"^\s*(?:(?:use|no|require)\s+(?!(?:constant|base|parent|vars|Mojo::Base)\b)"
    r"|(?:our\s+)?[@%]EXPORT\w*\s*=)"
)
_LOADTEST = re.compile(
    r"""\bloadtest(_kernel)?\s*\(?\s*(['"])(?:tests/)?([\w][\w./-]*?)(?:\.p[my])?\2"""
)
_HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


class ReachError(Exception):
    pass


def _schedule_tools():
    """check-schedule.py owns schedule parsing; its name has a dash, so load it by path."""
    spec = importlib.util.spec_from_file_location(
        "check_schedule", os.path.join(HERE, "check-schedule.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# -c overrides that switch off every configured filter driver (set by main()).
NEUTRAL = []


def filter_overrides(repo):
    """-c arguments that blank every filter driver in the config git would read.

    The dirty check reads changed files through filter.<name>.clean or .process, which
    a repository's attributes can select; reading the config itself runs nothing."""
    done = git(repo, "config", "--null", "--get-regexp", r"^filter\.", check=False)
    names = set()
    for item in text_of(done.stdout).split("\0"):
        key = item.split("\n", 1)[0]
        if key.startswith("filter.") and key.count(".") >= 2:
            names.add(key[len("filter.") : key.rindex(".")])
    if any("=" in name or "\n" in name for name in names):
        raise ReachError("a filter driver name git cannot override; check the config")
    overrides = []
    for name in sorted(names):
        for key, value in (
            ("clean", ""),
            ("smudge", ""),
            ("process", ""),
            ("required", "false"),
        ):
            overrides += ["-c", f"filter.{name}.{key}={value}"]
    return overrides


def git(repo, *args, check=True):
    try:
        done = subprocess.run(
            ["git", "-C", repo, "-c", "core.fsmonitor=false", *NEUTRAL, *args],
            capture_output=True,
            check=False,
            timeout=120,
            env={**os.environ, **QUIET},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ReachError(f"git {args[0]}: {error}") from None
    if check and done.returncode:
        message = os.fsdecode(done.stderr).strip().split("\n")[0]
        raise ReachError(f"git {args[0]} failed: {message}")
    return done


def text_of(data):
    return data if isinstance(data, str) else data.decode("utf-8", "replace")


def show(repo, rev, path):
    """The file at a revision, or None when it does not exist there."""
    done = git(repo, "show", "--no-textconv", f"{rev}:{path}", check=False)
    return text_of(done.stdout) if done.returncode == 0 else None


def module_entry(path):
    """tests/a/b.pm -> a/b, the form schedules and loadtest() use."""
    return re.sub(r"\.p[my]$", "", path[len("tests/") :])


def code_lines(text):
    """Lines with POD and whole-line comments blanked, so line numbers stay."""
    lines, pod = [], False
    for line in text.split("\n"):
        if pod or _POD.match(line):
            pod = not _POD_END.match(line)
            lines.append("")
        elif _COMMENT.match(line):
            lines.append("")
        else:
            lines.append(line)
    return lines


def declarations(lines):
    """Indexes of use/no/require statements and export lists: they name a sub, not call it."""
    found, open_statement = set(), False
    for index, line in enumerate(lines):
        if open_statement or _DECLARATION.match(line):
            found.add(index)
            open_statement = ";" not in line
    return found


def sub_spans(lines):
    """[(name, first index, last index)]: a sub ends at the next '}' in column 0."""
    starts = [
        (i, m.group(1)) for i, line in enumerate(lines) if (m := _SUB.match(line))
    ]
    spans = []
    for k, (start, name) in enumerate(starts):
        limit = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        end = next(
            (j for j in range(start, limit) if lines[j].startswith("}")), limit - 1
        )
        spans.append((name, start, end))
    return spans


def enclosing(spans, index):
    for name, start, end in spans:
        if start <= index <= end:
            return name
    return None


def package_of(text, path):
    match = _PACKAGE.search(text or "")
    if match:
        return match.group(1)
    if path.startswith("lib/"):
        return re.sub(r"\.pm$", "", path[len("lib/") :]).replace("/", "::")
    return "main"  # products/*/main.pm have no package statement


def changed_lines(diff):
    """(removed, added): [(1-based line, text)] of a -U0 diff of one file."""
    removed, added, old, new, inside = [], [], 0, 0, False
    for line in diff.split("\n"):
        match = _HUNK.match(line)
        if match:
            old, new, inside = int(match.group(1)), int(match.group(2)), True
        elif not inside:
            continue
        elif line.startswith("-"):
            removed.append((old, line[1:]))
            old += 1
        elif line.startswith("+"):
            added.append((new, line[1:]))
            new += 1
        elif line.startswith(" "):
            old += 1
            new += 1
    return removed, added


def loads(texts):
    """Module entries named by loadtest()/loadtest_kernel() in these lines."""
    found = set()
    for text in texts:
        for match in _LOADTEST.finditer(text):
            found.add(("kernel/" if match.group(1) else "") + match.group(3))
    return found


class Corpus:
    """Code of tests/, lib/ and products/ in the working tree, POD and comments blanked."""

    def __init__(self, repo, readable):
        self.files, self.spans, self.skip, self.defined = {}, {}, {}, {}
        for top, pattern in (
            ("tests", r"\.p[my]$"),
            ("lib", r"\.pm$"),
            ("products", r"\.pm$"),
        ):
            for folder, dirs, names in os.walk(os.path.join(repo, top)):
                dirs.sort()
                for name in sorted(names):
                    path = os.path.join(folder, name)
                    if not re.search(pattern, name) or not readable(path, repo):
                        continue
                    if os.path.getsize(path) > MAX_FILE_BYTES:
                        continue
                    with open(path, encoding="utf-8", errors="replace") as handle:
                        lines = code_lines(handle.read())
                    rel = os.path.relpath(path, repo).replace(os.sep, "/")
                    self.files[rel] = lines
                    self.spans[rel] = sub_spans(lines)
                    self.skip[rel] = declarations(lines)
                    if rel.startswith("lib/"):
                        for sub, _, _ in self.spans[rel]:
                            self.defined.setdefault(sub, set()).add(rel)
        self.joined = {rel: "\n".join(lines) for rel, lines in self.files.items()}

    def names_package(self, rel, package):
        return (
            re.search(r"(?<![\w:])" + re.escape(package) + r"(?!\w)", self.joined[rel])
            is not None
        )

    def users(self, package, skip):
        return [
            rel
            for rel in self.files
            if rel != skip and self.names_package(rel, package)
        ]

    def calls(self, rel, name, package, definer):
        """Indexes of lines in rel that call name, under the rules in the module docstring."""
        if name not in self.joined[rel]:
            return []
        call = re.compile(
            r"(?:(->)\s*|(?<![\w$@%]))" + re.escape(name) + r"\b(?!\s*=>)"
        )
        unique = self.defined.get(name) == {definer}
        named = rel == definer or self.names_package(rel, package)
        hits = []
        for index, line in enumerate(self.files[rel]):
            if index in self.skip[rel] or (
                _SUB.match(line) and _SUB.match(line).group(1) == name
            ):
                continue
            for match in call.finditer(line):
                if named or (match.group(1) and unique):
                    hits.append(index)
                    break
        if rel == definer:
            hits = [
                i for i in hits if enclosing(self.spans[rel], i) not in (None, name)
            ]
        return hits


class Reach:
    def __init__(self):
        self.modules = {}  # entry -> set of "via" labels
        self.loaders = {}  # loader file -> set of names it calls or loads
        self.libs = {}  # lib file -> set of subs reached (caller side)
        self.notes = []

    def module(self, entry, via):
        self.modules.setdefault(entry, set()).add(via)


def trace(corpus, reach, starts):
    """starts: [(lib file, package, subs, module level?, label)]."""
    queue = deque(
        (rel, pkg, subs, whole, label, 0) for rel, pkg, subs, whole, label in starts
    )
    done, lib_subs = set(), 0
    while queue:
        rel, package, subs, whole, label, depth = queue.popleft()
        generic = sorted(s for s in subs if GENERIC.match(s))
        if whole or generic:
            users = corpus.users(package, rel)
            why = (
                "outside any sub"
                if whole
                else f"hook or constructor {', '.join(generic)}"
            )
            if len(users) > MAX_USERS:
                reach.notes.append(
                    f"wide: {len(users)} files name {package} ({why} in {rel}); pick scenarios "
                    "by hand"
                )
            else:
                for user in users:
                    record(reach, user, f"{label} (uses {package})", None)
        for name in sorted(s for s in subs if not GENERIC.match(s)):
            if (rel, name) in done:
                continue
            done.add((rel, name))
            found = {}
            for other in corpus.files:
                hits = corpus.calls(other, name, package, rel)
                if hits:
                    found[other] = hits
            if len(found) > MAX_USERS:
                reach.notes.append(
                    f"wide: {len(found)} files call {name} ({rel}); its callers are not "
                    "listed, pick scenarios by hand"
                )
                continue
            via = f"{label}: {name}" if depth == 0 else f"{label} via {name}"
            for other, hits in found.items():
                if not other.startswith("lib/") or LOADER.match(other):
                    record(reach, other, via, name)
                    continue
                callers = {enclosing(corpus.spans[other], i) for i in hits}
                reach.libs.setdefault(other, set()).update(c or "-" for c in callers)
                if depth + 1 > MAX_DEPTH:
                    reach.notes.append(
                        f"depth: {other} calls {name}; its callers are not followed "
                        f"(more than {MAX_DEPTH} lib levels)"
                    )
                    continue
                lib_subs += 1
                if lib_subs > MAX_LIB_SUBS:
                    reach.notes.append(
                        f"cap: more than {MAX_LIB_SUBS} lib callers, stopped"
                    )
                    return
                queue.append(
                    (
                        other,
                        package_of(corpus.joined[other], other),
                        {c for c in callers if c},
                        None in callers,
                        label,
                        depth + 1,
                    )
                )


def record(reach, rel, via, name):
    if rel.startswith("tests/"):
        reach.module(module_entry(rel), via)
    elif LOADER.match(rel):
        reach.loaders.setdefault(rel, set()).add(name or "package")
    elif rel.startswith("lib/"):
        reach.libs.setdefault(rel, set()).add("(uses the package)")


def analyse_lib(repo, base, path, status):
    """(package, subs, module level?, doc only?, imports only?, loaded module entries)."""
    new = show(repo, "HEAD", path) if status != "D" else None
    old = show(repo, base, path) if status != "A" else None
    diff = text_of(
        git(
            repo,
            "diff",
            "-U0",
            "--inter-hunk-context=0",
            "--text",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            base,
            "HEAD",
            "--",
            path,
        ).stdout
    )
    removed, added = changed_lines(diff)
    package = package_of(new if new is not None else old, path)
    subs, whole, doc_only, imports = set(), False, True, False
    for text, changes in ((old, removed), (new, added)):
        if text is None:
            continue
        lines = code_lines(text)
        spans, skip = sub_spans(lines), declarations(lines)
        for number, _ in changes:
            index = number - 1
            if index >= len(lines) or not lines[index].strip():
                continue
            if index in skip:
                imports = True
                continue
            doc_only = False
            name = enclosing(spans, index)
            if name:
                subs.add(name)
            else:
                whole = True
    found = loads(text for _, text in removed + added)
    return package, subs, whole, doc_only and not imports, imports, found


def schedule_index(repo, cs, wanted):
    """entry -> [(schedule path, line)] for the wanted entries."""
    use_yaml = bool(cs.yaml)
    bases = {entry.rsplit("/", 1)[-1] for entry in wanted}
    found = {}
    for path in cs.schedules(repo):
        if not cs.readable(path, repo):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if not any(base in text for base in bases):
            continue
        doc, _ = cs.load(path, repo, use_yaml)
        rel = os.path.relpath(path, repo).replace(os.sep, "/")
        for entry, line, _ in doc.modules:
            entry = re.sub(r"\.p[my]$", "", entry)
            if entry in wanted:
                found.setdefault(entry, []).append((rel, line))
    return found


def loader_index(corpus, wanted):
    found = {}
    for rel, lines in corpus.files.items():
        if rel.startswith("tests/"):
            continue
        for index, line in enumerate(lines):
            for entry in loads([line]):
                if entry in wanted:
                    found.setdefault(entry, []).append(f"{rel}:{index + 1}")
    return found


def yaml_texts(repo, readable):
    texts = {}
    for top in ("schedule", "test_data"):
        for folder, dirs, names in os.walk(os.path.join(repo, top)):
            dirs.sort()
            for name in sorted(names):
                full = os.path.join(folder, name)
                if not name.endswith((".yaml", ".yml")) or not readable(full, repo):
                    continue
                if os.path.getsize(full) <= MAX_FILE_BYTES:
                    with open(full, encoding="utf-8", errors="replace") as handle:
                        rel = os.path.relpath(full, repo).replace(os.sep, "/")
                        texts[rel] = handle.read()
    return texts


def naming(texts, literal, regex=None):
    """[(rel, line index)] of the texts that name literal (as a whole path)."""
    pattern = re.compile(regex or r"(?<![\w.-])" + re.escape(literal) + r"(?![\w.-])")
    hits = []
    for rel, text in texts.items():
        if literal not in text:
            continue
        match = pattern.search(text)
        if match:
            hits.append((rel, text.count("\n", 0, match.start())))
    return hits


def data_users(path, texts):
    """(how it is named, [(rel, line index)]): files naming data/<x>, else its directory,
    else the directory's name as a quoted string (a path built at run time). A top-level
    directory alone (console) is named by half the tree, so neither fallback uses one."""
    inner = path[len("data/") :]
    candidates = [(inner, inner, None)]
    folder = inner.rsplit("/", 1)[0] if "/" in inner else ""
    if "/" in folder:
        candidates.append((folder, folder, None))
        name = folder.rsplit("/", 1)[-1]
        if len(name) >= 6:
            candidates.append((f"'{name}'", name, r"(['\"])" + re.escape(name) + r"\1"))
    for label, literal, regex in candidates:
        hits = naming(texts, literal, regex)
        if hits:
            return label, hits
    return inner, []


def test_data_users(path, texts):
    """Schedules that include test_data/<x>, also through other test_data files."""
    schedules, seen, frontier = set(), {path}, [path]
    while frontier:
        current = frontier.pop()
        for rel, _ in naming(texts, current):
            if rel.startswith("schedule/"):
                schedules.add(rel)
            elif rel.startswith("test_data/") and rel not in seen and len(seen) < 200:
                seen.add(rel)
                frontier.append(rel)
    return sorted(schedules)


def prove_targets(repo, packages, readable):
    found = []
    folder = os.path.join(repo, "t")
    if not os.path.isdir(folder) or not packages:
        return found
    pattern = re.compile(
        r"^\s*use\s+(?:" + "|".join(re.escape(p) for p in sorted(packages)) + r")\b",
        re.MULTILINE,
    )
    for name in sorted(os.listdir(folder)):
        full = os.path.join(folder, name)
        if not name.endswith(".t") or not readable(full, repo):
            continue
        if os.path.getsize(full) <= MAX_FILE_BYTES:
            with open(full, encoding="utf-8", errors="replace") as handle:
                if pattern.search(handle.read()):
                    found.append(f"t/{name}")
    return found


def capped(items, most):
    shown = list(items)[:most]
    rest = len(items) - len(shown)
    return ", ".join(shown) + (f" [+{rest} more]" if rest > 0 else "")


def classify(path, status, ctx):
    """One changed file: record what it reaches in ctx, return its detail line or None."""
    corpus, reach, texts, most = ctx["corpus"], ctx["reach"], ctx["texts"], ctx["most"]
    gone = " (removed)" if status == "D" else ""
    if path.startswith("tests/") and re.search(r"\.p[my]$", path):
        reach.module(module_entry(path), "removed" if gone else "changed")
        return f"{path}{gone}: test module {module_entry(path)}"
    if path.startswith("schedule/") and path.endswith((".yaml", ".yml")):
        ctx["schedules"].setdefault(path, set()).add("removed" if gone else "changed")
        return f"{path}{gone}: schedule"
    if (path.startswith("lib/") or LOADER.match(path)) and path.endswith(".pm"):
        package, subs, whole, doc_only, imports, loaded = analyse_lib(
            ctx["repo"], ctx["base"], path, status
        )
        ctx["packages"].add(package)
        if doc_only and not loaded:
            return f"{path}{gone}: comments or POD only: no run needed"
        if imports and not (subs or whole or loaded):
            return (
                f"{path}{gone}: imports or exports only: not traced; a dropped export "
                "breaks callers that still import it"
            )
        parts = []
        if subs:
            parts.append(f"subs {capped(sorted(subs), most)}")
        if whole:
            parts.append("code outside any sub")
        if loaded:
            parts.append(f"loads {capped(sorted(loaded), most)}")
            for entry in loaded:
                reach.module(entry, f"loaded in {path}")
        # A loader's top-level code runs at scheduling time; what it loads is in `loaded`.
        whole_traced = whole and not LOADER.match(path)
        if subs or whole_traced:
            ctx["starts"].append((path, package, subs, whole_traced, path))
        return f"{path}{gone}: {package}: {'; '.join(parts) or 'no code line'}"
    if path.startswith("data/"):
        needle, users = data_users(path, texts)
        if len(users) > MAX_USERS:
            reach.notes.append(
                f"wide: {len(users)} files name {needle} ({path}); pick scenarios by hand"
            )
            users = []
        for rel, line in users:
            if rel.startswith("tests/"):
                reach.module(module_entry(rel), f"uses {path}")
            elif rel.startswith("schedule/"):
                ctx["schedules"].setdefault(rel, set()).add(f"uses {path}")
            elif rel.startswith("lib/") and rel in corpus.spans:
                sub = enclosing(corpus.spans[rel], line)
                package = package_of(corpus.joined[rel], rel)
                ctx["starts"].append(
                    (rel, package, {sub} if sub else set(), not sub, path)
                )
        names = [rel for rel, _ in users]
        found = capped(names, most) if names else "nothing found (built at run time?)"
        return f"{path}{gone}: data, named as {needle} by {found}"
    if path.startswith("test_data/"):
        users = test_data_users(path, texts)
        for rel in users:
            ctx["schedules"].setdefault(rel, set()).add(f"includes {path}")
        found = (
            capped(users, most)
            if users
            else "no schedule: set by YAML_TEST_DATA in the job group"
        )
        return f"{path}{gone}: test data, included by {found}"
    if path.startswith("t/") and path.endswith(".t"):
        if not gone:
            ctx["units"].append(path)
        return f"{path}{gone}: unit test"
    if NO_RUN.search(path):
        ctx["no_run"].append(path)
        return None
    return f"{path}{gone}: not classified, check by hand"


def changed_files(repo, base):
    """[(status, path)]: a rename is its old path removed and its new path added."""
    raw = text_of(
        git(
            repo,
            "diff",
            "-z",
            "--name-status",
            "-M",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            base,
            "HEAD",
        ).stdout
    ).split("\0")
    changes, index = [], 0
    while index < len(raw) - 1:
        status = raw[index][:1]
        if status in "RC":
            if status == "R":
                changes.append(("D", raw[index + 1]))
            changes.append(("A", raw[index + 2]))
            index += 3
        else:
            changes.append((status, raw[index + 1]))
            index += 2
    return changes


def main():
    parser = ArgumentParser(
        prog="vr-reach.py",
        description="What the commits of an os-autoinst distri branch reach: changed test "
        "modules, the callers of changed lib subs (up to 3 lib levels), the users of changed "
        "data files, the schedules and loadtest() sites that run them, the unit tests of "
        "changed libs, and the oqa-sweep.py calls that find scenarios to clone. Offline: reads "
        "the checkout and git only. Warns when there are uncommitted changes or HEAD is not "
        "pushed, because a verification run fetches the pushed branch.",
        epilog="Exit codes: 0 the digest was printed, 2 usage or runtime error (not a distri "
        "or git checkout, unknown --base, no merge base). The callers are a heuristic: a sub name that other packages "
        "define too, or a call through a code reference, can add or hide a caller; a call "
        "guarded by a runtime condition counts like any other.",
    )
    parser.add_argument(
        "--repo", default=".", help="distri checkout (default: current directory)"
    )
    parser.add_argument(
        "--base",
        default="origin/master",
        metavar="REF",
        help="upstream ref the branch started from (default: origin/master; the diff is "
        "BASE...HEAD)",
    )
    parser.add_argument(
        "--max-items",
        type=int,
        default=25,
        metavar="N",
        help="list at most N names per line, N files, N modules, N schedules and N next "
        "lines of a kind (default: 25)",
    )
    args = parser.parse_args()
    most = max(args.max_items, 1)
    repo = os.path.abspath(args.repo)
    out = []
    try:
        if not all(os.path.isdir(os.path.join(repo, d)) for d in ("lib", "tests")):
            raise ReachError(
                f"no lib/ and tests/ in {args.repo}: not a distri checkout"
            )
        if args.base.startswith("-"):
            raise ReachError(f"not a ref: {args.base}")
        if git(repo, "rev-parse", "--git-dir", check=False).returncode:
            raise ReachError(f"{args.repo} is not a git checkout")
        NEUTRAL[:] = filter_overrides(repo)
        if git(
            repo,
            "rev-parse",
            "--verify",
            "--quiet",
            f"{args.base}^{{commit}}",
            check=False,
        ).returncode:
            raise ReachError(
                f"unknown --base {args.base}; fetch upstream or name the ref"
            )
        done = git(repo, "merge-base", args.base, "HEAD", check=False)
        if done.returncode:
            raise ReachError(
                f"no merge base of {args.base} and HEAD (a shallow clone? fetch more history)"
            )
        base = text_of(done.stdout).strip()
        head = text_of(git(repo, "rev-parse", "HEAD").stdout).strip()
        changes = changed_files(repo, base)
        out.append(
            f"repo={args.repo} base={args.base} merge_base={base[:12]} head={head[:12]} "
            f"files={len(changes)}"
        )
        # Content comparison runs no filter: every driver is blanked in NEUTRAL.
        touched = text_of(git(repo, "diff-index", "--name-only", "HEAD", "--").stdout)
        touched = [name for name in touched.split("\n") if name]
        untracked = text_of(
            git(repo, "ls-files", "--others", "--exclude-standard").stdout
        ).split("\n")
        untracked = [name for name in untracked if name]
        if touched or untracked:
            out.append(
                f"warning: {len(touched)} changed (or touched) and {len(untracked)} untracked "
                "files are not committed: a verification run never sees them"
            )
        pushed = text_of(
            git(
                repo,
                "for-each-ref",
                "--contains",
                "HEAD",
                "--format=%(refname)",
                "refs/remotes",
            ).stdout
        ).strip()
        if not pushed:
            out.append(
                "warning: HEAD is on no remote-tracking branch: push before cloning, the "
                "worker fetches the pushed branch when the job starts"
            )

        cs = _schedule_tools()
        corpus = Corpus(repo, cs.readable)
        reach = Reach()
        ctx = {
            "repo": repo,
            "base": base,
            "corpus": corpus,
            "reach": reach,
            "most": most,
            "texts": None,
            "schedules": {},
            "starts": [],
            "packages": set(),
            "units": [],
            "no_run": [],
        }
        details = []
        for status, path in changes:
            if ctx["texts"] is None and path.startswith(("data/", "test_data/")):
                ctx["texts"] = {**corpus.joined, **yaml_texts(repo, cs.readable)}
            line = classify(path, status, ctx)
            if line:
                details.append(line)
        out.extend(details[:most])
        if len(details) > most:
            out.append(f"[+{len(details) - most} more files]")
        if ctx["no_run"]:
            out.append(
                f"no openQA run needed: {capped(ctx['no_run'], 5)} (docs, CI, tools)"
            )

        trace(corpus, reach, ctx["starts"])
        vias = [
            f"via {lib}: {capped(sorted(subs), most)}"
            for lib, subs in sorted(reach.libs.items())
        ]
        vias += [
            f"loader {loader} calls {capped(sorted(names), most)}: the scheduling of its "
            "products may change"
            for loader, names in sorted(reach.loaders.items())
        ]
        for lines in (vias, reach.notes):
            out.extend(lines[:most])
            if len(lines) > most:
                out.append(f"[+{len(lines) - most} more]")

        schedules = ctx["schedules"]
        wanted = set(reach.modules)
        by_schedule = schedule_index(repo, cs, wanted) if wanted else {}
        by_loader = loader_index(corpus, wanted) if wanted else {}
        loaded, listed = [], 0

        # Modules a change reaches directly first, those reached through other subs after.
        def indirect(entry):
            return all(" via " in why for why in reach.modules[entry])

        for entry in sorted(wanted, key=lambda entry: (indirect(entry), entry)):
            places = by_schedule.get(entry, [])
            for rel, _ in places:
                schedules.setdefault(rel, set()).add(entry)
            sites = by_loader.get(entry, [])
            where = []
            if places:
                where.append(f"{len(places)} schedule line(s)")
            if sites:
                where.append(f"loadtest at {capped(sites, 3)}")
                loaded.append(entry)
            listed += 1
            if listed <= most:
                why = capped(sorted(reach.modules[entry]), 3)
                out.append(
                    f"module {entry} ({why}): "
                    + ("; ".join(where) or "not scheduled anywhere")
                )
        if listed > most:
            out.append(f"[+{listed - most} more modules]")
        prove = sorted(
            set(ctx["units"]) | set(prove_targets(repo, ctx["packages"], cs.readable))
        )

        out.append(
            f"summary: modules={len(wanted)} schedules={len(schedules)} "
            f"loaded_by_perl={len(loaded)} unit_tests={len(prove)}"
        )
        # Names come from the checkout: quoted, so a pasted line runs nothing else.
        if prove:
            more = f" [+{len(prove) - most} more]" if len(prove) > most else ""
            out.append(
                f"next: prove -l -Ios-autoinst/ {shlex.join(prove[:most])}{more}"
            )
        ordered = sorted(schedules)
        if len(ordered) > most:
            out.append(
                f"next: {len(ordered)} schedules, more than {most}: pick 1-3 that cover "
                "the change by hand; first ones: " + capped(ordered, 5)
            )
        else:
            for rel in ordered:
                out.append(
                    f"next: scripts/oqa-sweep.py --uses-schedule {shlex.quote(rel)} "
                    "--group <id>|--match <regex>"
                )
        for entry in loaded[:most]:
            out.append(
                f"next: scripts/oqa-sweep.py --group <id> --passed --module "
                f"{shlex.quote(entry.rsplit('/', 1)[-1])}"
            )
        if len(loaded) > most:
            out.append(f"[+{len(loaded) - most} more modules loaded by Perl]")
    except ReachError as error:
        print(one_lines([*out, f"error: {error}"]), end="")
        return 2
    except OSError as error:
        name = error.filename or ""
        print(one_lines([*out, f"error: cannot read {name}: {error.strerror}"]), end="")
        return 2
    print(one_lines(out, max_line=400, max_items=2000), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
