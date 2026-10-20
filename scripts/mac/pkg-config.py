#!/usr/bin/env python3
"""A minimal pkg-config, enough for ffmpeg's configure to find the static libraries
that scripts/mac/build-ffmpeg.sh installs. It reads .pc files from PKG_CONFIG_PATH."""

import os
import re
import sys

OPERATORS = ("<", "<=", "=", "!=", ">=", ">")


def search_path():
    return [entry for entry in os.environ.get("PKG_CONFIG_PATH", "").split(":") if entry]


def expand(value, variables):
    for _ in range(8):
        replaced = re.sub(r"\$\{([^}]+)\}", lambda m: variables.get(m.group(1), ""), value)
        if replaced == value:
            break
        value = replaced
    return value


def parse(path):
    variables = {"pcfiledir": os.path.dirname(path)}
    fields = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            assignment = re.match(r"^([A-Za-z0-9_.]+)\s*=\s*(.*)$", line)
            if assignment:
                variables[assignment.group(1)] = expand(assignment.group(2), variables)
                continue
            field = re.match(r"^([A-Za-z0-9_.]+)\s*:\s*(.*)$", line)
            if field:
                fields[field.group(1).lower()] = expand(field.group(2), variables)
    return fields


def load(name):
    for directory in search_path():
        candidate = os.path.join(directory, name + ".pc")
        if os.path.isfile(candidate):
            return parse(candidate)
    return None


def split_requirements(tokens):
    tokens = " ".join(tokens).replace(",", " ").split()
    wanted = []
    index = 0
    while index < len(tokens):
        name = tokens[index]
        if index + 1 < len(tokens) and tokens[index + 1] in OPERATORS:
            version = tokens[index + 2] if index + 2 < len(tokens) else ""
            wanted.append((name, tokens[index + 1], version))
            index += 3
        else:
            wanted.append((name, None, None))
            index += 1
    return wanted


def version_key(text):
    return [int(part) if part.isdigit() else part for part in re.split(r"[.\-+]", text) if part]


def satisfies(have, operator, want):
    if operator is None:
        return True
    left, right = version_key(have), version_key(want)
    return {
        "<": left < right, "<=": left <= right, "=": left == right,
        "!=": left != right, ">=": left >= right, ">": left > right,
    }[operator]


def collect(name, static, seen, order):
    if name in seen:
        return
    seen.add(name)
    fields = load(name)
    if fields is None:
        raise LookupError(name)
    order.append(fields)
    requirements = fields.get("requires", "")
    if static:
        requirements += " " + fields.get("requires.private", "")
    for child, _, _ in split_requirements([requirements]):
        collect(child, static, seen, order)


def unique(flags):
    kept = []
    for flag in flags:
        if flag not in kept:
            kept.append(flag)
    return kept


def main(arguments):
    options = {argument for argument in arguments if argument.startswith("--")}
    positional = [argument for argument in arguments if not argument.startswith("--")]
    static = "--static" in options

    if "--version" in options:
        print("0.29.2")
        return 0

    atleast = next((o.split("=", 1)[1] for o in options if o.startswith("--atleast-version=")), None)
    wanted = split_requirements(positional)
    if atleast is not None:
        wanted = [(name, ">=", atleast) for name, _, _ in wanted]

    fields = []
    for name, operator, version in wanted:
        package = load(name)
        if package is None or not satisfies(package.get("version", "0"), operator, version):
            if "--print-errors" in options:
                sys.stderr.write("Package %s was not found\n" % name)
            return 1
        fields.append(package)

    if "--modversion" in options:
        for package in fields:
            print(package.get("version", ""))
        return 0

    output = []
    if "--cflags" in options or "--libs" in options:
        try:
            order = []
            seen = set()
            for name, _, _ in wanted:
                collect(name, static, seen, order)
        except LookupError as missing:
            sys.stderr.write("Package %s was not found\n" % missing)
            return 1
        if "--cflags" in options:
            output += unique(" ".join(package.get("cflags", "") for package in order).split())
        if "--libs" in options:
            libs = []
            for package in order:
                libs += package.get("libs", "").split()
                if static:
                    libs += package.get("libs.private", "").split()
            output += unique(libs)
    if output:
        print(" ".join(output))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
