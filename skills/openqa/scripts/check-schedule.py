#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Lint YAML schedules of an os-autoinst distri checkout, or list the schedules that use a module.
"""Rules follow t/schema/Schedule-1.yaml, lib/main_common.pm loadtest() and .yamllint upstream."""

import os
import re
import subprocess
import sys

from _sanitize import ArgumentParser, one_lines

try:
    import yaml
except ImportError:
    yaml = None

TOP_KEYS = (
    "name",
    "description",
    "schedule",
    "vars",
    "test_data",
    "conditional_schedule",
)
REQUIRED = ("name", "schedule")
MAX_PAIRS = 20000
VAR_KEY = re.compile(r"^[A-Z_+]+[A-Z0-9_]*$")
COND_KEY = re.compile(r"^[a-zA-Z0-9_]+$")
COND_VAR = re.compile(r"^[A-Z][A-Z0-9_]+$")
CONDITIONAL = re.compile(r"\{\{(.*)\}\}")

# vars: are applied by set_var inside isotovideo, after openQA scheduled the job.
DOCUMENTED = ("DESKTOP", "HDD_1", "START_AFTER_TEST", "UEFI_PFLASH_VARS")
SCHEDULER = re.compile(
    r"^(?:START_AFTER_TEST|START_DIRECTLY_AFTER_TEST|PARALLEL_WITH|WORKER_CLASS|MACHINE"
    r"|ISO|ISO_\d+|HDD_\d+|UEFI_PFLASH_(?:CODE|VARS)|REPO_\d+|ASSET_\d+|KERNEL|INITRD"
    r"|(?:FORCE_)?PUBLISH_HDD_\d+|PUBLISH_PFLASH_VARS|STORE_HDD_\d+)$"
)
ERRORS = ("syntax", "schema", "module", "format")
WARNINGS = ("conditional", "placement", "convention")

_TOP = re.compile(r"^(?:\"([^\"]+)\"|'([^']+)'|([^\s#'\"-][^:#]*?))\s*:(?:\s|$)")
_CHILD = re.compile(r"^(\s+)(?:\"([^\"]+)\"|'([^']+)'|([^\s#'\"-][^:#]*?))\s*:(?:\s|$)")
_ITEM = re.compile(r"^\s*-\s+(.*?)\s*$")


class Doc:
    def __init__(self):
        self.flow = False
        self.top = []  # (key, line)
        self.name = None  # (value, line)
        self.modules = []  # (entry, line, section)
        self.refs = []  # (conditional name, line)
        self.conditions = set()
        self.vars = []  # (key, line)
        self.findings = []  # (line, class, message)

    def add(self, line, kind, message):
        self.findings.append((line, kind, message))

    def entry(self, value, line, section):
        conditional = CONDITIONAL.search(value)
        if conditional:
            self.refs.append((conditional.group(1), line))
        else:
            self.modules.append((value, line, section))


def show(value):
    text = " ".join(str(value).split())
    return f"'{text[:77]}...'" if len(text) > 80 else f"'{text}'"


def line_of(node):
    return node.start_mark.line + 1


def is_string(node):
    return isinstance(node, yaml.ScalarNode) and node.tag == "tag:yaml.org,2002:str"


class MergeBomb(Exception):
    pass


def pairs(node, depth=0, budget=None):
    """Key/value nodes of a mapping with plain-mapping merge keys expanded."""
    # Nested merge lists of aliases multiply: bound the work, not only the depth.
    budget = [MAX_PAIRS] if budget is None else budget
    for key, value in node.value:
        budget[0] -= 1
        if budget[0] < 0:
            raise MergeBomb
        if key.tag != "tag:yaml.org,2002:merge":
            yield key, value
            continue
        merged = value.value if isinstance(value, yaml.SequenceNode) else [value]
        for part in merged:
            if isinstance(part, yaml.MappingNode) and depth < 10:
                yield from pairs(part, depth + 1, budget)


