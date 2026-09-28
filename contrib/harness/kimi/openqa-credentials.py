#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Kimi Code PreToolUse hook: refuse tool calls that read credential files or print secrets.
"""Exit 2 blocks the call and its stderr becomes the tool result; exit 0 lets it run.

Any error inside the hook blocks too (fail closed). It matches text, so a path built at run time,
a variable or a script written first and run later still gets past it.
"""

import json
import os
import re
import sys

HOME = os.path.expanduser("~")
# Larger input could outrun the hook's timeout, and Kimi runs the call when it does.
MAX_INPUT = 1 << 20
MAX_COMMAND = 1 << 16
MAX_BRACE_TEXT = 1 << 20
MAX_SEQUENCE = 4096
SEQUENCE_RE = re.compile(r"(-?\d+|[A-Za-z])\.\.(-?\d+|[A-Za-z])(?:\.\.(-?\d+))?")
PATH_MAX = 4096

PATHS = [
    r"\.config/openqa\b",
    r"(?<![\w.-])/(?:usr/)?etc/openqa\b",
    r"\.config/gh(?![\w.-])",
    r"gh/hosts\.yml",
    r"\.config/osc\b",
    r"\.oscrc\b",
    r"\.config/tea\b",
    r"\.netrc\b",
    r"\.git-credentials\b",
    r"\.local/state/osc/cookiejar\b",
    r"(?:^|[\s/\"'=:<>(|;&])\.env(?:\.(?!example\b)[\w.-]+)?(?=$|[\s\"'/;|&)<>,*?\[])",
]
# Each rule holds when all its parts occur in one simple command. Parts are searched
# separately, which keeps the scan linear in the command's length.
COMMANDS = [
    (r"\bgh\s+auth\s+(?:token|status|git-credential)\b",),
    (r"(?:(?<!\S)(?-i:-[a-zA-Z]*H)|--header)[\s=]*(?:['\"]\s*)?authorization\s*:",),
    (r"\bopenqa-cli\b", r"authorization\s*:"),
    (r"--api(?:key|secret)\b",),
    (r"://[^\s/:@]+:[^\s/@]+@",),
    (r"MOJO_CLIENT_DEBUG",),
    # tools that print their own secrets
    (r"\bgit[\s-]obs\b", r"\blogin\s+list\b"),
    (r"gitcredentials-helper",),
    (r"\blogins?\s+(?:helper|git-credential)\b",),
    (r"\btea\b", r"\blogins?\s+(?:edit|e)\b"),
    (r"\bosc\b", r"--dump-"),
    (r"--http-[df]|http[-_](?:full[-_])?debug",),
    (r"\bosc\b", r"(?:^|\s)(?-i:-[a-zA-Z]*H[a-zA-Z]*)\b"),
    (r"\bcredential\s+fill\b",),
    (r"\bgit[\s-]credential-", r"(?:^|\s)get\b"),
    (r"\bsecret-tool\s+(?:lookup|search)\b",),
]
# A recursive search rooted at one of these, or at an ancestor of one, would read them.
SECRET_ROOTS = [
    f"{HOME}/.config/openqa",
    "/etc/openqa",
    "/usr/etc/openqa",
    f"{HOME}/.config/gh",
    f"{HOME}/.config/osc",
    f"{HOME}/.oscrc",
    f"{HOME}/.config/tea",
    f"{HOME}/.netrc",
    f"{HOME}/.git-credentials",
    f"{HOME}/.local/state/osc/cookiejar",
]
PATH_RE = re.compile("|".join(PATHS), re.IGNORECASE)
RULES = [[re.compile(p, re.IGNORECASE) for p in parts] for parts in COMMANDS]
WORD_RE = re.compile(r"[\s\"'`=<>|;&()]+")
UP_RE = re.compile(r"(?:\.\.(?:/|$))*")
MCP_KEY_RE = re.compile(r"path|file|dir|root|scope|glob|url|command|cmd", re.IGNORECASE)
MCP_ROOT_RE = re.compile(r"path|dir|root|scope", re.IGNORECASE)
OSC_ARG_OPTIONS = {"-A", "--apiurl", "-c", "--config"}
# osc takes any unambiguous prefix of a long option.
OSC_LONG_ARG_OPTIONS = ("--apiurl", "--config", "--setopt")
OSC_WORD_RE = re.compile(r"[\s`$(){}]+")
OSC_TOKEN_API = re.compile(r"/person/[^/]+/token")


def block(why):
    sys.stderr.write(f"Denied by openqa-credentials hook: {why}\n")
    sys.exit(2)


