# Contributing

Issues and pull requests are welcome. Before you send one:

- `swift build --build-tests` has no warnings and `swift test` passes. No test may call a model.
- Never point a plan or compaction run at your real data while developing: `claudo-cli --data-dir <scratch dir>`
  keeps the board and caches apart, and `plan` / `compact` spend your Claude subscription. `digest`, `prompt`,
  `board`, `merge`, `cache`, `raw` and `--render` call nothing.
- A UI change comes with renders before and after (`Claudo --render <dir> --board Fixtures/board-v4.json`), in light
  and dark (`--appearance dark`), in English and Russian (`--language ru`). The rules in [DESIGN.md](DESIGN.md) › UI
  hold: nothing moves under the pointer, labels that change keep their width, the popover has one fixed size.
- Every string a person can see goes through `L("English", "Русский")` or `plural`. Russian should read like a
  native macOS app; keep to the terms already used in the interface.
- A change to the prompts, the digest, the merge rules or the model updates DESIGN.md and its tests (DigestTests,
  MergeTests, MergeDayTests, ViewTests). A summarizer prompt or schema change bumps `SessionSummarizer.revision`.
- board.json stays compatible both ways: new fields are optional, keys are never renamed.
- Style: 4-space indent, lines up to ~120 characters, short `///` comments that say why.
