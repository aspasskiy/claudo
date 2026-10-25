# Claudo

Claude + to-do: a macOS menu bar task manager that Claude plans for you. If you work through many Claude Code
sessions at once, each one leaves a loose end. Claudo reads those sessions and the git state of your repos, and keeps
one board: what to do **Today**, **This week** and **Later**, grouped into a few areas of work, every task with a
line on why it matters now. Claude advises, you decide: statuses, edits and dismissals you make by hand stick.

## How it works

1. **Read.** Claudo scans the top-level Claude Code transcripts in `~/.claude/projects/*/*.jsonl` from the look-back
   window (30 days by default): your prompts, the assistant's last reply, Claude Code's recap and session titles.
   Tool traffic and subagents are skipped. It adds activity per launch folder, the `memory/MEMORY.md` indexes of the
   active projects, and a read-only `git status` of the week's repos (branch, uncommitted files, unpushed commits).
2. **Summarize.** Sonnet writes a short note per session: what happened, its state, and what is left open. Notes are
   cached, so later runs only send new or changed sessions.
3. **Plan.** Opus reads the digest (the notes, the last 7 days in more detail, git, and the current board) and
   answers with areas, a focus line, tasks and the tasks it closes, each with a reason.
4. **Merge.** The answer is folded into the live board. Fields you set by hand are pinned and never overwritten;
   when Claude thinks a task you marked yourself is finished, it leaves a "✦ Done?" suggestion instead. Tasks the run
   doesn't mention stay as they are.

All model calls go through the local `claude` CLI (`claude -p` with a JSON schema, no tools, no MCP servers, no
saved session), so they run on your own Claude account. There is no API key to configure.

