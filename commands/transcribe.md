---
description: Transcribe an audio recording (Voice Memos, phone call, etc.) via OpenAI Whisper and generate a project-context-aware analysis report.
argument-hint: "[file path or name] [optional: analysis instructions]"
---

# Transcribe Agent

Transcribe an audio file with OpenAI Whisper, then write a project-aware analysis report.

Arguments: `$ARGUMENTS` — a file path, a filename fragment, or empty. Anything after the file reference is treated as analysis instructions (e.g. "focus on pricing decisions").

## Step 1: Preflight

Run: `bash ~/.claude-dotfiles/scripts/whisper-transcribe.sh --preflight`

- Exit 0 → proceed.
- Exit 2 → tell the user `.env` or `OPENAI_API_KEY` is missing. Point them at `~/.claude-dotfiles/.env.example`. Stop.
- Exit 3 → tell the user `ffmpeg` isn't installed. Suggest `brew install ffmpeg`. Stop.

## Step 2: Resolve the audio file

`$ARGUMENTS` is one literal string (not shell-tokenized). Parse it intelligently:

1. **Empty** → ask the user which file they want transcribed.
2. **Try the whole string as a file path** (after trimming). If it points to an existing file, the file is the whole string and there are no instructions.
3. **Shrink from the right**: drop one trailing word at a time and check whether the remaining left portion is an existing file. The dropped suffix becomes the analysis instructions. This handles spaces in filenames like `Jon speaker event.m4a focus on pricing`.
4. **Fallback — name search**: call `bash ~/.claude-dotfiles/scripts/whisper-transcribe.sh --resolve "<best-guess-name>"` where the best guess is the substring most likely to be the filename (use an audio-extension word if one appears, else the whole string):
   - Exit 5 (no matches) → ask the user for a better name or a full path.
   - 1 match → confirm with the user, then use it.
   - Multiple matches → present the list, ask the user to pick.
5. **Never assume "first whitespace token = filename"** — macOS audio files routinely have spaces.

## Step 3: Compute output directory

```
slug   = lowercase, spaces→hyphens, strip non-[a-z0-9-] of the audio filename stem
date   = YYYY-MM-DD (today)
outdir = ~/Desktop/CODEBASES/transcriptions/{date}-{slug}/
```

Create it with `mkdir -p`.

## Step 4: Run the transcription script

```
bash ~/.claude-dotfiles/scripts/whisper-transcribe.sh "<resolved-audio-path>" "<outdir>"
```

If it exits non-zero, relay stderr to the user and stop. Do NOT attempt to proceed to analysis on a failed transcription.

On success, the script has written:
- `<outdir>/transcript.txt` — raw Whisper output
- `<outdir>/source.txt` — original audio path

## Step 5: Gather project context

Read from the current working directory (skip what doesn't exist):

- `CLAUDE.md`
- `README.md`
- `docs/OVERVIEW.md`, then any other `docs/**/*.md` files
- `./tmp/briefs/*.md`
- `./tmp/done-plans/*.md`
- `git log --oneline -20` (if inside a repo)

For a large codebase where the above isn't enough, spawn an Explore sub-agent to summarize the architecture quickly. Don't over-research — the goal is enough context to map client asks to real files.

Also read the transcript: `<outdir>/transcript.txt`.

## Step 6: Write the analysis report

Write `<outdir>/report.md` with this structure:

```markdown
# Meeting Report — <slug>

**Source:** <original audio path>
**Project context:** <current working directory + one-line project summary>

## Executive Summary
(3–5 sentences)

## Client Asks / Requirements
- <ask>, mapped to specific project file(s) / feature(s) when the mapping is clear

## Decisions Made

## Action Items
- [ ] <item> — <owner if mentioned> — <deadline if mentioned>

## Open Questions / Ambiguities

## Technical Constraints

## Notable Quotes
> verbatim excerpts worth preserving

---
## Appendix
- Transcript: `./transcript.txt`
- Source audio: see `./source.txt`
```

Apply any analysis instructions from `$ARGUMENTS` as steering (e.g. "focus on pricing" → expand that section, compress others). Be specific and concrete — generic advice is a failure.

## Step 7: Report to the user

Show:
- Path to `report.md` and `transcript.txt`
- 3-bullet summary of what's in the report
- Suggested next steps:
  - `/plan <feature from the report>` — turn an ask into an implementation plan
  - `/discussion <ambiguous topic>` — explore an open question before planning

## Safety rules (non-negotiable)

- Never echo, log, or write `$OPENAI_API_KEY` anywhere.
- Never write the key into `transcript.txt`, `report.md`, or any tool output.
- The script is the single boundary that handles the key; the command body never reads `.env` directly.
