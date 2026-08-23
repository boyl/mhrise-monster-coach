from __future__ import annotations

import pathlib
import sys

from lupa import LuaRuntime


def main() -> int:
    repository = pathlib.Path(__file__).resolve().parents[1]
    files = sorted((repository / "reframework").rglob("*.lua"))
    files.extend(sorted((repository / "tests").glob("test_*.lua")))
    runtime = LuaRuntime()
    failures: list[tuple[pathlib.Path, str]] = []
    for path in files:
        try:
            runtime.compile(path.read_text(encoding="utf-8"))
        except Exception as error:
            failures.append((path, str(error)))
    for path, error in failures:
        print(f"FAIL {path.relative_to(repository)} - {error}")
    print(f"Lua syntax: {len(files) - len(failures)}/{len(files)} PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
