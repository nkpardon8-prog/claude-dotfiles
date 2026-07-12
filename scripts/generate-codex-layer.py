#!/usr/bin/env python3
"""Generate Codex skills from the Claude dotfiles command framework."""

from __future__ import annotations

import os
import re
import shutil
import textwrap
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
COMMANDS = REPO / "commands"
NATIVE_SKILLS = REPO / "skills"
OUT = REPO / "codex" / "generated"
SKILLS_OUT = OUT / "skills" / "claude-dotfiles"

MANAGED_BEGIN = "<!-- BEGIN CLAUDE-DOTFILES-CODEX -->"
MANAGED_END = "<!-- END CLAUDE-DOTFILES-CODEX -->"

SKIP_COMMAND_PARTS = {
    "lib",
    "broad-reviewers",
}
SKIP_COMMAND_FILES = {
    "plan_base.md",
    "README.md",
    "CHANGELOG.md",
    "CRITERIA.md",
}


def slug(value: str) -> str:
    value = value.strip().lower()
    value = value.replace(":", "-").replace("/", "-").replace("_", "-")
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    return value or "unnamed"


def strip_frontmatter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    raw = text[4:end]
    body = text[end + 5 :]
    meta: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        meta[key.strip()] = value.strip().strip('"').strip("'")
    return meta, body.lstrip()


