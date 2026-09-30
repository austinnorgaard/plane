# SPDX-License-Identifier: AGPL-3.0-only
"""Tests for callsites.py. Run: python3 -m pytest fork/tools/test_callsites.py"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import callsites  # noqa: E402


def rows(src):
    return callsites.scan_source(src, "apps/api/plane/x.py")


def test_delay_kwargs():
    src = (
        "from plane.bgtasks.issue_activities_task import issue_activity\n"
        "issue_activity.delay(type='issue.activity.created', issue_id=str(i),\n"
        "    requested_data=rd, current_instance=None)\n"
    )
    (r,) = rows(src)
    assert r[3] == (
        "apps/api/plane/x.py:2 | type='issue.activity.created' | issue_id=str(i)"
        " | requested_data=rd | current_instance=None"
    )


def test_apply_async_kwargs_and_args():
    src = (
        "from a import issue_activity\n"
        "issue_activity.apply_async(kwargs={'type': 't1', 'issue_id': 'x', 'requested_data': 'r'})\n"
        "issue_activity.apply_async(args=['t2', 'r2', 'c2', 'i2'])\n"
    )
    a, b = rows(src)
    assert "type='t1' | issue_id='x' | requested_data='r' | current_instance=<missing>" in a[3]
    assert "type='t2' | issue_id='i2' | requested_data='r2' | current_instance='c2'" in b[3]


def test_aliased_import_and_direct_call():
    src = (
        "from a import issue_activity as ia\n"
        "ia.delay(type='t', issue_id=1)\n"
        "ia(type='u', issue_id=2)\n"
        "other.delay(type='no')\n"
    )
    found = rows(src)
    assert [r[3].split(" | ")[1] for r in found] == ["type='t'", "type='u'"]


def test_truncation_is_fixed_width():
    src = "issue_activity.delay(type='t', requested_data='" + "x" * 300 + "')\n"
    (r,) = rows(src)
    field = r[3].split(" | ")[3]
    assert field.endswith("...") and len(field) == len("requested_data=") + callsites.WIDTH


def test_check_mode(tmp_path=None):
    root = tempfile.mkdtemp()
    d = os.path.join(root, "apps", "api", "plane")
    os.makedirs(os.path.join(d, "tests"))
    with open(os.path.join(d, "v.py"), "w") as fh:
        fh.write("issue_activity.delay(type='t', issue_id=1)\n")
    with open(os.path.join(d, "tests", "t.py"), "w") as fh:
        fh.write("issue_activity.delay(type='ignored')\n")
    snap = os.path.join(root, "snap.txt")
    with open(snap, "w") as fh:
        fh.write("# header\n" + "\n".join(callsites.scan(root)) + "\n")
    assert len(callsites.scan(root)) == 1
    assert callsites.main(["--root", root, "--check", snap]) == 0
    with open(os.path.join(d, "v.py"), "a") as fh:
        fh.write("issue_activity.delay(type='new', issue_id=2)\n")
    assert callsites.main(["--root", root, "--check", snap]) == 1


def test_ignore_lines_tolerates_shift():
    root = tempfile.mkdtemp()
    d = os.path.join(root, "apps", "api", "plane")
    os.makedirs(d)
    path = os.path.join(d, "v.py")
    with open(path, "w") as fh:
        fh.write("issue_activity.delay(type='t', issue_id=1)\n")
    snap = os.path.join(root, "snap.txt")
    with open(snap, "w") as fh:
        fh.write("\n".join(callsites.scan(root)) + "\n")
    with open(path, "w") as fh:
        fh.write("# shift\nissue_activity.delay(type='t', issue_id=1)\n")
    assert callsites.main(["--root", root, "--check", snap]) == 1
    assert callsites.main(["--root", root, "--check", snap, "--ignore-lines"]) == 0


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
