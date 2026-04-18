# `/transcribe` — Audio → Transcript + Project-Aware Report

Transcribe an audio recording (iPhone Voice Memos, phone call recordings, handheld recorders, etc.) via the OpenAI Whisper API, then generate an analysis report framed in the context of the project you're currently working in.

Use case: record a client meeting, run `/transcribe` from inside the project codebase, get back client asks mapped to real files, decisions, action items, open questions, and notable quotes — ready to feed into `/plan`.

---

## Setup (one-time)

### 1. Install ffmpeg

```bash
brew install ffmpeg
```

Required for format transcoding and chunking files over Whisper's 25MB limit.

### 2. Create your `.env`

```bash
cp ~/.claude-dotfiles/.env.example ~/.claude-dotfiles/.env
chmod 600 ~/.claude-dotfiles/.env
```

Then edit `~/.claude-dotfiles/.env` and replace `sk-REPLACE_ME` with your real OpenAI API key (from https://platform.openai.com/api-keys).

`.env` is gitignored — it will never be pushed to GitHub. `.env.example` is the committed template.

### 3. Verify

```bash
bash ~/.claude-dotfiles/scripts/whisper-transcribe.sh --preflight
```

Should exit `0`. If it exits `2`, the `.env` or key is missing/placeholder. If `3`, ffmpeg isn't installed.

---

## Usage

Four forms, all global (works in any project):

```
/transcribe
```
Prompts you for a file.

```
/transcribe ~/Desktop/jon-meeting.m4a
```
Direct path.

```
/transcribe jon-meeting
```
Name-only — auto-searches `$PWD`, `~/Desktop`, `~/Documents`, `~/Downloads`, `~/`, and the iCloud Voice Memos directory.

```
/transcribe jon-meeting focus on the pricing discussion and ignore the intro small-talk
```
Name + steering instructions for the analysis step.

---

## Supported audio formats

**Native to Whisper (uploaded as-is when ≤25MB):**
`.m4a`, `.mp3`, `.mp4`, `.mpeg`, `.mpga`, `.wav`, `.webm`

**Transcoded to `.m4a` first (via ffmpeg):**
`.caf` (older Voice Memos), `.aac`, `.flac`, `.ogg`, `.opus`, `.wma`

**Large files:** any file over 25MB is re-encoded to mono 64kbps `.m4a` to compress. If it's still too big after that (multi-hour meetings), it's split into ≤20MB chunks with `ffmpeg -f segment`, each chunk transcribed separately, and the transcripts concatenated in order with `--- chunk N/M ---` separators.

---

## Output

Written to `~/Desktop/CODEBASES/transcriptions/YYYY-MM-DD-<slug>/`:

| File | Contents |
|------|----------|
| `transcript.txt` | Raw Whisper output (plain text, chunk separators if applicable) |
| `report.md` | Project-aware analysis (see below) |
| `source.txt` | Absolute path to the original audio file (provenance, not the audio itself) |

The output directory sits **outside** the dotfiles repo, so transcripts never risk being committed.

---

## Project-aware report

When generating `report.md`, the command reads the following from your current working directory (skipping what doesn't exist):

- `CLAUDE.md`
- `README.md`
- `docs/OVERVIEW.md` and any other `docs/**/*.md`
- `./tmp/briefs/*.md`
- `./tmp/done-plans/*.md`
- `git log --oneline -20`

The report then frames client asks against real files and features in the project — e.g. "Client wants invoice export → existing `src/invoices/` module, would need to add CSV formatter alongside `pdf-exporter.ts`." Generic advice is a failure mode; the command is designed to produce specific, actionable mappings.

Structure of `report.md`:

- Executive Summary
- Client Asks / Requirements (with project mappings)
- Decisions Made
- Action Items (owners + deadlines if mentioned)
- Open Questions / Ambiguities
- Technical Constraints
- Notable Quotes (verbatim)
- Appendix (paths to transcript and source)

---

## Troubleshooting

Exit codes from `scripts/whisper-transcribe.sh`:

| Code | Meaning | Fix |
|------|---------|-----|
| `2` | `.env` missing OR `OPENAI_API_KEY` unset/placeholder | `cp .env.example .env`, `chmod 600 .env`, replace `sk-REPLACE_ME` with your real key |
| `3` | `ffmpeg` not on `PATH` | `brew install ffmpeg` |
| `4` | Whisper API error | `curl --fail-with-body` means the HTTP response body is printed to stderr above the exit. Read OpenAI's JSON error message for the cause: common ones are `invalid_api_key`, `rate_limit_exceeded`, and `invalid_request_error` (e.g. corrupt audio). |
| `5` | `--resolve` found zero matches | Pass a more specific name or a full path |

### "No matching file found" on auto-search

Search is `find -maxdepth 2` in each of: `$PWD`, `~/Desktop`, `~/Documents`, `~/Downloads`, `~/`, iCloud Voice Memos. If your file is nested deeper, pass a full path.

### Voice Memos file from iPhone

If you're syncing via iCloud, the file shows up at `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`. Or export from the Voice Memos app to Desktop/Downloads via "Share → Save to Files" — either works.

---

## Security

- `OPENAI_API_KEY` is loaded from `~/.claude-dotfiles/.env` (mode 600, gitignored).
- The key is passed to `curl` via an `Authorization` header — it is **not** visible in `ps` output or shell history.
- The key is never written to `transcript.txt`, `report.md`, or any log.
- Output goes to `~/Desktop/CODEBASES/transcriptions/` — **outside** the dotfiles repo — so transcripts of sensitive client conversations are not auto-pushed to GitHub.

If you ever need to verify the repo is clean:

```bash
git -C ~/.claude-dotfiles log --all -p | grep -E 'sk-[A-Za-z0-9]{20,}'   # should be empty
git -C ~/.claude-dotfiles ls-files | grep -F .env                       # should show only .env.example
```

---

## Cost

OpenAI Whisper is priced at **$0.006/minute** (as of this writing). Rough estimates:

- 30-minute meeting → ~$0.18
- 1-hour meeting → ~$0.36
- 2-hour meeting → ~$0.72

Chunking a long file doesn't change the total cost (billed by audio duration, not request count).

---

## Related commands

- `/plan <feature>` — turn an ask from the report into an implementation plan
- `/discussion <topic>` — explore an ambiguous open question before planning
