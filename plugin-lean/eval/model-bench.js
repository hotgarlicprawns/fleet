#!/usr/bin/env node
'use strict';

/*
 * model-bench — which model should you actually use to build a feature:
 * Opus or Sonnet? Answered with real headless Claude Code runs, not a
 * guess about "Opus is smarter but pricier."
 *
 * Same discipline as eval.js: identical task, identical tools/permissions,
 * only the model changes. Verification is strict (exact tree match, or —
 * for the `feature` task, which generates new code — the produced function
 * is actually REQUIRED and RUN against real test vectors in a subprocess,
 * not text-matched). A model that answers wrong doesn't count as "cheap."
 *
 * This does NOT tell you how many tokens fit in your Pro/Max plan — that's
 * a live, Anthropic-side rolling-window measurement Fleet already surfaces
 * honestly (the rl5h/rl7d chips), not something derivable from a fixed
 * formula. This tells you, for a given kind of task: does the pricier
 * model actually cost more once you account for Sonnet needing a second
 * pass, or does Sonnet's per-token discount still win?
 *
 * Usage:
 *   node model-bench.js --self-test
 *   node model-bench.js --models opus,sonnet --tasks rename,retry,locate,feature --reps 2
 *   node model-bench.js --summarize results/<file>.jsonl
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const E = require('./eval.js');

const HERE = __dirname;
const RESULTS_DIR = path.join(HERE, 'results');

// ---------------------------------------------------------------------------
// the `feature` task: build something NEW, not edit something existing.
// Correctness is checked by actually running the code against real test
// vectors — the strongest verification available, stronger than a text
// diff — so it's a fair test of one-shot capability, not phrasing luck.
// ---------------------------------------------------------------------------

const RANGE_VECTORS = [
  { in: [[1, 3], [2, 6], [8, 10], [15, 18]], out: [[1, 6], [8, 10], [15, 18]] },
  { in: [], out: [] },
  { in: [[1, 4], [4, 5]], out: [[1, 5]] },       // touching counts as overlap
  { in: [[5, 10]], out: [[5, 10]] },
  { in: [[8, 10], [1, 3], [2, 6]], out: [[1, 6], [8, 10]] }, // must sort first
];

function verifyFeature(dir) {
  const target = path.join(dir, 'src', 'utils', 'ranges.js');
  if (!fs.existsSync(target)) return { pass: false, problems: ['src/utils/ranges.js was never created'] };
  // Actually require + run it, in a subprocess (never eval() untrusted code
  // in this process). One assert per vector; syntax errors and thrown
  // exceptions are caught and reported, not silently treated as a pass.
  const script = `
    const assert = require('assert');
    const m = require(${JSON.stringify(target)});
    const fn = m.mergeOverlappingRanges;
    if (typeof fn !== 'function') { console.log('FAIL: mergeOverlappingRanges is not exported as a function'); process.exit(1); }
    const vectors = ${JSON.stringify(RANGE_VECTORS)};
    for (const v of vectors) {
      let got;
      try { got = fn(v.in); } catch (e) { console.log('FAIL: threw on input ' + JSON.stringify(v.in) + ': ' + e.message); process.exit(1); }
      if (JSON.stringify(got) !== JSON.stringify(v.out)) {
        console.log('FAIL: input ' + JSON.stringify(v.in) + ' expected ' + JSON.stringify(v.out) + ' got ' + JSON.stringify(got));
        process.exit(1);
      }
    }
    console.log('PASS: all ' + vectors.length + ' vectors correct');
  `;
  const r = spawnSync(process.execPath, ['-e', script], { encoding: 'utf8', timeout: 10_000 });
  const out = (r.stdout || '') + (r.stderr || '');
  return { pass: r.status === 0 && out.includes('PASS'), problems: r.status === 0 ? [] : [out.trim().slice(0, 300)] };
}

const MODEL_TASKS = {
  ...E.TASKS,
  feature: {
    prompt: 'Create a new file src/utils/ranges.js exporting a function `mergeOverlappingRanges(ranges)`. `ranges` is an array of [start, end] integer pairs (start <= end), not necessarily sorted. Return a new array of merged, non-overlapping [start, end] pairs sorted ascending by start — two ranges that touch (one\'s end equals the other\'s start) or overlap must be merged into one. Export it as `module.exports = { mergeOverlappingRanges }`. Do not modify any other file.',
    run: verifyFeature,
  },
};

// A small, generic-service fixture is overkill for a from-scratch generation
// task and would just add irrelevant read cost — use a minimal repo instead.
function minimalFixture() {
  return {
    'package.json': JSON.stringify({ name: 'acme-commerce', version: '1.0.0', private: true }, null, 2) + '\n',
    'README.md': '# acme-commerce\n',
  };
}

function verify(task, dir, original, resultText) {
  if (task.run) return task.run(dir);
  return E.verify(task, dir, original, resultText);
}

// ---------------------------------------------------------------------------

function runOnce({ taskName, model, rep, tmpRoot, transcriptDir }) {
  const task = MODEL_TASKS[taskName];
  const dir = fs.mkdtempSync(path.join(tmpRoot, `${taskName}-${model}-`));
  const original = task.run ? minimalFixture() : E.buildFixture();
  E.writeTree(dir, original);
  spawnSync('git', ['init', '-q'], { cwd: dir });

  const xdg = path.join(tmpRoot, `xdg-${model}-${rep}`);
  fs.mkdirSync(xdg, { recursive: true });
  const mcp = path.join(tmpRoot, `mcp-empty.json`);
  if (!fs.existsSync(mcp)) fs.writeFileSync(mcp, JSON.stringify({ mcpServers: {} }));

  const args = ['-p', task.prompt, '--model', model, '--output-format', 'stream-json', '--verbose',
    '--strict-mcp-config', '--mcp-config', mcp, '--setting-sources', 'project',
    '--permission-mode', 'bypassPermissions', '--disallowedTools', ...E.DISALLOWED];

  return new Promise(resolve => {
    const started = Date.now();
    const child = spawn('claude', args, { cwd: dir, env: { ...process.env, XDG_CONFIG_HOME: xdg }, stdio: ['ignore', 'pipe', 'pipe'] });
    let buf = '', result = null, tools = {};
    const transcript = transcriptDir ? fs.createWriteStream(path.join(transcriptDir, `${taskName}-${model}-rep${rep}.jsonl`)) : null;
    const timer = setTimeout(() => child.kill('SIGKILL'), 15 * 60 * 1000);
    child.stdout.on('data', d => {
      if (transcript) transcript.write(d);
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.type === 'assistant') for (const c of (m.message && m.message.content) || [])
          if (c.type === 'tool_use') tools[c.name] = (tools[c.name] || 0) + 1;
        if (m.type === 'result') result = m;
      }
    });
    child.stderr.on('data', () => {});
    child.on('close', () => {
      clearTimeout(timer);
      if (transcript) transcript.end();
      const v = result ? verify(task, dir, original, result.result) : { pass: false, problems: ['no result (crash/timeout)'] };
      const u = (result && result.usage) || {};
      const canonicalModel = result && result.modelUsage ? Object.keys(result.modelUsage)[0] : null;
      fs.rmSync(dir, { recursive: true, force: true });
      resolve({
        ts: new Date().toISOString(), task: taskName, model, canonicalModel, rep,
        pass: v.pass, problems: v.problems,
        costUSD: result ? result.total_cost_usd : null,
        turns: result ? result.num_turns : null,
        durationMs: Date.now() - started,
        inputTokens: u.input_tokens || 0, outputTokens: u.output_tokens || 0,
        cacheWriteTokens: u.cache_creation_input_tokens || 0, cacheReadTokens: u.cache_read_input_tokens || 0,
        tools, isError: result ? !!result.is_error : true,
      });
    });
  });
}

// ---------------------------------------------------------------------------

function summarize(rows) {
  const lines = [];
  const models = [...new Set(rows.map(r => r.model))];
  const tasks = [...new Set(rows.map(r => r.task))];
  const canon = m => rows.find(r => r.model === m && r.canonicalModel)?.canonicalModel || m;
  lines.push(`models: ${models.map(m => `${m} (${canon(m)})`).join(', ')}   runs: ${rows.length}`);
  lines.push('');
  lines.push('task      model   pass   median $   median turns  median tokens');
  for (const t of tasks) {
    for (const m of models) {
      const rs = rows.filter(r => r.task === t && r.model === m);
      if (!rs.length) continue;
      lines.push(`${t.padEnd(9)} ${m.padEnd(7)} ${`${rs.filter(r => r.pass).length}/${rs.length}`.padEnd(6)} ` +
        `${E.median(rs.map(r => r.costUSD || 0)).toFixed(4).padStart(9)}  ${String(E.median(rs.map(r => r.turns || 0))).padStart(12)}  ` +
        `${String(Math.round(E.median(rs.map(E.totalTok)))).padStart(13)}`);
    }
  }
  lines.push('');
  lines.push('Only over PASSING runs (a wrong answer is never "cheap") — the real question');
  lines.push('this answers: for this kind of task, does the pricier model actually cost');
  lines.push('more once you account for retries, or does it one-shot enough to win?');
  for (const t of tasks) {
    lines.push('');
    lines.push(`  ${t}:`);
    for (const m of models) {
      const rs = rows.filter(r => r.task === t && r.model === m && r.pass);
      const all = rows.filter(r => r.task === t && r.model === m);
      if (!all.length) continue;
      if (!rs.length) { lines.push(`    ${m.padEnd(7)} 0/${all.length} passed — no cost figure (a failing run is never a bargain)`); continue; }
      const costPerSuccess = E.sum(rs.map(r => r.costUSD)) / rs.length;
      lines.push(`    ${m.padEnd(7)} ${rs.length}/${all.length} passed, avg $${costPerSuccess.toFixed(4)}/success, ` +
        `avg ${(E.sum(rs.map(r => r.turns)) / rs.length).toFixed(1)} turns`);
    }
  }
  const fails = rows.filter(r => !r.pass);
  if (fails.length) {
    lines.push('');
    lines.push('Failures:');
    for (const f of fails) lines.push(`  ${f.task}/${f.model}/rep${f.rep}: ${f.problems.join('; ')}`);
  }
  lines.push('');
  lines.push('$ = Claude Code\'s own total_cost_usd (list-price API cost; on a subscription this is the equivalent value, not a charge).');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------

function selfTest() {
  let ok = true;
  const check = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) ok = false; };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'model-bench-self-'));
  try {
    // correct implementation must pass every vector
    const good = path.join(tmp, 'good');
    E.writeTree(good, { 'src/utils/ranges.js': `
      function mergeOverlappingRanges(ranges) {
        const s = [...ranges].sort((a, b) => a[0] - b[0]);
        const out = [];
        for (const [start, end] of s) {
          const last = out[out.length - 1];
          if (last && start <= last[1]) last[1] = Math.max(last[1], end);
          else out.push([start, end]);
        }
        return out;
      }
      module.exports = { mergeOverlappingRanges };
    ` });
    check(verifyFeature(good).pass, 'a correct implementation passes all vectors');

    const missing = path.join(tmp, 'missing');
    fs.mkdirSync(missing, { recursive: true });
    check(!verifyFeature(missing).pass, 'a missing file fails, not silently skipped');

    const wrong = path.join(tmp, 'wrong');
    E.writeTree(wrong, { 'src/utils/ranges.js': `
      function mergeOverlappingRanges(ranges) { return ranges; } // doesn't merge or sort
      module.exports = { mergeOverlappingRanges };
    ` });
    check(!verifyFeature(wrong).pass, 'an implementation that ignores overlaps fails');

    const throws = path.join(tmp, 'throws');
    E.writeTree(throws, { 'src/utils/ranges.js': `
      function mergeOverlappingRanges(ranges) { throw new Error('nope'); }
      module.exports = { mergeOverlappingRanges };
    ` });
    check(!verifyFeature(throws).pass, 'an implementation that throws fails (not a crash of the harness)');

    const noExport = path.join(tmp, 'noexport');
    E.writeTree(noExport, { 'src/utils/ranges.js': `module.exports = {};` });
    check(!verifyFeature(noExport).pass, 'missing export fails cleanly');
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  process.exitCode = ok ? 0 : 1;
}

async function main() {
  const argv = process.argv.slice(2);
  const opt = (name, dflt) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : dflt; };
  if (opt('summarize')) { console.log(summarize(fs.readFileSync(opt('summarize'), 'utf8').trim().split('\n').map(JSON.parse))); return; }
  if (argv.includes('--self-test')) return selfTest();

  const models = opt('models', 'opus,sonnet').split(',');
  const reps = Number(opt('reps', 2));
  const tasks = opt('tasks', 'rename,retry,locate,feature').split(',');
  for (const t of tasks) if (!MODEL_TASKS[t]) throw new Error(`unknown task ${t}; have ${Object.keys(MODEL_TASKS).join(', ')}`);

  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const outFile = path.join(RESULTS_DIR, `model-bench-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`);
  const transcriptDir = outFile.replace(/\.jsonl$/, '');
  fs.mkdirSync(transcriptDir, { recursive: true });
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'model-bench-'));
  const rows = [];
  console.error(`model-bench: ${tasks.length} tasks x ${models.length} models x ${reps} reps\n-> ${outFile}`);
  try {
    for (let rep = 1; rep <= reps; rep++) {
      for (const taskName of tasks) {
        for (const model of models) {
          const row = await runOnce({ taskName, model, rep, tmpRoot, transcriptDir });
          rows.push(row);
          fs.appendFileSync(outFile, JSON.stringify(row) + '\n');
          console.error(`  rep${rep} ${taskName.padEnd(8)} ${model.padEnd(7)} ${row.pass ? 'PASS' : 'FAIL'} $${(row.costUSD || 0).toFixed(4)} turns=${row.turns} ${row.pass ? '' : row.problems.join('; ')}`);
        }
      }
    }
  } finally { fs.rmSync(tmpRoot, { recursive: true, force: true }); }
  console.log(summarize(rows));
}

if (require.main === module) main().catch(e => { console.error(e); process.exit(1); });
module.exports = { MODEL_TASKS, verifyFeature, summarize };