The planner's prompt is tuned to one working style: a founder who runs several lines of work at once through
parallel Claude Code sessions, with about 5 hours of their own attention a day (4–5 at weekends), weekends worked,
in a day that runs 07:00–23:00. Today is capped at that budget and the hours left; only what waits for someone
else's working hours moves to a weekday. The rules are in `Sources/ClaudoCore/PlanPrompt.swift`.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later, or the matching Command Line Tools)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in. Claudo looks for `claude` in
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.claude/local`.

## Install

```sh
./build.sh             # builds build/Claudo.app (release, ad-hoc signed)
./build.sh --install   # also copies it to /Applications and (re)launches it
```

Claudo lives in the menu bar only (no Dock icon). Click the icon, then **✦ Plan with Claude** to make the first board.

## Usage

**Left click** opens the popover: one list in three views, switched by the tabs on top.

- **Schedule** (⌘1): Today, then This week, then Later (folded), then what got done this week. Today starts with
  one card, the first thing in Claude's order, with its why, the next step and **Open session**, which resumes the
  source session in Terminal (`claude --resume`).
- **Projects** (⌘2): the same tasks grouped by area.
- **Priority** (⌘3): grouped by Urgent / High / Medium / Low.

The **filter** (⌘F) narrows every view: Today / This week / Later, areas, decisions or work, in progress, waiting,
high priority. The **status bar** at the bottom shows when the board was planned, a run's progress, the result,
errors and Undo. A plan from an earlier day says so and offers **Keep** or **✦ Plan today**.

| Action | Does |
|---|---|
| ⌘1 ⌘2 ⌘3 | Schedule / Projects / Priority |
| ⌘F | Filter |
| ⌘N | New task |
| ⌘R | Plan now |
| ⌘Z | Undo a removal |
| Click the status glyph (○ work, ◇ decision) | Done |
| ⌥-click the glyph | Cycle To Do → In Progress → Waiting |
| Right-click the glyph | Status menu |
| Hover a row | ▶ Open session, move it to Not today / Today / This week |
| Click a row / double-click its title | Details / rename |

**Right click** on the menu bar icon opens the menu: Plan Now, Look Back (7 / 14 / 30 days), Language, Plan Every
Morning at 9:00 (off by default), Launch at Login, Show Data Folder, Quit Claudo.

## Language

The interface is in English or Russian and follows the system language; **Language** in the right-click menu
switches it. The same setting is the language Claude writes the board in (task titles, notes, areas, the focus line)
and the session notes. With Match System and a system language other than English or Russian, the interface is
English and Claude writes in the system language. The prompts and the digest are always English. `claudo-cli`
follows the same setting unless given `--language`.

## Privacy

Everything stays on your Mac except what `claude -p` sends to Anthropic under your own Claude account: the digest
(excerpts of your prompts and the assistants' replies, session titles, project memory indexes, folder paths,
branch names and commit subjects) and the current board.

Claudo reads `~/.claude/projects` and runs read-only `git` commands (`--no-optional-locks`) in the repos you worked
in. It writes only to its data folder, `~/Library/Application Support/Claudo`:

| File | What |
|---|---|
| `board.json` | the board |
| `sessions-cache-sonnet.json` | Sonnet's session notes (`sessions-cache.json` holds Haiku's, from the CLI) |
| `last-digest.txt` | exactly what the last plan run read |
| `last-result.json` | the last run's raw answer |
| `last-run.json` | where the last run's time and money went |
| `run/` | the working folder `claude -p` runs in, so no project's `CLAUDE.md` loads |
| `resume.command` | the script **Open session** runs in Terminal |

Settings (view, filter, look-back, morning planning, language) are in the app's UserDefaults. Launch at Login
writes a LaunchAgent, `~/Library/LaunchAgents/site.spasskiy.claudo.plist`.

## Cost

Each plan run uses your Claude subscription. As a guide: a 30-day run with Opus at `xhigh` effort takes about
9 minutes and would cost about $4 at API list price; Sonnet's notes for a cold month (about 600 sessions) take
about 5 minutes and $1.90, and much less once the notes are cached. A 7-day look-back is faster and cheaper.
Planning every morning is off by default; nothing runs until you press Plan.

## CLI

`claudo-cli` runs the same pipeline without the UI. Commands marked † call `claude` and spend subscription quota.

```sh
swift build -c release
.build/release/claudo-cli [--data-dir <dir>] <command>
```

| Command | Does |
|---|---|
| `digest [--days N] [--compact off\|haiku\|sonnet]` | print what a plan run would send; `--compact` previews it from the session cache and calls nothing |
| `prompt [--language L]` | print the planner's system prompt and answer schema |
| `plan [model] [--days N] [--compact …] [--effort E] [--compact-effort E] [--language L]` † | run, merge into the board and save (Sonnet, no compaction and effort `xhigh` unless told otherwise) |
| `compact [--model haiku\|sonnet] [--effort E] [--days N] [--limit N] [--language L] [--dry-run]` † | summarize the uncached sessions into that model's cache; `--dry-run` only counts them |
| `cache [--model haiku\|sonnet] [--days N]` | what that model's session cache holds |
| `raw <session-id…> [--days N]` | the blocks the summarizer reads for these sessions |
| `board [file]` | print a board as the app lists it |
| `merge <board.json\|-> <answer.json> [--out file]` | fold a saved answer into a board offline |

`--data-dir` points every command at another data folder (a scratch one for experiments). `--language` takes a code
or a name (`ru`, `pt-BR`, `Russian`); by default it is the app's Language setting, else the system's language. Run
`claudo-cli help` for the full text.

## Development

```sh
swift build
swift test              # merge rules, views, digest, decoding, compaction, git state, the app's helpers
```

No test calls a model. `Fixtures/board-v4.json` and `Fixtures/board.json` are synthetic boards.

The app renders its popover to PNGs without a menu bar, for checking layouts in both appearances and languages:

```sh
.build/debug/Claudo --render /tmp/renders --board Fixtures/board-v4.json [--appearance dark] [--language ru] \
    [--group project] [--state running|stale|error|…] [--expand <task-id>] [--filter-open] [--full]
```

Without `--board` it reads your real board, read-only; it never writes. The flags are listed in
`Sources/Claudo/Render.swift`. How the planner, merge and UI are meant to behave: [DESIGN.md](DESIGN.md).
See [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change.

## Project layout

```
Sources/ClaudoCore/   model, session scanner, git state, digest, prompts, summarizer, planner, merge, storage
Sources/Claudo/       the menu bar app (SwiftUI + AppKit) and the debug renderer
Sources/claudo-cli/   the terminal harness
Tests/                ClaudoCoreTests (no model calls) and ClaudoTests (the app's pure helpers)
Fixtures/             synthetic boards for tests and renders
Resources/, tools/    the app icon and the script that draws it
build.sh, Info.plist  app bundle
```

## License

MIT, see [LICENSE](LICENSE).