def module_list(doc, node, section, what):
    if isinstance(node, yaml.ScalarNode) and node.tag == "tag:yaml.org,2002:null":
        return
    if not isinstance(node, yaml.SequenceNode):
        doc.add(line_of(node), "schema", f"{what} must be a list of module paths")
        return
    for item in node.value:
        if is_string(item):
            doc.entry(item.value, line_of(item), section)
        else:
            doc.add(line_of(item), "schema", f"{what}: entry is not a string")


def from_yaml(text, flow):
    doc = Doc()
    doc.flow = flow
    try:
        root = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        problem = getattr(error, "problem", None) or "invalid YAML"
        doc.add(mark.line + 1 if mark else 0, "syntax", problem)
        return doc
    if not isinstance(root, yaml.MappingNode):
        doc.add(1, "schema", "document is not a mapping")
        return doc
    for key, value in pairs(root):
        if flow:
            module_list(doc, value, "flow", f"flow step {show(key.value)}")
            continue
        doc.top.append((key.value, line_of(key)))
        if key.value == "name":
            if is_string(value):
                doc.name = (value.value, line_of(value))
            else:
                doc.add(line_of(value), "schema", "name must be a string")
        elif key.value == "schedule":
            if isinstance(value, yaml.MappingNode):
                for step, modules in pairs(value):
                    module_list(
                        doc, modules, "schedule", f"schedule step {show(step.value)}"
                    )
            else:
                module_list(doc, value, "schedule", "schedule")
        elif key.value == "vars":
            if not isinstance(value, yaml.MappingNode):
                doc.add(line_of(value), "schema", "vars must be a mapping")
                continue
            for var, setting in pairs(value):
                doc.vars.append((var.value, line_of(var)))
                if not isinstance(setting, yaml.ScalarNode):
                    doc.add(
                        line_of(var),
                        "schema",
                        f"vars {show(var.value)}: value must be a string or number",
                    )
        elif key.value == "conditional_schedule":
            conditional_schedule(doc, value)
    return doc


def conditional_schedule(doc, node):
    if not isinstance(node, yaml.MappingNode):
        doc.add(line_of(node), "schema", "conditional_schedule must be a mapping")
        return
    for name, condition in pairs(node):
        doc.conditions.add(name.value)
        if not COND_KEY.match(name.value):
            doc.add(
                line_of(name),
                "schema",
                f"conditional_schedule key {show(name.value)} must match [a-zA-Z0-9_]+",
            )
        if not isinstance(condition, yaml.MappingNode):
            doc.add(
                line_of(name),
                "schema",
                f"conditional_schedule {show(name.value)} must map a variable to values",
            )
            continue
        for var, branches in pairs(condition):
            if not COND_VAR.match(var.value):
                doc.add(
                    line_of(var),
                    "schema",
                    f"condition variable {show(var.value)} must match [A-Z][A-Z0-9_]+",
                )
            if not isinstance(branches, yaml.MappingNode):
                doc.add(
                    line_of(var),
                    "schema",
                    f"condition {show(var.value)} must map values to module lists",
                )
                continue
            for branch, modules in pairs(branches):
                where = f"{name.value}/{var.value}/{branch.value}"
                module_list(
                    doc, modules, "conditional_schedule", f"branch {show(where)}"
                )


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return re.sub(r"\s+#.*$", "", value)


def from_lines(text, flow):
    """Indentation-based extraction; knows nothing about anchors, merges or flow style."""
    doc = Doc()
    doc.flow = flow
    section = "flow" if flow else None
    condition_indent = None
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.lstrip().startswith("#") or line.startswith("---"):
            continue
        top = _TOP.match(line)
        if top and not flow:
            key = next(group for group in top.groups() if group is not None)
            section = key
            condition_indent = None
            if key != "<<":
                doc.top.append((key, number))
            if key == "name":
                doc.name = (unquote(line[top.end() :]), number)
            continue
        item = _ITEM.match(line)
        if item and section in ("flow", "schedule", "conditional_schedule"):
            doc.entry(unquote(item.group(1)), number, section)
            continue
        child = _CHILD.match(line)
        if not child:
            continue
        key = next(group for group in child.groups()[1:] if group is not None)
        indent = len(child.group(1))
        if section == "vars":
            doc.vars.append((key, number))
        elif section == "conditional_schedule":
            if condition_indent is None:
                condition_indent = indent
            if indent == condition_indent:
                doc.conditions.add(key)
    return doc


