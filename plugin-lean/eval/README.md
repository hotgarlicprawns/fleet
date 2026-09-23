# fleet-lean eval — does it actually save money?

`eval.js` answers that with real Claude Code runs, not estimates.

```bash
node eval.js --self-test            # checks the harness itself, costs nothing
node eval.js --reps 3               # 4 tasks x 2 arms x 3 reps = 24 real runs (~$1.5 list price, ~15 min)
node eval.js --repo /path/to/repo   # same idea, against a REAL repo's committed snapshot instead of the synthetic fixture
node eval.js --summarize results/<file>.jsonl
```

## Method

- **Same task, two arms.** Each task runs through headless Claude Code
  (`claude -p --output-format stream-json`) twice per repetition:
  `baseline` (no MCP servers) and `lean` (only fleet-lean). Model, tools,
  permission mode, prompt and fixture repo are identical. Irrelevant tools
  (web, subagents, scheduling) are disabled in both arms.
- **Fresh, deterministic repo per run.** A seeded generator builds the same
  20-file, ~200 KB JS project every time.
- **Strict verification.** After each run the whole tree must equal the
  expected tree byte-for-byte (or the answer must name the right file). A
  decoy constant catches over-editing.
- **Savings count only when both arms passed.** A cheap wrong answer never
  counts as a saving.
- **Real numbers only:** `total_cost_usd`, token usage and turns as reported
  by Claude Code itself. `total_cost_usd` is list-price API cost; on a
  subscription it's the equivalent usage, not a charge.
- **Fairness details:** arm order alternates each rep so prompt-cache warmth
  doesn't favor one side; the server under test is snapshotted at start and
  its hash recorded in every row; `XDG_CONFIG_HOME` is isolated so runs never
  touch your real savings data; full transcripts are saved next to each
  results file for inspection.

Tasks (synthetic fixture): `rename` (identifier across 10 files, 26 sites),
`retry` (one constant in a large file, with a same-valued decoy next to it),
`prefix` (string literal across a directory tree), `locate` (find a function
by what it does, not its name).

Tasks (`--repo` mode, `REPO_TASKS`): `hudRename` (a real Swift property
renamed across 3 real files), `hudLocate` (find a real function by behavior).
`--repo` archives `git HEAD` of the given repo (read-only against it — never
touches its worktree) and strips this eval's own source from the snapshot
first, since a task prompt naming a real identifier would otherwise match
inside the eval tool too and contaminate the ground truth. The target repo
must be committed clean (dirty worktree is refused) so the archived snapshot
matches what `expect()` was written against.

## Results

See `RESULTS.md` for every version measured so far and what changed between them.
