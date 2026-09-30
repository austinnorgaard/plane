# SPDX-License-Identifier: AGPL-3.0-only
"""Inventory every call site that enqueues the issue_activity celery task.

Usage:
    python3 fork/tools/callsites.py [--root <repo root>]
    python3 fork/tools/callsites.py --check <snapshot> [--ignore-lines] [--root <repo root>]

Output is one line per call site, sorted, path-relative and deterministic:
    <path>:<line> | type=<expr> | issue_id=<expr> | requested_data=<expr> | current_instance=<expr>

Header lines in a snapshot start with '#' and are ignored by --check.
"""

import argparse
import ast
import difflib
import os
import sys

TASK = "issue_activity"
WIDTH = 80
SKIP_DIRS = {"tests", "test", "__pycache__", "migrations"}
FIELDS = ("type", "issue_id", "requested_data", "current_instance")
# Positional order of the task signature.
POSITIONAL = ("type", "requested_data", "current_instance", "issue_id")


def shorten(text, width=WIDTH):
    text = " ".join(text.split())
    if len(text) > width:
        text = text[: width - 3] + "..."
    return text


def unparse(node):
    return "<missing>" if node is None else shorten(ast.unparse(node))


def find_aliases(tree):
    """Names under which issue_activity is bound in this module."""
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for a in node.names:
                if a.name == TASK:
                    names.add(a.asname or a.name)
        elif isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split(".")[-1] == TASK and a.asname:
                    names.add(a.asname)
    return names


def is_task_ref(node, names):
    if isinstance(node, ast.Name):
        return node.id in names
    if isinstance(node, ast.Attribute):
        return node.attr == TASK
    return False


def call_args(call, is_delay):
    """Map task parameter names to AST nodes."""
    args = list(call.args)
    kwargs = {k.arg: k.value for k in call.keywords if k.arg}
    if not is_delay and "kwargs" in kwargs and isinstance(kwargs["kwargs"], ast.Dict):
        # apply_async(kwargs={...}) and apply_async(args=[...])
        inner = {}
        for k, v in zip(kwargs["kwargs"].keys, kwargs["kwargs"].values):
            if isinstance(k, ast.Constant):
                inner[k.value] = v
        kwargs = inner
    elif not is_delay:
        av = {k.arg: k.value for k in call.keywords if k.arg == "args"}.get("args")
        if av is None and args:
            av = args[0]
        args = list(av.elts) if isinstance(av, (ast.List, ast.Tuple)) else []
        kwargs = {}
    out = dict(zip(POSITIONAL, args))
    out.update({k: v for k, v in kwargs.items() if k in POSITIONAL})
    return out


def scan_source(source, relpath):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []
    names = find_aliases(tree) | {TASK}
    rows = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        is_delay = is_apply = False
        if isinstance(f, ast.Attribute) and f.attr in ("delay", "apply_async") and is_task_ref(f.value, names):
            is_delay, is_apply = f.attr == "delay", f.attr == "apply_async"
        elif is_task_ref(f, names):
            is_delay = True  # direct call, same argument shape as delay
        else:
            continue
        a = call_args(node, is_delay)
        row = f"{relpath}:{node.lineno} | " + " | ".join(
            f"{k}={unparse(a.get(k))}" for k in ("type", "issue_id", "requested_data", "current_instance")
        )
        rows.append((relpath, node.lineno, node.col_offset, row))
    return rows


def scan(root):
    base = os.path.join(root, "apps", "api", "plane")
    rows = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if not fn.endswith(".py") or fn.startswith("test_") or fn == "conftest.py":
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, encoding="utf-8") as fh:
                rows.extend(scan_source(fh.read(), rel))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    return [r[3] for r in rows]


def read_snapshot(path):
    with open(path, encoding="utf-8") as fh:
        return [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]


def strip_line(row):
    head, sep, rest = row.partition(" | ")
    path = head.rsplit(":", 1)[0]
    return path + sep + rest


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--root", default=".", help="repository root (default: cwd)")
    p.add_argument("--check", metavar="SNAPSHOT", help="exit 1 with a diff if the tree differs")
    p.add_argument(
        "--ignore-lines",
        action="store_true",
        help="with --check, compare without line numbers (tolerates line shifts in patched files)",
    )
    p.add_argument("--header", metavar="TEXT", help="emit a '# TEXT' first line")
    ns = p.parse_args(argv)
    rows = scan(ns.root)
    if ns.check:
        want = read_snapshot(ns.check)
        if ns.ignore_lines:
            want, rows = [strip_line(r) for r in want], [strip_line(r) for r in rows]
        if want == rows:
            print(f"OK: {len(rows)} call sites match {ns.check}")
            return 0
        sys.stdout.writelines(
            ln + "\n"
            for ln in difflib.unified_diff(want, rows, "snapshot", "current", lineterm="", n=0)
        )
        print(f"DIFF: snapshot has {len(want)} call sites, tree has {len(rows)}")
        return 1
    if ns.header:
        print("# " + ns.header)
    print("\n".join(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