def check_format(doc, text):
    if not text:
        doc.add(1, "format", "file is empty")
    elif not text.endswith("\n"):
        doc.add(text.count("\n") + 1, "format", "no newline at end of file")
    elif text.endswith("\n\n") or not text.rstrip("\n").rsplit("\n", 1)[-1].strip():
        doc.add(text.rstrip().count("\n") + 2, "format", "trailing blank line")


def module_path(entry):
    """Mirror of loadtest(): tests/<entry>, with .pm added unless it ends in .pm or .py."""
    return "tests/" + (entry if re.search(r"\.p[my]$", entry) else entry + ".pm")


def new_in_git(repo, pathspecs):
    """Real paths git calls untracked or added; None when git cannot tell (no checkout, no git)."""
    # Repo-local config must not get to run anything: no fsmonitor hook, and no
    # "git status", which reads file content through the configured clean filters.
    # Nor a lazy fetch from a promisor remote, whose uploadpack is a command; the
    # empty GIT_ALLOW_PROTOCOL forbids every transport for a git without the first.
    quiet = {
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_ALLOW_PROTOCOL": "",
    }
    diff = ["diff", "--cached", "--relative", "--name-only", "-z", "--diff-filter=A"]
    new = set()
    for command in (
        ["ls-files", "-z", "--others", "--exclude-standard"],
        [*diff, "--no-ext-diff", "--no-textconv"],
    ):
        try:
            done = subprocess.run(
                ["git", "-C", repo, "-c", "core.fsmonitor=false", *command, "--"]
                + list(pathspecs),
                capture_output=True,
                check=True,
                timeout=60,
                env={**os.environ, **quiet},
            )
        except (OSError, subprocess.SubprocessError):
            return None
        names = os.fsdecode(done.stdout).split("\0")
        new.update(os.path.realpath(os.path.join(repo, name)) for name in names if name)
    return new


def check(doc, path, repo, name_rule=True):
    if not doc.flow and not any(kind == "syntax" for _, kind, _ in doc.findings):
        seen = set()
        for key, line in doc.top:
            if key in seen:
                doc.add(line, "schema", f"duplicate top-level key {show(key)}")
            elif key not in TOP_KEYS:
                allowed = ", ".join(TOP_KEYS)
                doc.add(
                    line,
                    "schema",
                    f"unknown top-level key {show(key)} (allowed: {allowed})",
                )
            seen.add(key)
        for key in REQUIRED:
            if key not in seen:
                doc.add(1, "schema", f"required key '{key}' is missing")
        base = os.path.splitext(os.path.basename(path))[0]
        if name_rule and doc.name and doc.name[0] not in (base, os.path.basename(path)):
            doc.add(
                doc.name[1],
                "convention",
                f"name {show(doc.name[0])} differs from the file basename '{base}'",
            )
    for key, line in doc.vars:
        if not VAR_KEY.match(key):
            doc.add(
                line, "schema", f"vars key {show(key)} must match [A-Z_+]+[A-Z0-9_]*"
            )
        plain = key.lstrip("+")
        if plain in DOCUMENTED:
            why = "declarative-schedule-doc.md forbids it there"
        elif SCHEDULER.match(plain):
            why = "openQA reads it before vars: are applied"
        else:
            continue
        doc.add(
            line,
            "placement",
            f"{plain} under vars: belongs in the job settings ({why})",
        )
    for name, line in doc.refs:
        if name not in doc.conditions:
            doc.add(
                line,
                "conditional",
                f"{{{{{name}}}}} has no entry in conditional_schedule; it schedules nothing",
            )
    for entry, line, _ in doc.modules:
        if entry.startswith("tests/"):
            doc.add(
                line,
                "module",
                f"{show(entry)} starts with tests/; entries are relative to tests/",
            )
            continue
        if entry.endswith(".pm"):
            doc.add(
                line, "convention", f"{show(entry)} ends in .pm; drop the extension"
            )
        if not os.path.isfile(os.path.join(repo, module_path(entry))):
            doc.add(line, "module", f"{module_path(entry)} does not exist")


