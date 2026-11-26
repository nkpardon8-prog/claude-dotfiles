#!/usr/bin/env python3
"""memory-lint.py - report-only health check for Claude Code memory directories.

Four checks per memory dir:
  missing-link   index (MEMORY.md) links whose destination is not an existing file
                 (reported by index line number; the destination text is never printed)
  orphan         note files linked from neither MEMORY.md nor MEMORY-archive.md
                 (MEMORY.md links the archive, so archived notes count as indexed)
  index-size     MEMORY.md over 17,000 bytes, or any MEMORY.md line over 120 chars
  stale-project  notes with frontmatter `type: project` (top level, or a direct child of
                 `metadata:`) whose file mtime is older than 60 days

Prints counts, file names and line numbers only, never note or index content. A directory
that cannot be fully read is reported as incomplete and the scan moves on. Always exits 0.

Usage: memory-lint.py [--dir DIR ...]   (default: every ~/.claude/projects/*/memory)
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path
from urllib.parse import unquote

INDEX = "MEMORY.md"
ARCHIVE = "MEMORY-archive.md"
MAX_INDEX_BYTES = 17_000
MAX_LINE_CHARS = 120
STALE_SECONDS = 60 * 86400
CHECKS = ("missing-link", "orphan", "index-size", "stale-project")

# An inline markdown link: [text](dest) or [text](<dest with spaces>), optional "title".
LINK_RE = re.compile(r"(?<!\\)\[[^\[\]]*\]\(\s*(<[^<>\n]*>|[^()\s]+)(?:\s+\"[^\"]*\")?\s*\)")
CODE_SPAN_RE = re.compile(r"(`+).*?\1")


def is_note(path: Path) -> bool:
    name = path.name
    return (
        path.is_file()
        and name.endswith(".md")
        and name not in (INDEX, ARCHIVE)
        and ".bak" not in name
    )


def local_links(text: str) -> list[tuple[int, str]]:
    """(line number, destination) for each local link outside code spans and fences."""
    links: list[tuple[int, str]] = []
    in_fence = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for dest in LINK_RE.findall(CODE_SPAN_RE.sub("", line)):
            if dest.startswith("<"):
                dest = dest[1:-1]
            dest = unquote(dest.split("#", 1)[0])
            if not dest or "://" in dest or dest.startswith("mailto:"):
                continue
            links.append((n, dest))
    return links


def strip_value(raw: str) -> str:
    return re.sub(r"\s+#.*$", "", raw).strip().strip("'\"")


def frontmatter_type(path: Path) -> str | None:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    in_metadata = False
    child_indent: int | None = None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        pair = re.match(r"^\s*([A-Za-z_][\w-]*):(?:\s+(.*))?$", line)
        if indent == 0:
            in_metadata, child_indent = False, None
            if pair:
                key, value = pair.group(1), strip_value(pair.group(2) or "")
                if key == "type":
                    return value
                in_metadata = key == "metadata" and value == ""
            continue
        if in_metadata and pair:
            if child_indent is None:
                child_indent = indent
            if indent == child_indent and pair.group(1) == "type":
                return strip_value(pair.group(2) or "")
    return None


def lint_dir(d: Path, now: float) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {c: [] for c in CHECKS}
    linked: set[Path] = set()
    index = d / INDEX
    if index.is_file():
        raw = index.read_bytes()
        text = raw.decode("utf-8", errors="replace")
        for n, dest in local_links(text):
            target = (d / dest).resolve()
            linked.add(target)
            if not target.is_file():
                found["missing-link"].append(f"{INDEX} line {n}")
        if len(raw) > MAX_INDEX_BYTES:
            found["index-size"].append(f"{INDEX} is {len(raw)} bytes (max {MAX_INDEX_BYTES})")
        for n, line in enumerate(text.splitlines(), 1):
            if len(line) > MAX_LINE_CHARS:
                found["index-size"].append(f"{INDEX} line {n} is {len(line)} chars (max {MAX_LINE_CHARS})")
    else:
        found["index-size"].append(f"{INDEX} missing")
    archive = d / ARCHIVE
    if archive.is_file():
        text = archive.read_text(encoding="utf-8", errors="replace")
        linked.update((d / dest).resolve() for _, dest in local_links(text))

    for note in sorted(p for p in d.iterdir() if is_note(p)):
        if note.resolve() not in linked:
            found["orphan"].append(note.name)
        if frontmatter_type(note) == "project":
            age = now - note.stat().st_mtime
            if age > STALE_SECONDS:
                found["stale-project"].append(f"{note.name} ({int(age // 86400)} days)")
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
        try:
            results = lint_dir(d, now)
        except OSError as exc:
            where = Path(exc.filename).name if getattr(exc, "filename", None) else "?"
            print(f"  incomplete: {type(exc).__name__} reading {where}")
            continue
        for check, items in results.items():
            print(f"{check}: {len(items)}")
            for item in items:
                print(f"  {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
