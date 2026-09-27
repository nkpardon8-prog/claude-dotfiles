# Codex Bridge

This directory documents the Codex layer generated from the Claude dotfiles repo.

Codex does not have Claude Code's native slash-command UI, so the bridge maps the
same source files into Codex skills:

- `commands/*.md` -> `~/.codex/skills/claude-dotfiles/command-*/SKILL.md`
- `skills/*/SKILL.md` -> `~/.codex/skills/claude-dotfiles/native-*/SKILL.md`
- global routing rules -> managed block in `~/.codex/instructions.md`
- `codex/overrides/<dir>/SKILL.md` -> copied whole INSTEAD of the automatic port for that output dir
  (same dir name, same skill name). Used where a command's steps only work inside Claude Code; the
  generator fails loud on an override with no matching command. Today: `command-transfer`.

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
use /database-audit
```

The slash names are aliases, not native Codex slash commands. Codex sees them
through the generated skill metadata and the global routing instructions.
In the Codex terminal app a message that STARTS with an unknown `/name` is rejected
before it reaches the model ("Unrecognized command"; codex-cli 0.157 source), so there
use `$` instead: type `$transfer` (or `$plan`, ...) and pick the `claude-command-*`
skill from the list, or just ask in plain words.

## Moving a Codex chat to your other Mac

The `claude-command-transfer` skill is hand-written (`codex/overrides/command-transfer/`)
because the Claude `/transfer` steps (`/pre-compact`, Claude session files) do not exist in
Codex. Inside the Codex chat you want to move: type `$transfer`, pick
`claude-command-transfer` (or say "move this chat to my other Mac"). It writes
`TRANSFER.<id>.md` notes at the repo root, then runs
`transfer-send.sh --tool codex --sid "$CODEX_THREAD_ID" --seal-after-exit` with escalated
permissions (the sandbox blocks `ps` and iCloud Drive; approve the prompt), shows a code, and
asks you to close the chat (`/quit` or Ctrl-C twice). The file seals once the chat has closed:
right away when the Codex window itself ran the chat, about a minute later when Codex's shared
background server (`codex app-server`) did, because that server keeps the chat's lock for ~60 s
after the last window leaves. On the other Mac: `resumework <code>` or the Resume Chat app.
