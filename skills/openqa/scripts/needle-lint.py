#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Lint needle JSON files the way os-autoinst needle.pm loads them and the needles-repo CI gates them.
"""Errors make os-autoinst drop the needle or the needles CI reject it; warnings are conventions."""

import json
import os
import re
import sys

from _sanitize import ArgumentParser, one_lines

TOP_KEYS = ("area", "tags", "properties")
AREA_TYPES = ("match", "ocr", "exclude")
GEOMETRY = ("xpos", "ypos", "width", "height")
AREA_KEYS = GEOMETRY + (
    "type",
    "match",
    "margin",
    "click_point",
    "max_offset",
    "processing_flags",
)
DATED = re.compile(r"-(\d{8})(?:_\d{1,2}|-\d{1,2})?$")
BUG_REF = re.compile(
    r"(?<![A-Za-z0-9])(?:(?:poo|bsc|bnc|boo|kde|gh|bgo|bko|fdo|lp)#?\d+|jsc#?[A-Z]+-\d+)"
    r"|https?://\S+",
)
# needle.pm recovers the reason of a bare "workaround" string from the file name only.
NAME_REF = re.compile(r"\S+-(?:bsc|poo|bnc|boo)\d+-\S+")


def show(value):
    text = " ".join(str(value).split())
    return f"'{text[:57]}...'" if len(text) > 60 else f"'{text}'"


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def reject_duplicates(pairs):
    keys = [key for key, _ in pairs]
    repeated = sorted({key for key in keys if keys.count(key) > 1})
    if repeated:
        raise ValueError(f"duplicate key {show(repeated[0])}")
    return dict(pairs)


def check_click_point(point, where, out):
    """needle.pm is_click_point_valid(): 'center', or a hash with true xpos and ypos."""
    if point == "center":
        return None
    if not isinstance(point, dict):
        out("error", f"{where}: click_point must be 'center' or {{xpos, ypos[, id]}}")
        return None
    for key in ("xpos", "ypos"):
        if not is_int(point.get(key)):
            out("error", f"{where}: click_point {key} missing or not an integer")
        elif point[key] <= 0:
            out(
                "error",
                f"{where}: click_point {key} {point[key]} is not above 0, needle.pm rejects it",
            )
    for key in sorted(set(point) - {"xpos", "ypos", "id"}):
        out("warning", f"{where}: unknown click_point key {show(key)}")
    if "id" in point and not isinstance(point["id"], str):
        out("error", f"{where}: click_point id must be a string")
    return point.get("id")


def check_areas(areas, out):
    if not isinstance(areas, list) or not areas:
        out("error", "area must be a non-empty list")
        return
    types = []
    points = []
    for index, area in enumerate(areas, 1):
        where = f"area {index}"
        if not isinstance(area, dict):
            out("error", f"{where}: not an object")
            continue
        for key in GEOMETRY:
            if key not in area:
                out("error", f"{where}: {key} is missing")
            elif not is_int(area[key]):
                out("error", f"{where}: {key} must be an integer")
            elif area[key] < 0 or (key in ("width", "height") and area[key] == 0):
                out("error", f"{where}: {key} {area[key]} is out of range")
        kind = area.get("type")
        if "type" not in area:
            out("warning", f"{where}: type is missing, needle.pm assumes 'match'")
            kind = "match"
        elif kind not in AREA_TYPES:
            out(
                "error",
                f"{where}: type {show(kind)} is not one of {', '.join(AREA_TYPES)}",
            )
        types.append(kind)
        if "match" in area:
            level = area["match"]
            if not is_number(level) or not 0 <= level <= 100:
                out("error", f"{where}: match must be a number within 0-100")
            elif level == 0:
                out(
                    "warning",
                    f"{where}: match 0 counts as unset, the default 96 applies",
                )
        if "margin" in area:
            if not is_int(area["margin"]) or area["margin"] < 0:
                out("error", f"{where}: margin must be a non-negative integer")
            elif area["margin"] == 0:
                out(
                    "warning",
                    f"{where}: margin 0 counts as unset, the default 50 applies",
                )
        if area.get("click_point"):
            points.append(check_click_point(area["click_point"], where, out))
        for key in sorted(set(area) - set(AREA_KEYS)):
            out("warning", f"{where}: unknown key {show(key)}")
    if "match" not in types:
        extra = " (an ocr-only needle loads but matches any screen)" * ("ocr" in types)
        out("error", f"no area of type match{extra}")
    if len(points) > 1 and None in points:
        out("error", "several click points need an id each, needle.pm drops the needle")


