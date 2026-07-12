# Codex Bridge

This directory documents the Codex layer generated from the Claude dotfiles repo.

Codex does not have Claude Code's native slash-command UI, so the bridge maps the
same source files into Codex skills:

- `commands/*.md` -> `~/.codex/skills/claude-dotfiles/command-*/SKILL.md`
- `skills/*/SKILL.md` -> `~/.codex/skills/claude-dotfiles/native-*/SKILL.md`
- global routing rules -> managed block in `~/.codex/instructions.md`

Install or refresh globally:

```bash
~/.claude-dotfiles/scripts/install-codex.sh
```

After install, new Codex shells run `scripts/codex-sync.sh` before launching
Codex. That pulls this repo when possible and refreshes the generated Codex
skills so changes apply to future sessions.

## Usage

Invoke workflows in plain language or with their old Claude slash names:

```text
/plan build a Stripe checkout flow
use /implement on ./tmp/ready-plans/foo.md
run /codex-review
use /ui-ux-pro-max:design-system
```

The slash names are aliases, not native Codex slash commands. Codex sees them
through the generated skill metadata and the global routing instructions.
