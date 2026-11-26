#!/usr/bin/env python3
"""memory-lint.py - report-only health check for Claude Code memory directories.

Four checks per memory dir:
  missing-link   index (MEMORY.md) links that point at a file that does not exist
  orphan         note files linked from neither MEMORY.md nor MEMORY-archive.md
                 (MEMORY.md links the archive, so archived notes count as indexed)
  index-size     MEMORY.md over 17,000 bytes, or any MEMORY.md line over 120 chars
  stale-project  notes with frontmatter `type: project` (top level or under `metadata:`)
                 whose file mtime is older than 60 days

Prints counts and file names only, never note content. Always exits 0.

Usage: memory-lint.py [--dir DIR ...]   (default: every ~/.claude/projects/*/memory)
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

INDEX = "MEMORY.md"
ARCHIVE = "MEMORY-archive.md"
MAX_INDEX_BYTES = 17_000
MAX_LINE_CHARS = 120
STALE_DAYS = 60
LINK_RE = re.compile(r"\]\(([^)\s#]+)(?:#[^)]*)?\)")


def is_note(path: Path) -> bool:
    name = path.name
    return (
        path.is_file()
        and name.endswith(".md")
        and name not in (INDEX, ARCHIVE)
        and ".bak" not in name
    )


def local_links(text: str) -> list[str]:
    return [t for t in LINK_RE.findall(text) if "://" not in t and not t.startswith("mailto:")]


def frontmatter_type(path: Path) -> str | None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    in_metadata = False
    for line in lines[1:]:
        if line.strip() == "---":
            break
        top = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if top:
            key, value = top.group(1), top.group(2).strip().strip("'\"")
            in_metadata = key == "metadata" and value == ""
            if key == "type":
                return value
            continue
        nested = re.match(r"^\s+type:\s*(.*)$", line)
        if in_metadata and nested:
            return nested.group(1).strip().strip("'\"")
    return None


def lint_dir(d: Path, now: float) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {"missing-link": [], "orphan": [], "index-size": [], "stale-project": []}
    index = d / INDEX
    linked: set[str] = set()
    if index.is_file():
        raw = index.read_bytes()
        text = raw.decode("utf-8", errors="replace")
        for target in local_links(text):
            linked.add(Path(target).name)
            if not (d / target).exists():
                found["missing-link"].append(target)
        if len(raw) > MAX_INDEX_BYTES:
            found["index-size"].append(f"{INDEX} is {len(raw)} bytes (max {MAX_INDEX_BYTES})")
        for n, line in enumerate(text.splitlines(), 1):
            if len(line) > MAX_LINE_CHARS:
                found["index-size"].append(f"{INDEX} line {n} is {len(line)} chars (max {MAX_LINE_CHARS})")
    else:
        found["index-size"].append(f"{INDEX} missing")
    archive = d / ARCHIVE
    if archive.is_file():
        linked.update(Path(t).name for t in local_links(archive.read_text(encoding="utf-8", errors="replace")))

    for note in sorted(p for p in d.iterdir() if is_note(p)):
        if note.name not in linked:
            found["orphan"].append(note.name)
        if frontmatter_type(note) == "project":
            age_days = int((now - note.stat().st_mtime) // 86400)
            if age_days > STALE_DAYS:
                found["stale-project"].append(f"{note.name} ({age_days} days)")
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description="Report-only memory directory lint.")
    ap.add_argument("--dir", action="append", default=[], help="memory dir (repeatable)")
    args = ap.parse_args()
    dirs = [Path(p).expanduser() for p in args.dir] or sorted(
        (Path.home() / ".claude" / "projects").glob("*/memory")
    )
    now = time.time()
    for d in dirs:
        print(f"== {d}")
        if not d.is_dir():
            print("  not a directory")
            continue
        for check, items in lint_dir(d, now).items():
            print(f"{check}: {len(items)}")
            for item in items:
                print(f"  {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
