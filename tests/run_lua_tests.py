from __future__ import annotations

import argparse
import os
import pathlib
import sys

from lupa import LuaRuntime


def run_test(path: pathlib.Path, repository: pathlib.Path) -> tuple[bool, str]:
    messages: list[str] = []
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals()["print"] = lambda *parts: messages.append("\t".join(map(str, parts)))
    module_root = (repository / "reframework" / "autorun").as_posix()
    runtime.execute(
        f'package.path = "{module_root}/?.lua;{module_root}/?/init.lua;" .. package.path'
    )
    try:
        runtime.execute(path.read_text(encoding="utf-8"))
    except Exception as error:  # Lupa exposes Lua errors through implementation-specific types.
        return False, str(error)
    expected = f"{path.name}: PASS"
    if expected not in messages:
        return False, f"missing explicit PASS marker: {expected}"
    return True, expected


def main() -> int:
    parser = argparse.ArgumentParser(description="Run isolated Monster Coach Lua behavior tests")
    parser.add_argument("paths", nargs="*", help="Optional test files relative to the repository")
    args = parser.parse_args()

    repository = pathlib.Path(__file__).resolve().parents[1]
    os.chdir(repository)
    paths = [repository / item for item in args.paths] if args.paths else sorted(
        (repository / "tests").glob("test_*.lua")
    )
    failed: list[tuple[pathlib.Path, str]] = []
    for path in paths:
        ok, message = run_test(path, repository)
        print(("PASS" if ok else "FAIL"), path.name, "-", message)
        if not ok:
            failed.append((path, message))
    print(f"Lua behavior: {len(paths) - len(failed)}/{len(paths)} PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
