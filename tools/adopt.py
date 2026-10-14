#!/usr/bin/env python3
"""Text helpers for `bin/ci-runner adopt`, which downloads a repository's
workflow files and needs three things from them: the verify-routing guard
steps, cache keys that lack the architecture, and the guard step to suggest.
Stdlib only, and no YAML parser: the workflow text is read line by line, which
is enough for the shapes GitHub workflows take and fails safe (a guard it
cannot read counts as no guard, so adopt does not switch the repository on).

  adopt.py guards DIR       one line per verify-routing step:
                            file:line <TAB> label <TAB> expected entries (spaces)
  adopt.py cache-keys DIR   one line per cache key that has runner.os and not
                            runner.arch: file:line: text
  adopt.py guard-snippet [--label L] [--jobs a.yml:x,b.yml:y]
                            the guard step to add to a workflow
  adopt.py quote TEXT       TEXT percent-encoded for a URL path
"""
import argparse
import os
import re
import sys
import urllib.parse

# Keep in step with the version docs/adopting.md and the README tell consumers
# to pin; tests/adopt.sh checks that the docs still say it.
ACTION = "i2Dev-com/ci-runner/verify-routing@v2"
DEFAULT_LABEL = "local-ci"

USES = re.compile(r"^(\s*)(-\s+)?uses:\s*['\"]?\S*/verify-routing@")
KEY = re.compile(r"^(\s*)(-\s+)?([A-Za-z0-9_-]+):\s*(.*?)\s*$")
CACHE_KEY = re.compile(r"^(\s*)(?:-\s+)?(key|restore-keys):\s*(.*?)\s*$")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [line.rstrip("\r\n") for line in fh]


def workflow_files(directory):
    return sorted(n for n in os.listdir(directory) if n.endswith((".yml", ".yaml")))


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    s = line.strip()
    return not s or s.startswith("#")


def in_block(line, base):
    """Whether a line belongs to a block scalar whose key is indented `base`:
    blank, or indented deeper. A comment at the key's own depth or less ends
    it (a deeper one is text, as YAML reads it)."""
    return not line.strip() or indent_of(line) > base


def scalar(value):
    """A single-line YAML scalar: no trailing comment, no quotes."""
    value = re.sub(r"\s+#.*$", "", value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value


def step_bounds(lines, at):
    """The first and one-past-last line of the step that has its `uses:` on
    line index `at`. A step is a list item; its keys sit two columns right of
    the dash (or on the dash line itself)."""
    m = USES.match(lines[at])
    if m.group(2):
        start, dash = at, len(m.group(1))
    else:
        # `uses:` is a later key of the step: walk up to its `- ` line.
        key_indent = len(m.group(1))
        start = at
        while start > 0:
            line = lines[start]
            if not is_blank(line) and indent_of(line) < key_indent:
                break
            start -= 1
        dash = indent_of(lines[start])
        if not lines[start].lstrip().startswith("-"):
            return at, at + 1
    end = start + 1
    while end < len(lines):
        if not is_blank(lines[end]) and indent_of(lines[end]) <= dash:
            break
        end += 1
    return start, end


def with_values(lines, start, end):
    """The keys of the step's `with:` block, as {key: text}. A block scalar
    (`|`, `>`, with or without - and +) keeps its lines, newline-joined."""
    key_indent = None
    for i in range(start, end):
        m = KEY.match(lines[i])
        if m and m.group(3) == "uses":
            key_indent = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
            break
    if key_indent is None:
        return {}
    values = {}
    i = start
    while i < end:
        m = KEY.match(lines[i])
        here = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0) if m else -1
        if m and m.group(3) == "with" and here == key_indent and not m.group(4):
            child = None
            i += 1
            while i < end:
                line = lines[i]
                if is_blank(line):
                    i += 1
                    continue
                if indent_of(line) <= key_indent:
                    break
                if child is None:
                    child = indent_of(line)
                km = KEY.match(line)
                if km and indent_of(line) == child:
                    name, rest = km.group(3), km.group(4)
                    if re.match(r"^[|>][+-]?\d*\s*(#.*)?$", rest):
                        block = []
                        i += 1
                        while i < end and in_block(lines[i], child):
                            block.append(lines[i].strip())
                            i += 1
                        values[name] = "\n".join(block)
                        continue
                    values[name] = scalar(rest)
                i += 1
            continue
        i += 1
    return values


def guards(directory):
    """(file:line, label, expected entries) for every verify-routing step."""
    found = []
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        for at, line in enumerate(lines):
            if line.lstrip().startswith("#") or not USES.match(line):
                continue
            start, end = step_bounds(lines, at)
            values = with_values(lines, start, end)
            expected = [e for e in re.split(r"[\s,]+", values.get("expected", "")) if e]
            found.append((f"{name}:{at + 1}", values.get("label") or DEFAULT_LABEL, expected))
    return found


def cache_keys(directory):
    """Cache `key:` and `restore-keys:` text with runner.os and no runner.arch.
    A text heuristic: it does not know which action the key belongs to, only
    that a key built from the OS alone is shared between the hosted x86-64
    runners and the arm64 VM. Block scalars (restore-keys: |) are followed."""
    hits = []
    for name in workflow_files(directory):
        lines = read_lines(os.path.join(directory, name))
        i = 0
        while i < len(lines):
            m = CACHE_KEY.match(lines[i]) if not lines[i].lstrip().startswith("#") else None
            if not m:
                i += 1
                continue
            base, rest = len(m.group(1)), m.group(3)
            checked = [(i, rest)]
            if re.match(r"^([|>][+-]?\d*)?\s*(#.*)?$", rest):
                j = i + 1
                while j < len(lines) and in_block(lines[j], base):
                    if lines[j].strip():
                        checked.append((j, lines[j].strip()))
                    j += 1
                i = j - 1
            for at, text in checked:
                text = re.sub(r"\s+#.*$", "", text)
                if "runner.os" in text and "runner.arch" not in text:
                    hits.append(f"{name}:{at + 1}: {text}")
            i += 1
    return hits


def guard_snippet(label, jobs):
    entries = jobs or ["ci.yml:<job-id>"]
    out = [
        "      - name: Verify local-runner routing",
        f"        uses: {ACTION}",
        "        with:",
        "          expected: |",
    ]
    out += [f"            {e}" for e in entries]
    if label != DEFAULT_LABEL:
        out.append(f"          label: {label}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("guards").add_argument("dir")
    sub.add_parser("cache-keys").add_argument("dir")
    p = sub.add_parser("guard-snippet")
    p.add_argument("--label", default=DEFAULT_LABEL)
    p.add_argument("--jobs", default="")
    sub.add_parser("quote").add_argument("text")
    args = ap.parse_args()

    if args.cmd == "guards":
        for where, label, expected in guards(args.dir):
            print(f"{where}\t{label}\t{' '.join(expected)}")
    elif args.cmd == "cache-keys":
        for hit in cache_keys(args.dir):
            print(hit)
    elif args.cmd == "guard-snippet":
        print(guard_snippet(args.label, [j for j in re.split(r"[\s,]+", args.jobs) if j]))
    else:
        print(urllib.parse.quote(args.text, safe=""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