def segments(text):
    """Split at ; & | and newlines outside quotes, in one pass."""
    out, start, quote, i = [], 0, "", 0
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        elif c in "\n;&|":
            out.append(text[start:i])
            start = i + 1
        i += 1
    out.append(text[start:])
    return out


def osc_prints_secret(segment):
    """An osc call whose subcommand, past the global options, lists tokens or prints a password."""
    # Command substitution and subshells start a call of their own, so split at them too.
    words = [word.strip("'\"") for word in OSC_WORD_RE.split(segment) if word]
    names = [word.rsplit("/", 1)[-1] for word in words]
    starts = [i for i, name in enumerate(names) if name == "osc"]
    for start, end in zip(starts, starts[1:] + [len(words)]):
        rest = iter(words[start + 1 : end])
        for word in rest:
            if word in OSC_ARG_OPTIONS or (
                len(word) > 3 and any(o.startswith(word) for o in OSC_LONG_ARG_OPTIONS)
            ):
                next(rest, None)
            elif not word.startswith("-"):
                args = list(rest)
                if (
                    word == "token"
                    or word == "config"
                    and bool({"pass", "passx"} & set(args))
                    or word == "api"
                    and any(OSC_TOKEN_API.search(arg) for arg in args)
                ):
                    return True
                break
    return False


