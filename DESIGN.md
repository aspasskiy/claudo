# Claudo — design

A menu bar task manager where Claude is the planner. The board persists between runs: Claude *advises* (adds
tasks, closes finished ones, reweighs areas, writes the week's focus), the owner *decides* (statuses, edits and
dismissals stick). Every text has a length cap. The test for every change: does the owner know what to do in
five seconds?

## Model (Sources/ClaudoCore/Model.swift — the contract)

- **Day** — a local calendar day, "yyyy-MM-dd" in JSON, Gregorian whatever the system calendar; arithmetic is
  zone-free (no DST skips).
- **Area** — a line of work. `symbol` (an SF Symbol from `Area.symbols`), `color` (`AreaColor`), `weight`
  focus | active | background | parked, `status` (≤ 80: what is going on), `outcome` (≤ 70: what "done this week"
  looks like, may be empty), `attention` (% of the owner's 7-day attention by topic, the planner's estimate).
  `Area.inbox` is implicit: tasks the owner adds without an area live there until Claude files them.
- **TaskItem** — `status` todo | doing | waiting | done | dropped, `priority` urgent | high | medium | low, `when`
  today | week | later, `kind` task | decision (a yes/no only the owner can make, minutes), `estimate` (hours of the
  owner's attention), `rank` (Claude's order), `why` (≤ 80, the stake), `due` (a deadline, an appointment, or a
  waiting task's check-back day), `sessionId` + `cwd` (resume the source session), `origin` claude | user, `isNew`
  (added by the last run, not yet seen), `pinned` (fields the owner set by hand), `advice` (Claude's pending
  suggestion on a pinned task), `closedReason`. Day bookkeeping: `plannedFor` (the day it was last put on Today;
  earlier = carried over), `todaySince` (the first day of its stretch on Today), `whenSetOn` (the owner's Today /
  not-today choice binds that day's plans only; Later sticks: `holdsWhenPin(on:)`), `snoozedUntil` ("Not today" on
  a task that is on Today only because it falls due; the deadline stays).
- **Board** — `focus` (≤ 140), areas, tasks, plan metadata (`plannedAt`, `model`, `sessionCount`, cost), `keptOn`
  (the owner kept an older plan's Today for that day; `planIsStale` is then false). Every field added since
  version 3 is optional in JSON, so older boards load unchanged; `currentVersion` is 4.
- **Owner actions** are `Board` mutating methods (`setStatus`, `setWhen`, `setDue`, `notToday`, `keepForToday`,
  `add`, `remove`, `acceptAdvice`…); each pins the field it touches.
- **PlanResult** — what one run returns. `Merge.merge` folds it into the *live* board: a run takes minutes and
  overlaps the owner's edits, so it never merges into the snapshot it started from.

### Views

Every open task is in exactly one place, by when it is for:

- `today(now:)` — open with when = today, or due by today and not snoozed (`isOnToday`), plus tasks closed today.
  Due and overdue first unless today's plan placed them, then the plan's rank.
- `upcoming(.week, now:)` / `upcoming(.later, now:)` — open, not on Today, by `when`; priority → rank → age.
- `doneThisWeek(now:)` — done in the last 7 days, newest first; `closedThisWeek(now:)` adds the dropped ones
  (`claudo-cli board` and `merge` list those, with their reasons).

Status (doing, waiting) and kind (decision) are marks on rows and filter parts, never places. A waiting task comes
onto Today by itself on its check-back day (its `due`). Tests: ViewTests (partition, carry-over, pins, snooze,
keep, DST).

## Planner (Sources/ClaudoCore)

**Pipeline** (`Planner.run`, reporting progress): scan sessions (`Sessions.scan`) and repos (`GitState.scan`) →
the summarizer notes uncached sessions (`Compactor`) → digest → one `claude -p` call (`ClaudeCLI.ask`) with the
system prompt and `answerSchema` → decode (`PlanDecoding`). The caller merges the result with `Merge.merge` into
the board as it is by then: `Store.refresh` into the live one, `claudo-cli plan` into a fresh load. The app plans
with Opus and compacts with Sonnet; `Planner`'s code defaults (Sonnet, compaction off) serve the CLI. Both calls
pass `--effort` explicitly (`Planner.effort`, `compactEffort`, default xhigh): `claude -p` would otherwise inherit
the owner's interactive effort level. The plan call times out after 15 min. Each run leaves `last-digest.txt`
(exactly what the model read), `last-result.json` (its raw answer) and `last-run.json` (each stage's seconds and
claude's report: duration, usage, cost) in the data dir.

**Language.** Prompts and the digest are English whatever the board is written in. `Planner.language` (a code or
a name, normalized by `PlanLanguage.name`: "ru", "ru-US", "русский" → "Russian"; a script other than the
language's usual one stays: "zh-TW" → "Chinese, Traditional", "sr-Latn" → "Serbian (Latin)") is the language the
model writes every text field and the session notes in. The app passes its Language setting
(`PlanLanguage.forSetting`); `claudo-cli` reads the same setting unless given `--language`; `Planner`'s own default
is the system's language (`PlanLanguage.system`). Names and titles already on the board stay; one in another
language may be translated, never the title of an owner's task.

**Sessions.** Top-level transcripts in `~/.claude/projects/*/*.jsonl` (no subagents): the owner's prompts (pastes
unwrapped, words queued while an agent works included), the last assistant reply, the session title, and Claude
Code's recap ("away summary") when it came after the last prompt. Tool traffic is skipped.

**Digest**, in order, within 460k characters (the oldest sessions are dropped first):
- the first line: now, the weekday, weekend or not, hours left in the owner's day (07–23);
- **Current board** — the focus, areas, open tasks grouped by area with their facts (status, when, priority,
  estimate, kind, "from the owner", why, due, created, "on Today since … (day N)", carried over, snoozed, the last
  activity of its session; `*` marks a pinned field, a `when` star only while the choice binds), and what was closed
  in the window, so it isn't suggested again;
- **Repository state** — git of the week's repos: branch, uncommitted, unpushed (with the unpushed commits'
  subjects), last commit; read-only, `--no-optional-locks`, 3 s per call, ≤ 20 repos;
- **Activity by launch folder** — labeled "the topic may differ": work on one project often starts in another's
  folder;
- **Project memory** — the `memory/MEMORY.md` indexes of the folders touched, newest first, ≤ 25k;
- **Sessions** — the last 7 days in detail (prompts, the last reply, the recap, "Owner's last words", "running now"
  while an agent is still on the last prompt, CUT OFF when it got no reply); older ones in brief, or as one line
  with a note (+ the first open item at importance ≥ 2). Session ids appear by their first 8 characters and are
  resolved back on decode.

**Prompt rules** (`Planner.systemPrompt(language:)`; DigestTests check). The prompt is tuned to one working style:
a founder running several lines of work through parallel Claude Code sessions, about 5 h of their own attention a
day (~4–5 at weekends), weekends worked; the digest counts the day's hours left to 23:00 (`dayEndHour`). It names
no project or person. The rules:
- *Reconcile first*: each open task is checked against git and the sessions since it was created — done, merged,
  pushed, decided → closed with the fact; the owner's "drop it" / "stop" closes a topic and beats git; things the
  owner did outside the sessions become a decision "… sent?"; a batch the owner closed whole is checked part by
  part.
- *Areas*: 3–7, by attention by topic (not by folder), "Other" ≤ ~10%; focus = ≥ ⅓ of the attention or the owner's
  stated goal; money without the owner's attention is active, not focus. Existing ids, names, symbols and colors
  stay.
- *Today*: in execution order by stake (losing money or customers → the focus goal's blocker → its next step →
  deadlines ≤ 72 h → decisions); 1–2 deep blocks from focus areas, decisions only with a stake, dated items
  ≤ 72 h; within the owner's usual day (~5 h) and the hours left. What waits for the other side's working hours
  moves to the next weekday with a due. A carried-over task stays only with a fresh reason.
- *Urgent* only by rule (payment or login broken, also a fix not live while ads or customers already go there;
  prod down; a paying customer blocked; legal, tax or bank ≤ 48 h; an unplanned spend), with fresh evidence, ≤ 3 on
  the board. *Waiting* only with a trace that the ball left. ≤ 8 decisions, ≤ 30 open tasks, no micro-steps.
- *Evidence*: numbers carry the date they were measured; Claude Code's recap is the agent's report, not a fact and
  not a task; invent nothing; don't re-suggest closed tasks; don't retell the assistant's working rules from memory.
- Every open task on the board is returned in `tasks` or in `closed`. A final self-check closes the prompt.

## Merge rules (Merge.swift; MergeTests, MergeDayTests)

1. A new id → insert, origin claude, `isNew`, createdAt = now. Dedupe first: a normalized title (lowercased letters
   and digits) equal to a board task's, open or closed within 30 days, is that task — updated, never resurrected.
2. An existing id → every field not in `pinned` is updated; the title of an owner's task never changes. Done and
   dropped tasks are never reopened.
3. A status in `tasks` applies only when the status isn't pinned.
4. A `closed` entry on an open task: status not pinned → status, completedAt, closedReason; pinned → `advice`
   (status + reason) instead.
5. Open tasks the run doesn't mention stay as they are.
6. Areas are replaced by the result's, but existing ids keep their color and symbol; an area missing from the result
   survives as parked while it has open tasks. Attention is clamped to 0–100.
7. Every text is clipped to its cap with "…" (the schema asks, nothing enforces it).
8. Done and dropped tasks older than 30 days (the longest look-back) are pruned. Ranks = order in `tasks`.
9. Board metadata (focus, plannedAt, model, sessionCount, cost) comes from the result; `keptOn` resets.
10. Why and kind come from the plan; due unless pinned.
11. Expired `when` pins are released for every open task before the run applies.
12. Today is dated to the plan's day: `plannedFor` set, `todaySince` kept across a stretch, both cleared off Today.
    A Today task without a `plannedFor` gets its old plan day first, so an unmentioned one reads as carried over.
13. A short session id keeps the known full link; a run that names none keeps the old one.
14. `snoozedUntil` is never touched.

## Compaction and cache

A month is ~600 sessions and ~450k characters of raw digest, half of them one-off errands. A summarizer pass
makes the plan's input smaller and sharper.

- **Mode** `CompactMode`: off | haiku | sonnet. The app always uses Sonnet; the CLI takes `--compact` and
  `compact --model` for experiments. On a full month the two wrote notes of similar quality in blind comparison;
  Sonnet was faster (~5 vs ~12 min) and terser, Haiku cheaper (~$0.36 vs ~$1.90 at list price).
- **SessionSummarizer** (`claude -p --model haiku|sonnet`): batches of ~40k characters of raw blocks, concurrency 3,
  5 min per batch (10 for a bigger model). Schema: per session a summary (≤ 300), state, importance 0–4, and up to
  3 open items (≤ 120), the owner's own steps first, their "stop" / "drop it" quoted. Concrete: numbers, dates,
  files, ids, commit hashes. Unknown or missing ids fall back to the raw block.
- **Cache**: one file per model in the data dir — `sessions-cache.json` for Haiku, `sessions-cache-<model>.json`
  for another — so a Haiku note never stands in for Sonnet's and switching back sends nothing again. An entry is
  valid while the session's end, its typed-prompt count (words queued mid-turn don't count) and the note's version
  match. The version is `<model>-<revision>`; `SessionSummarizer.revision` is s4, and s1–s3 notes are still
  accepted (they differ only in emphasis and language, and notes are only the planner's input).
- **Digest with notes**: a noted recent session renders as its header, the note and "Open: …"; older noted sessions
  as one line (date · folder · title · prompts · state · importance), plus the first open item at importance ≥ 2.
  Without a note, the raw block as before.

## Storage

`BoardStore` — `board.json` in the data dir (`Paths.support`, ~/Library/Application Support/Claudo; tests and
`claudo-cli --data-dir` point it elsewhere). Saved on every mutation (debounced), atomically. An unreadable board is
copied aside to `board.unreadable-<time>.json` before anything can overwrite it. Each `claude -p` call runs in
`<data dir>/run`, so no project's CLAUDE.md loads, and leaves no session behind. The app's settings are
UserDefaults: `grouping`, `filter`, `autoMorning`, `lookback`, `language`.

## UI (Sources/Claudo)

Popover 420 wide, **one fixed size**: header (`Metrics.headerHeight` 44) + one list (`Metrics.listHeight` 520,
scrolls) + status bar (`Metrics.statusBarHeight` 34). A chip, an expanded row or an undo never resize it. The first
screen shows all of Today and the top of This week.

**Principles**
- **One list, placed by one thing**: when a task is for (`when` + `isOnToday`), as in Things or Todoist. Status
  and kind are marks and filter parts, never places.
- **Nothing moves under the pointer.** Hover controls are overlays or reserved space at opacity 0; labels that
  change keep their width; a tab's weight never changes with its state.
- **One accent.** Coral is Claude's (plan, NEW, advice, focus, run progress); no area wears it (an area colored
  coral draws rose). Status colors live in the status glyphs only; red only for overdue and urgent; area colors
  only as a 6 pt dot on rows and the symbol on area headers. Facts are plain text, not chips.
- **Three grays.** `.secondary` for what is read (whys, dates, estimates), `Palette.faint` (≈ 3:1) for counts and
  shares, `.tertiary` only for placeholders. Coral text uses `Palette.coralText`.
- **One left edge**: containers at 8 pt, text at 18 pt, in the header, list and status bar.

**Header**: the three views as tabs — Schedule · Projects · Priority, each a symbol and its name (⌘1–3; the current
one in a filled capsule) — then the filter button (⌘F) and `+` (⌘N). No brand or date: the date heads Today's
group. While a filter is on, one line of removable chips and Clear takes its 30 pt from the list.

**Views** (`Store.grouping`: date | project | priority) group the same rows three ways. **Schedule** (default):
Today, This week, Later (folded), Done this week. **Projects** (`ListGroups.byArea`): areas by weight, symbol +
name + count as the header, the inbox last. **Priority** (`byPriority`): Urgent, High, Medium, Low. Inside a
project or priority group rows keep the list's order (Today's in plan order, then This week's, then Later's) and
say their horizon on the right: Today in amber, Later in gray (the row a step quieter), This week unmarked. A row
drops what its group says (the area dot by project, "!" by priority) and the estimate. No lead card, focus line or
Later fold outside Schedule.