def load(path, repo, use_yaml):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    flow = "flows/" in os.path.relpath(path, repo).replace(os.sep, "/")
    try:
        doc = from_yaml(text, flow) if use_yaml else from_lines(text, flow)
    except (MergeBomb, RecursionError):
        doc = Doc()
        doc.flow = flow
        doc.add(1, "syntax", "merge keys or nesting expand without bound")
    return doc, text


def schedules(repo):
    found = []
    for folder, dirs, names in os.walk(os.path.join(repo, "schedule")):
        dirs.sort()
        found += [
            os.path.join(folder, name)
            for name in sorted(names)
            if name.endswith(".yaml")
        ]
    return found


def readable(path, repo):
    """False for a device, a FIFO or a link that leads out of the checkout: a branch can carry those."""
    real, root = os.path.realpath(path), os.path.realpath(repo)
    inside = os.path.commonpath([real, root]) == root
    # A symlinked parent directory escapes just as well as a symlinked file, so
    # a name under the checkout has to resolve back into it; a name the caller
    # gave outside the checkout stays their own business unless it is a link.
    named = os.path.commonpath([os.path.abspath(path), root]) == root
    return os.path.isfile(real) and (inside or not (named or os.path.islink(path)))


# The name as typed, for a file outside the repository: abspath() folds "https://" into
# "https:/", out of redaction's reach.
TYPED = {}


def shown(path, repo):
    relative = os.path.relpath(path, repo)
    return TYPED.get(path, path) if relative.startswith("..") else relative


def find_module(wanted, repo, use_yaml):
    wanted = re.sub(r"^(?:\./)?(?:tests/)?", "", wanted)
    names = {wanted, re.sub(r"\.pm$", "", wanted), wanted + ".pm"}
    base = re.sub(r"\.pm$", "", wanted)
    state = (
        "present"
        if os.path.isfile(os.path.join(repo, module_path(base)))
        else "missing"
    )
    lines = [f"module: {base} ({module_path(base)} {state})"]
    hits = 0
    for path in schedules(repo):
        if not readable(path, repo):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            if base not in handle.read():
                continue
        doc, _ = load(path, repo, use_yaml)
        for entry, line, section in doc.modules:
            if entry in names:
                hits += 1
                lines.append(f"{shown(path, repo)}:{line}: {section}")
    lines.append(f"summary: {hits} reference(s)")
    return lines, 0 if hits else 1


def capped(lines, most, head):
    """Keep head leading lines, at most `most` findings and the summary line."""
    body = lines[head:-1]
    if len(body) <= most:
        return lines
    note = f"[... {len(body) - most} more not shown, raise --max-findings]"
    return [*lines[:head], *body[:most], note, lines[-1]]


