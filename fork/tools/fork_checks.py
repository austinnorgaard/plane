# SPDX-License-Identifier: AGPL-3.0-only
"""Fork consistency checks (PLN-118). Read-only; stdlib only.

Usage:
    python3 fork/tools/fork_checks.py [patches|parity|all|list] [--base <upstream ref>] [--head <ref>] [--root <repo root>]

patches  Every upstream file the fork modifies or deletes (git diff --diff-filter=MDR <base> <head>, files that
         exist in <base>) must be listed in the upstream part of fork/PATCHES.md (the backticked paths above
         "## New files"). Listed files that the fork no longer changes are reported as notes, not failures.
parity   Every live metadata event (kind, verb) that an app view publishes (publish_metadata_event in
         apps/api/plane/app/views) must also be published by a REST v1 view (apps/api/plane/api/views): the
         PLN-111 class of bug, where a change made through /api/v1 never reached open browsers. Exceptions are
         listed in fork/tools/publish-parity.allow ("<kind> <verb>  # reason"). Work-item events are not
         compared: REST v1 work-item changes publish through the issue_activity task (fork/tools/CALLSITES.md);
         direct publish_work_item_event calls in app views are printed as notes.

list     Print the upstream paths PATCHES.md lists (the parser rebase-check.sh uses).

Run by rebase-check.sh (section 4) and in CI (.github/workflows/fork-checks.yml) on pull requests.

Exit status: 0 clean, 1 findings, 2 usage or setup error. --base defaults to v1.4.3 (the tag must exist locally:
git fetch upstream tag v1.4.3 --no-tags).
"""

import argparse
import ast
import os
import re
import subprocess
import sys

DEFAULT_BASE = "v1.4.3"
APP_VIEWS = "apps/api/plane/app/views"
API_VIEWS = "apps/api/plane/api/views"
ALLOW_FILE = "fork/tools/publish-parity.allow"


def git(root, *args):
    result = subprocess.run(
        ["git", "-C", root, *args],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


# ------------------------------------------------------------------ patches


def _expand(token):
    match = re.search(r"\{([^{}]*)\}", token)
    if not match:
        return [token]
    out = []
    for part in match.group(1).split(","):
        out.extend(_expand(token[: match.start()] + part + token[match.end() :]))
    return out


def _common_prefix_len(a, b):
    n = 0
    for x, y in zip(a.split("/"), b.split("/")):
        if x != y:
            break
        n += 1
    return n


def listed_upstream_paths(patches_text, known_files):
    """Backticked repo paths in the upstream part of PATCHES.md (rebase-check.sh uses this too).

    `{a,b}` brace lists are expanded. A `.../tail` path is resolved by suffix against `known_files`; when the
    suffix matches several files, the one sharing the longest leading directories with the previous full path
    of the same line wins (`kanban/x.tsx`, `.../list/y.tsx` means the sibling list folder)."""
    text = re.split(r"\n(?:## )?New files", patches_text, maxsplit=1)[0]
    paths = set()
    for line in text.splitlines():
        previous = ""
        for token in re.findall(r"`([^`\s]+)`", line):
            for path in _expand(token):
                if path.startswith(".../"):
                    hits = sorted(f for f in known_files if f.endswith(path[3:]))
                    if len(hits) > 1 and previous:
                        best = max(_common_prefix_len(h, previous) for h in hits)
                        hits = [
                            h for h in hits if _common_prefix_len(h, previous) == best
                        ]
                    if len(hits) != 1:
                        continue
                    path = hits[0]
                if "/" in path and not path.startswith(("http", "plane:")):
                    paths.add(path)
                    previous = path
    return paths


def check_patches(root, base, head):
    base_files = set(git(root, "ls-tree", "-r", "--name-only", base).split("\n")) - {""}
    head_files = set(git(root, "ls-tree", "-r", "--name-only", head).split("\n")) - {""}
    changed = set()
    for line in git(
        root, "diff", "--name-status", "--no-renames", "--diff-filter=MD", base, head
    ).splitlines():
        _status, _, path = line.partition("\t")
        if path in base_files:
            changed.add(path)
    with open(os.path.join(root, "fork", "PATCHES.md"), encoding="utf-8") as fh:
        listed = listed_upstream_paths(fh.read(), base_files | head_files)
    missing = sorted(changed - listed)
    print(
        f"== patches: {len(changed)} upstream files changed since {base}, {len(listed)} paths listed"
    )
    for path in missing:
        print(f"  MISSING  {path}  (changed upstream file, not in fork/PATCHES.md)")
    for path in sorted((listed & base_files) - changed):
        print(f"  note     {path}  (listed, but the fork no longer changes it)")
    if not missing:
        print("  ok: every changed upstream file is listed")
    return 1 if missing else 0


# ------------------------------------------------------------------- parity


def _literal(node):
    return (
        node.value
        if isinstance(node, ast.Constant) and isinstance(node.value, str)
        else None
    )


def publish_calls(root, folder, function):
    """(kind, verb, path:line) of every call to `function` in the python files under `folder`."""
    out = []
    base = os.path.join(root, folder)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in {"__pycache__", "tests"})
        for name in sorted(filenames):
            if not name.endswith(".py"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, encoding="utf-8") as fh:
                try:
                    tree = ast.parse(fh.read())
                except SyntaxError:
                    continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                target = node.func
                called = (
                    target.id
                    if isinstance(target, ast.Name)
                    else getattr(target, "attr", None)
                )
                if called != function:
                    continue
                args = {k.arg: k.value for k in node.keywords if k.arg}
                positional = list(node.args)
                # publish_metadata_event(project_id, kind, verb, actor_id, settle=False)
                # publish_work_item_event(project_id, issue_ids, kind, verb, actor_id, settle=False)
                offset = 2 if function == "publish_work_item_event" else 1
                kind = args.get(
                    "kind", positional[offset] if len(positional) > offset else None
                )
                verb = args.get(
                    "verb",
                    positional[offset + 1] if len(positional) > offset + 1 else None,
                )
                out.append(
                    (
                        _literal(kind) or "<dynamic>",
                        _literal(verb) or "<dynamic>",
                        f"{rel}:{node.lineno}",
                    )
                )
    return sorted(out, key=lambda c: (c[0], c[1], c[2]))