def check_tags(tags, out):
    if not isinstance(tags, list) or not tags:
        out("error", "tags must be a non-empty list")
        return
    for tag in tags:
        if not isinstance(tag, str) or not tag:
            out("error", f"tag {show(tag)} is not a non-empty string")
    strings = [tag for tag in tags if isinstance(tag, str)]
    for tag in sorted({tag for tag in strings if strings.count(tag) > 1}):
        out("error", f"duplicate tag {show(tag)}")


def check_properties(properties, name, out):
    if not isinstance(properties, list):
        out("error", "properties must be a list")
        return
    for item in properties:
        if isinstance(item, str):
            if item == "workaround" and not NAME_REF.search(name):
                out(
                    "error",
                    "bare 'workaround' property needs -<bsc|boo|bnc|poo><number>- in the "
                    "file name, else the soft-failure has no reason",
                )
            continue
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            out(
                "error",
                f"property {show(item)} is neither a string nor {{name, value}}",
            )
            continue
        if item["name"] != "workaround":
            continue
        value = item.get("value")
        if not isinstance(value, str) or not value.strip():
            out("error", "workaround property has no value")
        elif not BUG_REF.search(value) and not BUG_REF.search(name):
            out(
                "warning",
                "workaround without a bug reference (e.g. bsc#1234567) in its value or "
                "the file name",
            )


def lint(path):
    found = []

    def out(level, message):
        found.append((level, message))

    name = os.path.splitext(os.path.basename(path))[0]
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle, object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        out("error", f"invalid JSON: {error}")
        return found
    if not isinstance(data, dict):
        out("error", "top level is not an object")
        return found
    check_tags(data.get("tags"), out)
    check_areas(data.get("area"), out)
    if "properties" in data:
        check_properties(data["properties"], name, out)
    for key in sorted(set(data) - set(TOP_KEYS)):
        out("warning", f"unknown top-level key {show(key)}")
    png = os.path.splitext(path)[0] + ".png"
    if not os.path.isfile(png) or not os.path.getsize(png):
        out("error", f"{name}.png is missing or empty")
    dated = DATED.search(name)
    if not dated or dated.group(1) < "20130000":
        out("warning", "file name does not end in -YYYYMMDD")
    return found


def collect(targets):
    paths = []
    for target in targets:
        if os.path.isdir(target):
            for folder, dirs, names in os.walk(target):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                paths += [
                    os.path.join(folder, n)
                    for n in sorted(names)
                    if n.endswith(".json")
                ]
        elif os.path.isfile(target):
            paths.append(target)
        else:
            raise FileNotFoundError(f"no such file or directory: {target}")
    return paths


def main(argv=None):
    parser = ArgumentParser(
        prog="needle-lint.py",
        description="Lint needle JSON files: valid JSON, tags (non-empty, no duplicates), "
        "areas (integer xpos/ypos/width/height, type match|ocr|exclude, match 0-100, at least "
        "one match area), click_point form, same-basename PNG, workaround bug reference. "
        "Warnings: file name without -YYYYMMDD, unknown keys, values needle.pm treats as "
        "unset. Nothing is fetched; the PNG content is not inspected.",
        epilog="Output: one 'file: error|warning: message; message ...' line per file and level, a summary line. "
        "exit: 0 clean or warnings only, 1 errors (with --strict: any finding), "
        "2 usage or file error",
    )
    parser.add_argument(
        "--strict", action="store_true", help="warnings also give exit 1"
    )
    parser.add_argument(
        "--errors-only", action="store_true", help="do not print warnings"
    )
    parser.add_argument(
        "targets",
        nargs="+",
        metavar="path",
        help="needle .json file, or a directory searched recursively for *.json",
    )
    args = parser.parse_args(argv)
    try:
        paths = collect(args.targets)
    except OSError as error:
        print(one_lines([f"needle-lint: {error}"]), end="", file=sys.stderr)
        return 2
    if not paths:
        print("needle-lint: no .json files found", file=sys.stderr)
        return 2

    lines = []
    counts = {"error": 0, "warning": 0}
    for path in paths:
        try:
            found = lint(path)
        except OSError as error:
            print(
                one_lines([f"needle-lint: {path}: {error.strerror}"]),
                end="",
                file=sys.stderr,
            )
            return 2
        for wanted in ("error", "warning"):
            messages = [message for level, message in found if level == wanted]
            counts[wanted] += len(messages)
            if messages and (wanted == "error" or not args.errors_only):
                lines.append(f"{path}: {wanted}: {'; '.join(messages)}")
    summary = (
        f"summary: {len(paths)} needle(s), {counts['error']} error(s), "
        f"{counts['warning']} warning(s)"
    )
    print(one_lines(lines, max_line=600) + summary)
    return 1 if counts["error"] or (args.strict and counts["warning"]) else 0


if __name__ == "__main__":
    sys.exit(main())
