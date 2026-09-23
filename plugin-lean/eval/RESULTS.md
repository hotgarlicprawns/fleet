# fleet-lean eval results

Claude Code 2.1.280, model `sonnet`, 4 tasks × 2 arms × 3 reps per version
(v0/v1 were 1-rep smoke runs). Cost = Claude Code's own `total_cost_usd`.
Negative "saves" means fleet-lean cost **more** than plain Claude Code.

| version | what changed | lean tool calls | cost vs baseline | turns vs baseline | lean cheaper in |
|---|---|---|---|---|---|
| v0 (1 rep) | as shipped in 0.4.0 | **0** — model never used them | noise only | — | — |
| v1 (1 rep) | MCP `instructions` telling the model the tools exist (Claude Code defers MCP tools behind ToolSearch, showing only names) | used | **−80%** | −33% | 0/4 |
| v2 | `lean_edit` accepts any fragment like the built-in Edit (was whole lines only — the model's natural `find` failed, costing ~6 turns), `replaceAll`, grep-style text output instead of JSON | used | **−51%** | −50% | 3/12 |
| v3 | explicit "complete" footer (the old "10 of 20 files matched" read as truncated, so the model re-ran grep to double-check) + "don't re-verify" guidance | used | **−11%** | +2% | 2/12 |
| v4 (real repo) | same server as v3, but run with `--repo` against a real committed snapshot of the fleet repo itself (2 tasks: rename a real Swift property across 3 files, locate a real function by behavior) instead of the synthetic fixture | used | **+8%** aggregate, but **−18%** with one outlier excluded (see below) | −25% aggregate | 2/6 |

Raw rows: `results/v2.jsonl` (server 5e24ad528587), `results/v3.jsonl` and
`results/v4-repo.jsonl` (server 5fe3637dc681), plus full transcripts in
`results/v*-transcripts/` and the smoke runs in `results/early/`.
Re-summarize any of them with `node eval.js --summarize <file>`.

### v4 detail: real repo, real outlier

`node eval.js --repo <path-to-fleet> --reps 3` runs `REPO_TASKS` against
`git archive HEAD` of an actual repo (this eval harness's own source is
stripped from the snapshot first, since its task prompts mention the real
identifier under test and would otherwise contaminate the ground truth —
see `extractRepoSnapshot` in `eval.js`).

The raw aggregate says lean saved 8.4% — look at the per-task table instead
and it's the opposite: **lean's median cost is higher in both tasks**
(hudRename: $0.055 baseline vs $0.060 lean; hudLocate: $0.046 vs $0.059),
and lean only won 2 of 6 paired runs. The aggregate is entirely produced by
one baseline run (`hudRename` rep 2) hitting a `sed -i '' -E` quoting quirk
on this machine, falling back to individual Edit calls, and taking 14 turns
instead of ~4 — a shell environment fluke in the baseline arm, not anything
fleet-lean fixed. Excluding that one run: baseline $0.247 vs lean $0.292
over the remaining 5 pairs — **lean costs 18% more**, consistent with v2/v3.

## Conclusion

**fleet-lean does not save money against current Claude Code.** At its
best (v3, synthetic repo), it matches baseline on turns and still costs
~11% more. Re-run against a real repo — Fleet's own — v4 confirms it: once
a same-arm shell-quirk outlier is set aside, lean costs ~18% more there too.

Why, from the transcripts:

1. **The premise is out of date.** fleet-lean assumed Claude searches by
   Glob → Grep → Read-whole-file. Current Claude Code searches with
   `grep -rl` / `grep -n` through Bash, which returns a few hundred bytes,
   and renames with `grep -l | xargs sed` in one call. There are no avoided
   whole-file Reads to save.
2. **Deferred-tool tax.** Claude Code defers MCP tools, so every lean
   session pays an extra ToolSearch round trip plus the tool schemas in context.
3. With turns at parity (v3), that fixed overhead is the whole difference.

It follows that the "est. tokens avoided" figure in `/fleet-lean-report`
(file bytes a whole-file Read would have returned, minus what fleet-lean
returned) is **not** a real saving. It's measured against something Claude
Code doesn't actually do. The Fleet app no longer shows it, and the website
no longer claims savings.

What would change this verdict: tasks where built-in tools genuinely need
many turns (big multi-file refactors with a different edit per file, or
repos where grep output itself is huge). Add them to `TASKS` in `eval.js`
and re-measure before making any claim.
