# model-bench — Opus vs. Sonnet, real cost per completed task

`model-bench.js` (same directory) answers a specific question: when building
a Fleet feature, does Opus's stronger one-shot reasoning make up for its
higher per-token price, or is Sonnet cheaper even after the extra pass it
sometimes needs? Method is the same discipline as `eval.js`: real headless
Claude Code runs, strict verification (exact tree match, or for the
`feature` task — writing new code — the produced function is actually
`require()`d and run against test vectors in a subprocess), cost is Claude
Code's own `total_cost_usd`. Only passing runs count toward a cost figure.

```bash
node model-bench.js --self-test
node model-bench.js --models opus,sonnet --tasks rename,retry,locate,feature --reps 2
node model-bench.js --summarize results/model-bench-<file>.jsonl
```

## Result (2026-09-25, `claude-opus-5-5` vs `claude-sonnet-5`, 4 tasks × 2 reps)

Raw data: `results/model-bench-2026-09-25T10-36-21-307Z.jsonl`, transcripts
in the matching folder.

All 16 runs passed (no correctness difference in this sample). Average cost
per successful run:

| task | opus | sonnet | cheaper |
|---|---|---|---|
| rename (identifier across 10 files) | $0.073, 4.0 turns | $0.068, 5.5 turns | close — noisy, opus won 1 of 2 reps |
| retry (one constant, decoy nearby) | $0.135, 4.0 turns | $0.057, 5.5 turns | **sonnet, clearly** (consistent both reps) |
| locate (find function by behavior) | $0.082, 4.0 turns | $0.057, 4.5 turns | sonnet — but noisy (opus won 1 of 2 reps) |
| feature (write new code, run against test vectors) | $0.061, 4.0 turns | $0.045, 3.5 turns | **sonnet, clearly** (both reps) |

**Sonnet was cheaper in every task's average, and in 6 of 8 individual runs.**
Opus consistently used far fewer *tokens* (its one-shot instinct is real —
e.g. `rename`: 30K vs 98K median tokens) but its per-token price is high
enough that the token savings don't cover the gap except occasionally.
Turns were close (Opus usually 4, Sonnet usually 4–6) — Opus's edge is real
but small on tasks this size.

**Reading this correctly:** n=2 reps per cell is a small sample — `retry`
and `feature` show a consistent, non-noisy gap; `rename` and `locate` are
close enough that either model could win on a given run. This is not "Opus
is never worth it" — it's "for routine, well-specified edits and small
feature additions like these, Sonnet is the safer default, and Opus's
premium doesn't reliably pay for itself." A genuinely ambiguous or
architecturally tricky task (the kind where Sonnet might need real
back-and-forth, not just an extra pass) isn't represented in this task set
and could tip the other way — re-run with `--tasks` pointed at something
harder before trusting this for that case.

## What this does NOT answer

How many tokens/calls fit in your Pro or Max plan before you're rate
limited. That's a live, Anthropic-side rolling-window measurement, not a
fixed conversion Fleet can precompute — Fleet already surfaces the real
number (the `rl5h`/`rl7d` chips in the top bar, per account), rather than
guessing at a formula for it.