def _alternatives(body):
    """A brace group's comma-separated parts, split outside quotes, quotes removed."""
    parts, start, quote, i = [], 0, "", 0
    while i < len(body):
        c = body[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        elif c == ",":
            parts.append(body[start:i])
            start = i + 1
        i += 1
    parts.append(body[start:])
    return [
        re.sub(r"\\(.)", r"\1", part).replace('"', "").replace("'", "")
        for part in parts
    ]


def _sequence(body):
    """The items of a {x..y[..step]} sequence of letters or integers, None for anything else."""
    match = SEQUENCE_RE.fullmatch(body)
    if not match:
        return None
    first, last, step = (
        match.group(1),
        match.group(2),
        abs(int(match.group(3) or 1)) or 1,
    )
    if first.lstrip("-").isdigit() and last.lstrip("-").isdigit():
        low, high = int(first), int(last)
        items = (
            range(low, high + 1, step) if low <= high else range(low, high - 1, -step)
        )
        # Digits alone never spell a credential path, so a long range is checked in part.
        return [str(item) for item in items[:MAX_SEQUENCE]]
    if first.isalpha() and last.isalpha():
        low, high = ord(first), ord(last)
        items = (
            range(low, high + 1, step) if low <= high else range(low, high - 1, -step)
        )
        return [chr(item) for item in items]
    return None


def _brace_group(text):
    """(start, end, parts) of the first innermost brace group that expands, or None.

    Braces count inside quotes too: a stray quote in a comment or heredoc must not hide a
    group, and a group found in error only adds text to check. A group never spans words."""
    stack, quote, i = [], "", 0  # [start, has comma], or None for a ${...}
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if c in "'\"":
            if not quote:
                quote = c
            elif c == quote:
                quote = ""
        elif c == "{":
            stack.append(None if text[i - 1 : i] == "$" else [i, False])
        elif c == "}" and stack:
            top = stack.pop()
            parts = _alternatives(text[top[0] + 1 : i]) if top and top[1] else None
            if parts and len(parts) > 1:
                return top[0], i + 1, parts
            if top and i - top[0] <= 64 and ".." in text[top[0] : i]:
                parts = _sequence(text[top[0] + 1 : i])
                if parts:
                    return top[0], i + 1, parts
        elif c == "," and stack and stack[-1]:
            stack[-1][1] = True
        elif not quote and (c.isspace() or c in ";&|<>()"):
            stack.clear()
        i += 1
    return None


def brace_variants(text):
    """The text itself and its brace expansions, None when they outgrow MAX_BRACE_TEXT.

    The unexpanded text is always among them, so expanding can only add refusals."""
    done, todo, size = [text], [text], len(text)
    while todo:
        current = todo.pop()
        group = _brace_group(current)
        if not group:
            if current is not text:
                done.append(current)
            continue
        start, end, parts = group
        # Budget before building: one group can hold thousands of parts.
        size += len(parts) * (len(current) - (end - start)) + sum(map(len, parts))
        if size > MAX_BRACE_TEXT:
            return None
        todo += [current[:start] + part + current[end:] for part in parts]
    return done


def refused(text):
    if len(text) > MAX_COMMAND:
        return f"is over {MAX_COMMAND} characters, too long to check"
    # The shell drops a backslash-newline, even inside a word.
    text = text.replace("\\\n", "")
    texts = brace_variants(text)
    if texts is None:
        return (
            f"expands its braces beyond {MAX_BRACE_TEXT} characters, too many to check"
        )
    for variant in texts:
        why = _refused(variant)
        if why:
            return why
    return None


def _refused(text):
    if PATH_RE.search(text):
        return "names a credential file"
    # A rule can hold in a segment only when all its parts occur in the whole text.
    rules = [parts for parts in RULES if all(rx.search(text) for rx in parts)]
    osc = "osc" in text
    for segment in segments(text) if rules or osc else ():
        if any(all(rx.search(segment) for rx in parts) for parts in rules) or (
            osc and osc_prints_secret(segment)
        ):
            return "prints a secret"
    return None


def variants(path, cwds):
    out = {path}
    for cwd in cwds:
        joined = os.path.join(cwd, os.path.expanduser(path))
        out |= {joined, os.path.normpath(joined), os.path.realpath(joined)}
    return out


def check_path(path, cwds, recursive=False):
    if len(path) > PATH_MAX:
        block(f"a path over {PATH_MAX} characters")
    for variant in variants(path, cwds):
        if PATH_RE.search(variant):
            block(f"{path!r} is a credential file")
        if recursive and any(
            root == variant or root.startswith(variant.rstrip("/") + "/")
            for root in SECRET_ROOTS
        ):
            block(f"a recursive search of {path!r} would read credential files")


def check_words(command, cwd):
    """Resolve each word of a Bash command against the cwd the call sets."""
    base = os.path.normpath(cwd).rstrip("/")
    for word in set(WORD_RE.split(command)):
        word = os.path.normpath(word)
        up = UP_RE.match(word).group()
        rest = word[len(up) :]
        path = os.path.join(base.rsplit("/", up.count(".."))[0] + "/", rest)
        # base itself passed check_path, so only a match near the join is new.
        if PATH_RE.search(path, max(0, len(path) - len(rest) - 64)):
            block(f"{word!r} is a credential file in the call's cwd")


def mcp_strings(obj, key=""):
    if isinstance(obj, dict):
        for name, value in obj.items():
            yield from mcp_strings(value, name)
    elif isinstance(obj, list):
        for value in obj:
            yield from mcp_strings(value, key)
    elif isinstance(obj, str) and MCP_KEY_RE.search(key):
        yield key, obj


def session_dirs(session):
    # A line cut short by a concurrent write is skipped, not fatal.
    dirs = set()
    index = os.path.join(
        os.environ.get("KIMI_CODE_HOME") or f"{HOME}/.kimi-code", "session_index.jsonl"
    )
    try:
        with open(index, encoding="utf-8") as handle:
            for line in handle:
                if session in line:
                    try:
                        dirs.add(json.loads(line).get("workDir"))
                    except ValueError:
                        pass
    except OSError:
        pass
    dirs.discard(None)
    return dirs


def main():
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        block(f"a tool call over {MAX_INPUT} bytes")
    event = json.loads(raw)
    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    # event["cwd"] is Kimi's process directory; an ACP or web session has its own workDir.
    cwds = {event.get("cwd") or os.getcwd()} | session_dirs(
        event.get("session_id") or "\0"
    )
    if tool == "Bash":
        command = args.get("command", "").replace("\\\n", "")
        why = refused(command)
        if why:
            block(f"the command {why}")
        # Without its own cwd the command runs in the session's directory.
        workdir = args.get("cwd") or "."
        check_path(workdir, cwds)
        # refused() already rejected an expansion too large to check.
        for variant in brace_variants(command):
            for cwd in cwds:
                check_words(variant, os.path.join(cwd, os.path.expanduser(workdir)))
    elif tool in ("Read", "ReadMediaFile", "Write", "Edit"):
        check_path(args.get("path", ""), cwds)
    elif tool == "Grep":
        for root in [args["path"]] if args.get("path") else sorted(cwds):
            check_path(root, cwds, recursive=True)
            if args.get("glob"):
                check_path(os.path.join(root, args["glob"]), cwds)
    elif tool == "Glob":
        check_path(os.path.join(args.get("path") or ".", args.get("pattern", "")), cwds)
    elif tool == "FetchURL":
        if PATH_RE.search(args.get("url", "")):
            block("the URL names a credential file")
    elif tool.startswith("mcp__"):
        for key, text in mcp_strings(args):
            why = refused(text)
            if why:
                block(f"an MCP argument {why}")
            # A search rooted at an ancestor of a credential file would read it.
            if MCP_ROOT_RE.search(key):
                check_path(text, cwds, recursive=True)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - any failure must block, not let the call run
        block(f"the hook failed ({type(error).__name__}); failing closed")
    sys.exit(0)
