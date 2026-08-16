#!/usr/bin/env python3
"""按资源引用闭包提取单只 MHRise 怪物的 AI 数据。"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


RESOURCE_PATTERN = re.compile(
    r"(?i)(?:natives[\\/](?:stm|x64)[\\/])?"
    r"(enemy[\\/]em\d{3}[\\/][a-z0-9_./\\-]+?\.user)(?:\.\d+)?"
)
EXTRACTED_PATTERN = re.compile(r"Extracted\s+\d+\s+files?", re.IGNORECASE)


def normalize_path(value: str) -> str:
    return value.strip().replace("\\", "/").lower()


def load_release_list(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        if raw.strip():
            entries[normalize_path(raw)] = raw.strip()
    return entries


def seed_paths(entries: dict[str, str], monster: str, variant: str) -> set[str]:
    prefix = f"natives/stm/enemy/{monster}/{variant}/ai_fsm_user_data/"
    return {key for key in entries if key.startswith(prefix)}


def extract_resource_references(data: bytes, monster: str) -> set[str]:
    references: set[str] = set()
    for offset in (0, 1):
        text = data[offset:].decode("utf-16le", errors="ignore")
        for match in RESOURCE_PATTERN.finditer(text):
            value = normalize_path(match.group(1))
            if value.startswith(f"enemy/{monster}/"):
                references.add(value)
    return references


def resolve_references(references: set[str], entries: dict[str, str]) -> tuple[set[str], set[str]]:
    revision_index: dict[str, set[str]] = {}
    for key in entries:
        base = re.sub(r"\.\d+$", "", key)
        revision_index.setdefault(base, set()).add(key)
    resolved: set[str] = set()
    unresolved: set[str] = set()
    for reference in references:
        prefix = f"natives/stm/{normalize_path(reference)}"
        matches = revision_index.get(prefix, set())
        if matches:
            resolved.update(matches)
        else:
            unresolved.add(reference)
    return resolved, unresolved


def scan_extracted(root: Path, monster: str) -> tuple[dict[str, set[str]], set[str]]:
    sources: dict[str, set[str]] = {}
    all_references: set[str] = set()
    monster_marker = f"/enemy/{monster}/"
    for path in sorted(root.rglob("*.user.*")):
        relative = normalize_path(path.relative_to(root).as_posix())
        if monster_marker not in "/" + relative:
            continue
        references = extract_resource_references(path.read_bytes(), monster)
        sources[relative] = references
        all_references.update(references)
    return sources, all_references


def extraction_succeeded(return_code: int, output: str) -> bool:
    return return_code == 0 or EXTRACTED_PATTERN.search(output) is not None


def run_retool(retool: Path, release_subset: Path, pak: Path, output_root: Path) -> str:
    result = subprocess.run(
        [str(retool), "-h", str(release_subset), "-x", "-skipUnknowns", "-noExtractDir", str(pak)],
        cwd=output_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    output = result.stdout + result.stderr
    if not extraction_succeeded(result.returncode, output):
        raise RuntimeError(f"RETool failed for {pak} (exit {result.returncode}):\n{output}")
    return output


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def build_manifest(
    root: Path,
    monster: str,
    variant: str,
    selected: set[str],
    sources: dict[str, set[str]],
    unresolved: set[str],
) -> dict:
    files = []
    for relative, references in sorted(sources.items()):
        path = root / Path(relative)
        files.append({
            "path": relative,
            "size": path.stat().st_size,
            "sha256": sha256(path),
            "references": sorted(references),
        })
    return {
        "schema_version": 1,
        "monster": monster,
        "variant": variant,
        "selected_paths": sorted(selected),
        "files": files,
        "unresolved_references": sorted(unresolved),
    }


def extract_closure(args: argparse.Namespace) -> dict:
    entries = load_release_list(args.release_list)
    selected = seed_paths(entries, args.monster, args.variant)
    if not selected:
        raise ValueError(f"No AI seed paths for {args.monster}/{args.variant}")

    args.extracted_root.mkdir(parents=True, exist_ok=True)
    list_root = args.extracted_root / ".monster-coach-lists"
    list_root.mkdir(exist_ok=True)
    pending = set(selected)

    for pass_number in range(1, args.max_passes + 1):
        if args.retool and pending:
            subset = list_root / f"pass-{pass_number:02d}.list"
            subset.write_text(
                "\n".join(entries[path] for path in sorted(pending)) + "\n",
                encoding="utf-8",
            )
            for pak in args.pak:
                run_retool(args.retool, subset, pak, args.extracted_root)

        sources, references = scan_extracted(args.extracted_root, args.monster)
        resolved, unresolved = resolve_references(references, entries)
        pending = resolved - selected
        selected.update(resolved)
        if not pending or not args.retool:
            manifest = build_manifest(
                args.extracted_root,
                args.monster,
                args.variant,
                selected,
                sources,
                unresolved,
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            return manifest

    raise RuntimeError(f"Reference closure did not converge after {args.max_passes} passes")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-list", type=Path, required=True)
    parser.add_argument("--extracted-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--monster", default="em032")
    parser.add_argument("--variant", default="00")
    parser.add_argument("--retool", type=Path)
    parser.add_argument("--pak", type=Path, action="append", default=[])
    parser.add_argument("--max-passes", type=int, default=20)
    args = parser.parse_args()
    args.monster = normalize_path(args.monster)
    args.variant = normalize_path(args.variant)
    if bool(args.retool) != bool(args.pak):
        parser.error("--retool and at least one --pak must be supplied together")
    return args


if __name__ == "__main__":
    result = extract_closure(parse_args())
    print(
        f"{result['monster']}: {len(result['files'])} files, "
        f"{len(result['selected_paths'])} selected paths, "
        f"{len(result['unresolved_references'])} unresolved references"
    )