**Filter** (`BoardFilter`, decoded key by key so an older saved one still reads): When (Today / This week / Later
with counts, any number at once; all three = none), Areas (multi; each tooltip carries the area's status, share and
outcome), Show All / Decisions / Work, Only In Progress / Waiting, High priority (urgent + high). Every part
combines and narrows every view and the panel's counts; the tray and the status bar ignore it. Picking horizons
only (`narrows` false) keeps Today's lead card; any other part makes Today plain rows.

**Status bar** (`BarState.resolve`): the one place for app state, by priority — error (plain words via
`Fmt.failure`, raw text in the tooltip, Retry for a failed plan) › undo ("Removed … Undo ⌘Z", 5 s) › running
(spinner, stage, elapsed; a 2 pt coral line on its top edge, a fraction while the summarizer runs) › result
("✦ 2 new · 1 closed", 4 s) › stale ("↻ 5 from Saturday's plan · 11 sessions since" · Keep · ✦ Plan today) › idle
("Planned 2h ago · ✓ 31 this week" · ✦ Plan, Re-plan after ≥ 5 sessions since) › never planned. ⌘R plans from
any state.

**Schedule** (`BoardList`): Today → This week → Later (folded under its header; open while the filter picks it) →
Done this week (folded; "Done today" while Today alone is picked). A group header is 13 semibold with a faint count;
no sub-headers. This week and Later step aside when empty unless the filter picks them; picked alone, a group drops
its header (the chip says it).