def first_useful_line(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith(">"):
            continue
        if line.startswith("|") or line.startswith("---"):
            continue
        return line
    for line in text.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line
    return "Ported Claude dotfiles workflow."


def one_line(value: str, limit: int = 360) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    value = value.replace('"', "'")
    if len(value) <= limit:
        return value
    return value[: limit - 1].rstrip() + "."


def folded_yaml(value: str, indent: int = 2, width: int = 100) -> str:
    value = one_line(value, limit=900)
    prefix = " " * indent
    return "\n".join(prefix + line for line in textwrap.wrap(value, width=width))


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def command_aliases(path: Path) -> list[str]:
    rel = path.relative_to(COMMANDS).with_suffix("")
    parts = rel.parts
    slash = "/" + "/".join(parts)
    aliases = [slash]
    if len(parts) > 1:
        aliases.append("/" + parts[0] + ":" + ":".join(parts[1:]))
    return aliases


def command_skill_name(path: Path) -> str:
    rel = path.relative_to(COMMANDS).with_suffix("")
    return "claude-command-" + slug("-".join(rel.parts))


def should_skip_command(path: Path) -> bool:
    rel = path.relative_to(COMMANDS)
    if path.name in SKIP_COMMAND_FILES:
        return True
    return any(part in SKIP_COMMAND_PARTS for part in rel.parts)


def source_ref(path: Path) -> str:
    return str(path.relative_to(REPO))


def command_skill(path: Path) -> tuple[str, str]:
    raw = path.read_text(encoding="utf-8")
    meta, body = strip_frontmatter(raw)
    aliases = command_aliases(path)
    primary = aliases[-1] if ":" in aliases[-1] else aliases[0]
    description = meta.get("description") or first_useful_line(body)
    trigger = ", ".join(aliases)
    name = command_skill_name(path)
    rel = source_ref(path)
    full_description = (
        f"Use when the user invokes {trigger}, or asks for the matching Claude dotfiles workflow. "
        f"{description}"
    )

    content = f"""---
name: {name}
description: >-
{folded_yaml(full_description)}
metadata:
  short-description: "Port of {primary}"
---

# {primary}

This is the Codex port of the Claude dotfiles command `{primary}`.

## Codex Adaptation

- Treat text after `{primary}` as `$ARGUMENTS`.
- Source file: `{rel}` in `~/.claude-dotfiles`.
- If the original command mentions Claude-only tools (`Task`, `Read`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, `Write`, `Edit`), map them to the available Codex tools and local shell/file operations.
- If the command requests Claude `Task` subagents, use Codex delegation only when the current user request or command invocation clearly authorizes delegation; otherwise perform the work locally.
- Do not rely on Claude hooks, statusline behavior, or native slash-command state. Recreate only the workflow outcome that matters for Codex.
- Preserve the command's safety boundaries. Confirm before external deploys, public comments, database mutation, credential handling, destructive file operations, or pushing non-dotfiles repos.

## Original Command

{body}
"""
    return name, content


def native_skill(path: Path) -> tuple[str, str]:
    raw = path.read_text(encoding="utf-8")
    meta, body = strip_frontmatter(raw)
    skill_dir = path.parent.name
    name = "claude-skill-" + slug(skill_dir)
    description = meta.get("description") or first_useful_line(body)
    rel = source_ref(path)
    full_description = (
        f"Use when the user asks for the `{skill_dir}` capability from the Claude dotfiles framework. "
        f"{description}"
    )
    content = f"""---
name: {name}
description: >-
{folded_yaml(full_description)}
metadata:
  short-description: "Port of {skill_dir}"
---

# {skill_dir}

This is the Codex port of the Claude dotfiles native skill `{skill_dir}`.

## Codex Adaptation

- Source file: `{rel}` in `~/.claude-dotfiles`.
- Prefer Codex-native tools when available; use shell scripts from the source skill only when they still apply.
- Confirm before driving a real GUI, browser session, remote machine, credential flow, external service, or destructive action.

## Original Skill

{body}
"""
    return name, content


def command_index(entries: list[tuple[str, list[str], str]]) -> str:
    lines = [
        "---",
        "name: claude-dotfiles-command-index",
        "description: >-",
        "  Use when the user asks what Claude dotfiles commands or Codex-ported slash workflows are available.",
        "metadata:",
        '  short-description: "Claude dotfiles command index"',
        "---",
        "",
        "# Claude Dotfiles Command Index",
        "",
        "Codex ports each Claude command into a skill. Invoke by plain language or by the old slash alias.",
        "",
        "| Alias | Codex Skill | Source |",
        "|---|---|---|",
    ]
    for name, aliases, rel in sorted(entries, key=lambda row: row[1][0]):
        lines.append(f"| `{', '.join(aliases)}` | `{name}` | `{rel}` |")
    lines.append("")
    return "\n".join(lines)


def instructions_block(command_count: int, native_count: int) -> str:
    return f"""{MANAGED_BEGIN}
# Claude Dotfiles Codex Bridge

Managed by `~/.claude-dotfiles/scripts/install-codex.sh`.

## Source Of Truth

- The canonical framework repo is `~/.claude-dotfiles`.
- Claude command source files live in `~/.claude-dotfiles/commands`.
- Codex skills generated from those commands live in `~/.codex/skills/claude-dotfiles`.
- Current generated surface: {command_count} command skills and {native_count} native skills.

## Slash Alias Routing

- Codex does not have Claude Code's native slash-command menu.
- When the user types a Claude-style command such as `/plan`, `/implement`, `/codex-review`, `/plan2bid:run`, or `/ui-ux-pro-max:design`, treat it as a request to use the matching `claude-command-*` skill.
- Text after the slash command is the command argument payload.
- Also trigger these skills from natural language when the user clearly asks for the same workflow.
- To list available ported commands, use the `claude-dotfiles-command-index` skill.

## Global Rules Ported From CLAUDE.md

- Never upgrade, update, regenerate, or otherwise change a project's Next.js version unless the user explicitly approves that exact action.
- After code changes, check whether project documentation needs updates.
- Before calling work done, run relevant tests and validation unless the user explicitly tells you not to.
- Dotfiles repo policy: changes under `~/.claude-dotfiles` may be committed and pushed automatically after secret scanning.
- Other repo policy: never push application/project code to GitHub without explicit user approval.
- Treat credential files, `.env` files, browser sessions, remote desktops, deploys, database writes, public comments, and payment/account actions as sensitive. Ask before mutating or exposing anything material.

## Tool Mapping

- Claude `Read`, `Grep`, and `Glob` map to normal Codex file reads and shell search, preferably `rg`.
- Claude `WebSearch` and `WebFetch` map to Codex web browsing when current information or source attribution matters.
- Claude `Task` maps to Codex subagents only when delegation is explicitly authorized by the user's request or by a clearly invoked workflow that requires it and current policy permits it.
- Claude lifecycle hooks and statusline features do not exist natively in Codex. Preserve the workflow result, not the UI mechanics.

{MANAGED_END}"""


def generate() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    SKILLS_OUT.mkdir(parents=True, exist_ok=True)

    entries: list[tuple[str, list[str], str]] = []
    command_count = 0
    for path in sorted(COMMANDS.rglob("*.md")):
        if should_skip_command(path):
            continue
        name, content = command_skill(path)
        aliases = command_aliases(path)
        rel = source_ref(path)
        write(SKILLS_OUT / ("command-" + slug(name.removeprefix("claude-command-"))) / "SKILL.md", content)
        entries.append((name, aliases, rel))
        command_count += 1

    native_count = 0
    for path in sorted(NATIVE_SKILLS.glob("*/SKILL.md")):
        name, content = native_skill(path)
        write(SKILLS_OUT / ("native-" + slug(path.parent.name)) / "SKILL.md", content)
        native_count += 1

    write(SKILLS_OUT / "command-index" / "SKILL.md", command_index(entries))
    write(OUT / "instructions-block.md", instructions_block(command_count, native_count))
    write(OUT / "SUMMARY", f"Generated {command_count} command skills and {native_count} native skills.\n")


if __name__ == "__main__":
    os.umask(0o022)
    generate()