def main(argv=None):
    parser = ArgumentParser(
        prog="check-schedule.py",
        description="Lint YAML schedules of an os-autoinst distri checkout: top-level keys, "
        "name, existence of every module under schedule and conditional_schedule "
        "(tests/<entry>.pm, or tests/<entry> when the entry ends in .pm or .py), settings "
        "that must not live under vars:, trailing blank line. Files below a flows/ directory "
        "only get the module and format checks. Classes syntax, schema, module and format are "
        "errors; conditional ({{key}} without a conditional_schedule entry), placement and "
        "convention are warnings. 'name differs from the file basename' is reported only for "
        "files git calls untracked or added (the upstream tree does not follow it), for every "
        "file with --all-conventions or when --repo is not a git checkout.",
        epilog="Output: one 'file:line: class: message' per finding, errors first, then a summary "
        "line ending in mode=yaml (PyYAML) or mode=fallback (line-based extractor). exit: 0 clean or warnings "
        "only, 1 errors (with --strict: any finding; with --module: no reference found), "
        "2 usage or file error",
    )
    parser.add_argument(
        "--repo", default=".", help="distri checkout (default: current directory)"
    )
    parser.add_argument(
        "--module",
        metavar="DIR/NAME",
        help="list every schedule under schedule/ that references this module instead",
    )
    parser.add_argument(
        "--strict", action="store_true", help="warnings also give exit 1"
    )
    parser.add_argument(
        "--fallback",
        action="store_true",
        help="use the line-based extractor even when PyYAML is importable",
    )
    parser.add_argument(
        "--errors-only", action="store_true", help="do not print warnings"
    )
    parser.add_argument(
        "--all-conventions",
        action="store_true",
        help="report 'name differs from the file basename' for files already in git too",
    )
    parser.add_argument(
        "--max-findings",
        type=int,
        default=40,
        metavar="N",
        help="print at most N findings or references, errors first (default: 40); "
        "the summary always counts all of them",
    )
    parser.add_argument(
        "files",
        nargs="*",
        metavar="file",
        help="schedule files, relative to the current directory or to --repo "
        "(default: every *.yaml below schedule/)",
    )
    args = parser.parse_args(argv)
    repo = os.path.abspath(args.repo)
    if not os.path.isdir(os.path.join(repo, "tests")):
        print(
            one_lines([f"check-schedule: no tests/ directory in {args.repo}"]),
            end="",
            file=sys.stderr,
        )
        return 2
    if args.module and args.files:
        parser.error("--module takes no files")

    use_yaml = bool(yaml) and not args.fallback
    mode = f"mode={'yaml' if use_yaml else 'fallback'}"
    lines = []
    try:
        if args.module:
            found, status = find_module(args.module, repo, use_yaml)
            found[-1] += f" {mode}"
            print(one_lines(capped(found, args.max_findings, 1)), end="")
            return status
        paths = []
        for name in args.files:
            candidates = (name, os.path.join(repo, name))
            path = next((c for c in candidates if os.path.isfile(c)), None)
            if path is None:
                print(
                    one_lines([f"check-schedule: no such file: {name}"]),
                    end="",
                    file=sys.stderr,
                )
                return 2
            paths.append(os.path.abspath(path))
            TYPED[paths[-1]] = name
        new = None if args.all_conventions else new_in_git(repo, paths or ["schedule"])
        paths = paths or schedules(repo)
        if not paths:
            print(
                one_lines([f"check-schedule: no schedule files in {args.repo}"]),
                end="",
                file=sys.stderr,
            )
            return 2
        counts = dict.fromkeys(ERRORS + WARNINGS, 0)
        for path in paths:
            if not readable(path, repo):
                counts["format"] += 1
                where = shown(path, repo)
                lines.append(
                    (
                        False,
                        f"{where}:1: format: not a regular file of the checkout, not read",
                    )
                )
                continue
            doc, text = load(path, repo, use_yaml)
            check_format(doc, text)
            check(doc, path, repo, new is None or os.path.realpath(path) in new)
            for line, kind, message in sorted(doc.findings):
                counts[kind] += 1
                if kind in ERRORS or not args.errors_only:
                    lines.append(
                        (
                            kind not in ERRORS,
                            f"{shown(path, repo)}:{line}: {kind}: {message}",
                        )
                    )
    except OSError as error:
        # str(OSError) quotes the file name with repr(), which hides a split credential
        where = shown(error.filename, repo) if error.filename else "check-schedule"
        print(
            one_lines([f"check-schedule: {where}: {error.strerror}"]),
            end="",
            file=sys.stderr,
        )
        return 2

    errors = sum(counts[kind] for kind in ERRORS)
    warnings = sum(counts[kind] for kind in WARNINGS)
    detail = " ".join(f"{kind}={count}" for kind, count in counts.items() if count)
    summary = (
        f"summary: {len(paths)} file(s), {errors} error(s), {warnings} warning(s)"
        + (f" [{detail}]" if detail else "")
        + f" {mode}"
    )
    # Errors first (the sort is stable, so file order is kept within each class).
    lines = [text for _, text in sorted(lines, key=lambda item: item[0])]
    print(one_lines(capped([*lines, summary], args.max_findings, 0)), end="")
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