def read_allow(root):
    allowed = {}
    path = os.path.join(root, ALLOW_FILE)
    if not os.path.exists(path):
        return allowed
    with open(path, encoding="utf-8") as fh:
        for number, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                raise RuntimeError(
                    f"{ALLOW_FILE}:{number}: expected '<kind> <verb>  # reason'"
                )
            allowed[(parts[0], parts[1])] = (
                raw.split("#", 1)[1].strip() if "#" in raw else ""
            )
    return allowed


def check_parity(root):
    app = publish_calls(root, APP_VIEWS, "publish_metadata_event")
    api = publish_calls(root, API_VIEWS, "publish_metadata_event")
    api_pairs = {(k, v) for k, v, _ in api}
    allowed = read_allow(root)
    print(
        f"== parity: {len(app)} metadata publishes in app views, {len(api)} in REST v1 views"
    )
    missing = []
    for kind, verb, where in app:
        if (kind, verb) in api_pairs:
            continue
        if (kind, verb) in allowed:
            print(
                f"  allowed  {kind} {verb}  {where}  ({allowed[(kind, verb)] or 'see ' + ALLOW_FILE})"
            )
            continue
        missing.append((kind, verb, where))
        print(f"  MISSING  {kind} {verb}  published by {where}, by no REST v1 view")
    for pair in sorted(set(allowed) - {(k, v) for k, v, _ in app}):
        print(
            f"  note     {pair[0]} {pair[1]}  is allowed but no app view publishes it any more (stale entry)"
        )
    for kind, verb, where in publish_calls(root, APP_VIEWS, "publish_work_item_event"):
        print(
            f"  note     work item {kind} {verb}  {where}  (direct publish; REST v1 work items use issue_activity)"
        )
    if not missing:
        print("  ok: every app metadata publish has a REST v1 counterpart")
    return 1 if missing else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "check", nargs="?", default="all", choices=["patches", "parity", "all", "list"]
    )
    parser.add_argument(
        "--base",
        default=DEFAULT_BASE,
        help=f"upstream ref the fork is based on (default {DEFAULT_BASE})",
    )
    parser.add_argument(
        "--head", default="HEAD", help="fork ref to check (default HEAD)"
    )
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    ns = parser.parse_args(argv)
    try:
        root = git(ns.root, "rev-parse", "--show-toplevel").strip()
        if ns.check == "list":
            # the upstream paths PATCHES.md lists, one per line (used by rebase-check.sh)
            known = set(
                git(root, "ls-tree", "-r", "--name-only", ns.head).split("\n")
            ) - {""}
            with open(os.path.join(root, "fork", "PATCHES.md"), encoding="utf-8") as fh:
                print("\n".join(sorted(listed_upstream_paths(fh.read(), known))))
            return 0
        status = 0
        if ns.check in ("patches", "all"):
            git(root, "rev-parse", "--verify", "--quiet", f"{ns.base}^{{commit}}")
            status |= check_patches(root, ns.base, ns.head)
        if ns.check in ("parity", "all"):
            status |= check_parity(root)
    except RuntimeError as exc:
        print(f"fork_checks: {exc}", file=sys.stderr)
        return 2
    return status


if __name__ == "__main__":
    sys.exit(main())