**Today** (`board.today(now:)`, split by `TodayPlan`): the header with the date and "5 left · ≈3h"; the week's
focus in one line (click unfolds); the **lead card** (raised; coral edge when new): the first open row in plan
order, any kind — the whole why, two lines of the note, ▶ Open session; then the rest in plan order; waiting rows
whose check-back day has come last. Under a filter there is no card. Nothing open is one quiet line.

**This week** (`Store.weekTasks`) and **Later** (`laterTasks`): flat, ordered by priority → rank → age. This week's
rows are two lines like Today's (area dot + why); Later's are one line.

**Row**: status glyph (circle = work, diamond = decision; click = done, ⌥-click cycles To Do → In Progress →
Waiting, right-click = menu), title 13 regular (lead 14 semibold), at most two facts on the right (⚑ deadline or
↩ check-back, estimate; "!" for urgent; a due-today date hidden on Today), why in one line after the area dot (full
in the tooltip and on expand). NEW = a 5 pt coral dot in the margin. Hover: ▶ and one step along the horizon over
the title's end — Not today on Today, Today on This week, This week on Later. Expanded: the note, one control row
(status, When, priority), dates and icon actions (▶, copy, rename, delete). Open session writes
`resume.command` (`claude --resume <id>` in the task's folder) and opens it in Terminal.

**Quick add**: `+` or ⌘N → an inline field on top of the first group listed, in the one area the filter names,
else the inbox. Enter adds, Esc cancels; Move to in the row's menu changes the area later.

**Tray icon**: a ball of yarn + the open count: two wound strands plus one crossing strand per task still open
today (up to 5), so it untangles as tasks get done; ✦ inside while planning; a coral dot for unseen NEW tasks; a
stale plan fades the ball and grays the count. The tooltip starts "Next: <lead title>". `Store.now` moves on wake
and on a calendar-day change (and reloads the board, recounts sessions), so the icon is right in the morning
without opening the popover.

**Right-click menu**: Plan Now, Look Back (`Store.lookbacks`: 7 / 14 / 30 days), Language, Plan Every Morning at
9:00 (`Store.morningHour`; off by default), Launch at Login (a LaunchAgent, label `site.spasskiy.claudo`), Show
Data Folder, Quit Claudo. No model choice: the app plans with Opus and compacts with Sonnet.

**Localization** (Localization.swift): the interface is English or Russian. `AppLanguage` — system | english |
russian, picked under Language and kept in UserDefaults `language` — sets `Loc.russian`; Match System is Russian
when the system's first preferred language is. Every visible string goes through `L("English", "Русский")`, counts
through `plural(n, one, many, ru:)` (three Russian forms), dates through formatters on `Loc.locale`, re-created
when the language changes. `AppLanguage.planLanguage` is the language the planner writes in: English or Russian
when picked, the system's language under Match System (it may be one the interface doesn't speak); the mapping is
`PlanLanguage.forSetting`, which `claudo-cli` shares. Russian runs longer: labels keep fixed widths in both
languages, and renders are checked in both.

## Debug render

`Claudo --render <dir> [--board <fixture.json>] [--appearance dark] [--language ru] [--group date|project|priority]
[--scope today,week,later] [--planned-ago <hours>] [--sessions-since <n>] [--expand <id>] [--hover <id>]
[--state empty|running|summarizing|planning|result|error|undo|stale|replan|never] [--filter-area <id,id>]
[--filter-kind decision|task] [--filter-status doing,waiting] [--filter-important] [--filter-open]
[--show-later] [--full] [--name …]` (the full list in Render.swift) writes PNGs of the popover and never writes the
board: without `--board` it reads the real one read-only. The board is shifted to read as planned `--planned-ago`
hours ago (default 2). Each run prints the tray tooltip and the list's content height against the list's.
Fixtures: `Fixtures/board-v4.json` and `Fixtures/board.json` (an older-format board), both synthetic.

## Known limits

- Attention shares are the model's estimate by topic, not computed in code; a launch folder used for errands still
  pulls its project's share up.
- A plan made late in the evening is dated that day with little time left; only a prompt line keeps carried Today
  tasks from being dropped to fit.
- The planner tends to keep an old task's title and premise when it can't prove it wrong; the owner's tick or
  Remove settles it.
