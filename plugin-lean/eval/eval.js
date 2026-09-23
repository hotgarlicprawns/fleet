#!/usr/bin/env node
'use strict';

/*
 * fleet-lean A/B eval — does fleet-lean actually save money on real tasks?
 *
 * Runs the SAME coding tasks through real headless Claude Code
 * (`claude -p --output-format stream-json`) twice per repetition:
 *   baseline : no MCP servers
 *   lean     : only the fleet-lean MCP server
 * Everything else is identical (model, tools, permission mode, fixture repo,
 * prompt). Each run gets a fresh copy of a deterministic fixture repo, and
 * its result is checked by a strict verifier (the final tree must equal the
 * expected tree byte-for-byte, or the answer must name the right file).
 *
 * Numbers reported are Claude Code's own: total_cost_usd (list-price API
 * cost Claude Code computes; on a subscription it's the equivalent value,
 * not a bill), token usage, turns, wall time. Nothing is estimated here.
 * Savings are only computed over runs where BOTH arms passed, so a cheap
 * wrong answer can never count as a saving.
 *
 * Usage:
 *   node eval.js [--reps 3] [--model sonnet] [--tasks rename,locate,...]
 *   node eval.js --repo /path/to/fleet [--reps 3] [--tasks hudRename,hudLocate]
 *   node eval.js --summarize results/<file>.jsonl
 * Writes results/<timestamp>.jsonl (one line per run) and prints a summary.
 * Runs isolate XDG_CONFIG_HOME so they never touch your real savings data.
 *
 * --repo runs REPO_TASKS against a real committed snapshot (`git archive
 * HEAD`) of an actual repo instead of the synthetic fixture above — e.g.
 * the fleet repo itself. Each run gets its own throwaway extraction; the
 * real repo is never written to (git archive only reads it).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync, spawn } = require('child_process');

const HERE = __dirname;
const PLUGIN_ROOT = path.resolve(HERE, '..');
let SERVER = path.join(PLUGIN_ROOT, 'server', 'index.js'); // replaced by a frozen snapshot in main()
let SERVER_HASH = null;
const RESULTS_DIR = path.join(HERE, 'results');

// ---------------------------------------------------------------------------
// deterministic fixture repo
// ---------------------------------------------------------------------------

// tiny seeded PRNG so every run sees the byte-identical repo
function rng(seed) { let s = seed >>> 0; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32; }

const WORDS = ['order', 'invoice', 'customer', 'ledger', 'parcel', 'route', 'quota', 'batch', 'token',
  'session', 'refund', 'coupon', 'stock', 'vendor', 'region', 'audit', 'cache', 'metric', 'report', 'queue'];

function filler(r, prefix, n) {
  // realistic-looking but irrelevant functions, so reading a whole file costs what it would in a real repo
  const out = [];
  for (let i = 0; i < n; i++) {
    const a = WORDS[Math.floor(r() * WORDS.length)], b = WORDS[Math.floor(r() * WORDS.length)];
    const name = `${prefix}${a[0].toUpperCase()}${a.slice(1)}${b[0].toUpperCase()}${b.slice(1)}${i}`;
    out.push(
      `function ${name}(input, opts = {}) {`,
      `  const items = Array.isArray(input) ? input : [input];`,
      `  const limit = opts.limit ?? ${10 + Math.floor(r() * 90)};`,
      `  const result = [];`,
      `  for (const item of items.slice(0, limit)) {`,
      `    if (!item || item.${a}Id == null) continue;`,
      `    result.push({ id: item.${a}Id, ${b}: item.${b} ?? null, score: (item.weight || 1) * ${(r() * 3).toFixed(2)} });`,
      `  }`,
      `  return result.sort((x, y) => y.score - x.score);`,
      `}`,
      ``);
  }
  return out.join('\n');
}

function buildFixture() {
  const r = rng(42);
  const files = {};
  files['package.json'] = JSON.stringify({ name: 'acme-commerce', version: '1.0.0', private: true }, null, 2) + '\n';
  files['README.md'] = '# acme-commerce\n\nInternal order, billing and logistics services.\n';

  files['src/utils/money.js'] = [
    `'use strict';`, ``, filler(r, 'money', 6),
    `function formatCurrency(amount, currency = 'USD') {`,
    `  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(amount);`,
    `}`, ``, filler(r, 'money', 6),
    `module.exports = { formatCurrency };`, ``].join('\n');

  const services = ['orders', 'billing', 'invoices', 'refunds', 'customers', 'reports', 'coupons', 'vendors'];
  for (const svc of services) {
    const usesMoney = svc !== 'customers' && svc !== 'vendors';
    const lines = [`'use strict';`];
    if (usesMoney) lines.push(`const { formatCurrency } = require('../utils/money');`);
    lines.push(`const LOG_PREFIX = '[legacy]';`, ``, filler(r, svc, 18));
    if (usesMoney) {
      lines.push(`function describe${svc[0].toUpperCase() + svc.slice(1)}Total(total) {`,
        `  console.log(LOG_PREFIX, '${svc} total', formatCurrency(total));`,
        `  return formatCurrency(total);`, `}`, ``);
    } else {
      lines.push(`function describe${svc[0].toUpperCase() + svc.slice(1)}(x) {`,
        `  console.log(LOG_PREFIX, '${svc}', x);`, `  return String(x);`, `}`, ``);
    }
    if (svc === 'orders') {
      // target for the "retry" task, with a decoy constant of the same value right next to it
      lines.push(`const EMAIL_RECEIPT_MAX_ATTEMPTS = 3;`, `const PAYMENT_CAPTURE_MAX_ATTEMPTS = 3;`, ``,
        `async function capturePayment(order, gateway) {`,
        `  for (let attempt = 1; attempt <= PAYMENT_CAPTURE_MAX_ATTEMPTS; attempt++) {`,
        `    try { return await gateway.capture(order.paymentId); }`,
        `    catch (e) { console.log(LOG_PREFIX, 'capture failed', attempt, e.message); }`,
        `  }`, `  throw new Error('capture failed');`, `}`, ``,
        `async function sendReceipt(order, mailer) {`,
        `  for (let attempt = 1; attempt <= EMAIL_RECEIPT_MAX_ATTEMPTS; attempt++) {`,
        `    try { return await mailer.send(order.email); } catch (e) { /* retry */ }`,
        `  }`, `}`, ``);
    }
    lines.push(filler(r, svc + 'Tail', 18));
    lines.push(`module.exports = { LOG_PREFIX${svc === 'orders' ? ', capturePayment, sendReceipt' : ''} };`, ``);
    files[`src/services/${svc}.js`] = lines.join('\n');
  }

  // logistics: the "locate" target has a name that does NOT contain the words in the question
  files['src/services/logistics/rates.js'] = [`'use strict';`, ``, filler(r, 'rates', 20),
    `// parcels over 150cm combined length pay a flat handling premium`,
    `function applyBulkyFee(parcel, base) {`,
    `  const girth = parcel.length + 2 * (parcel.width + parcel.height);`,
    `  return girth > 150 ? base + 12.5 : base;`, `}`, ``,
    filler(r, 'rates', 20), `module.exports = { applyBulkyFee };`, ``].join('\n');
  files['src/services/logistics/zones.js'] = [`'use strict';`, ``, filler(r, 'zones', 30),
    `module.exports = {};`, ``].join('\n');
  files['src/services/logistics/carriers.js'] = [`'use strict';`, ``, filler(r, 'carrier', 30),
    `// surcharge table for fuel, NOT size`, `const FUEL_SURCHARGE = 0.07;`,
    `module.exports = { FUEL_SURCHARGE };`, ``].join('\n');

  // callers of formatCurrency outside services
  for (const name of ['checkout', 'cart', 'statement']) {
    files[`src/web/${name}.js`] = [`'use strict';`, `const { formatCurrency } = require('../utils/money');`, ``,
      filler(r, name, 12),
      `function render${name[0].toUpperCase() + name.slice(1)}(model) {`,
      `  return '<span>' + formatCurrency(model.total, model.currency) + '</span>';`, `}`, ``,
      `module.exports = { render${name[0].toUpperCase() + name.slice(1)} };`, ``].join('\n');
  }
  for (const name of ['helpers', 'dates', 'ids']) {
    files[`src/utils/${name}.js`] = [`'use strict';`, ``, filler(r, name, 15), `module.exports = {};`, ``].join('\n');
  }
  return files;
}

function writeTree(dir, files) {
  for (const [rel, content] of Object.entries(files)) {
    const p = path.join(dir, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, content);
  }
}

function readTree(dir) {
  const out = {};
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === '.git' || e.name === '.claude') continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p); else out[path.relative(dir, p)] = fs.readFileSync(p, 'utf8');
    }
  })(dir);
  return out;
}

/** Extracts the CURRENT COMMIT of a real repo into `dir` via `git archive`
 *  — read-only against the source repo (archive never touches the
 *  worktree or index), so this is safe to point at a real project. Refuses
 *  a dirty worktree so "the fixture" and "what's actually committed" can't
 *  silently diverge. */
function extractRepoSnapshot(repoPath, dir) {
  // Excludes this eval's own results/ output: running the eval writes new
  // result files INTO the very repo it's archiving from (results are
  // sometimes deliberately committed as evidence), which would otherwise
  // make every run after the first see the repo as "dirty" because of the
  // previous run's own output.
  const dirty = spawnSync('git', ['status', '--porcelain', '--', '.', ':!plugin-lean/eval/results'],
    { cwd: repoPath, encoding: 'utf8' });
  if (dirty.status !== 0) throw new Error(`--repo ${repoPath} is not a git repo`);
  if (dirty.stdout.trim()) throw new Error(`--repo ${repoPath} has uncommitted changes — commit or stash first so the archived snapshot matches HEAD:\n${dirty.stdout}`);
  fs.mkdirSync(dir, { recursive: true });
  const archive = spawnSync('git', ['archive', 'HEAD'], { cwd: repoPath, maxBuffer: 1024 * 1024 * 512 });
  if (archive.status !== 0) throw new Error(`git archive failed: ${archive.stderr}`);
  const untar = spawnSync('tar', ['-x', '-C', dir], { input: archive.stdout });
  if (untar.status !== 0) throw new Error(`tar extract failed: ${untar.stderr}`);
}

// ---------------------------------------------------------------------------
// tasks: prompt + expected transformation of the tree (null = no change) +
// optional answer check. Verification is strict: every file must match.
// ---------------------------------------------------------------------------

const mapTree = (files, fn) => Object.fromEntries(Object.entries(files).map(([k, v]) => [k, fn(k, v)]));

const TASKS = {
  rename: {
    prompt: 'Rename the function formatCurrency to formatMoney everywhere in this project: its definition, its export, every require/import of it, and every call site. Do not change anything else.',
    expect: files => mapTree(files, (k, v) => v.split('formatCurrency').join('formatMoney')),
  },
  retry: {
    prompt: 'In the orders service, payment capture is retried at most 3 times. Change that limit to 5. Do not change any other limit or anything else.',
    expect: files => mapTree(files, (k, v) => k === 'src/services/orders.js'
      ? v.replace('const PAYMENT_CAPTURE_MAX_ATTEMPTS = 3;', 'const PAYMENT_CAPTURE_MAX_ATTEMPTS = 5;') : v),
  },
  prefix: {
    prompt: "Every service under src/services logs with the prefix '[legacy]'. Change that prefix to '[core]' in every file under src/services (including subfolders, wherever it appears). Do not change anything else.",
    expect: files => mapTree(files, (k, v) => k.startsWith('src/services/') ? v.split("'[legacy]'").join("'[core]'") : v),
  },
  locate: {
    prompt: 'Which file defines the function that adds the extra charge for oversized parcels? Do not modify any files. Reply with only the relative file path, nothing else.',
    expect: files => files,
    answer: out => /src\/services\/logistics\/rates\.js/.test(out || ''),
  },
};

// ---------------------------------------------------------------------------
// tasks for --repo mode: a real, modest-size codebase (the fleet repo
// itself — ~10K lines / 116 tracked files), designed the same way as the
// synthetic tasks above (exact-transform verification, no fabricated
// baseline). Picked from real identifiers, checked by hand beforehand to
// occur ONLY where the task expects (see plugin-lean/eval/README.md).
// ---------------------------------------------------------------------------
const REPO_TASKS = {
  hudRename: {
    prompt: 'Rename the Swift property `hudInstalled` to `hudActive` everywhere it appears in this project — its declaration and every read/write site. Do not change anything else.',
    // Restricted to *.swift: the repo snapshot includes this eval harness's
    // own source, which mentions "hudInstalled" in this very prompt string —
    // a blind whole-tree replace would rewrite that non-Swift, non-identifier
    // occurrence too, which isn't what a correct answer would do.
    expect: files => mapTree(files, (k, v) => k.endsWith('.swift') ? v.split('hudInstalled').join('hudActive') : v),
  },
  hudLocate: {
    prompt: 'Which Swift file defines the function that re-copies the bundled HUD statusline script over the installed one only if the bytes actually differ? Do not modify any files. Reply with only the relative file path, nothing else.',
    expect: files => files,
    answer: out => /app\/Sources\/FleetApp\/HUDManager\.swift/.test(out || ''),
  },
};

function verify(task, dir, original, resultText) {
  const expected = task.expect(original);
  const actual = readTree(dir);
  const problems = [];
  for (const k of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
    if (expected[k] !== actual[k]) problems.push(k in actual ? (k in expected ? `differs: ${k}` : `unexpected file: ${k}`) : `missing: ${k}`);
  }
  if (task.answer && !task.answer(resultText)) problems.push(`wrong answer: ${JSON.stringify((resultText || '').slice(0, 120))}`);
  return { pass: problems.length === 0, problems: problems.slice(0, 5) };
}

// ---------------------------------------------------------------------------
// one headless Claude Code run
// ---------------------------------------------------------------------------

// Tools irrelevant to a local coding task, removed identically in both arms
// so neither can wander off (web, subagents, scheduling, etc.).
const DISALLOWED = ['Task', 'Agent', 'WebFetch', 'WebSearch', 'CronCreate', 'CronDelete', 'CronList', 'DesignSync',
  'EnterWorktree', 'ExitWorktree', 'ListAgents', 'Monitor', 'NotebookEdit', 'PushNotification', 'RemoteTrigger',
  'ReportFindings', 'ScheduleWakeup', 'SendMessage', 'Skill', 'TaskCreate', 'TaskGet', 'TaskList', 'TaskStop',
  'TaskUpdate'];

function runOnce({ taskName, arm, model, rep, tmpRoot, transcriptDir, repoPath, taskSet }) {
  const task = taskSet[taskName];
  const dir = fs.mkdtempSync(path.join(tmpRoot, `${taskName}-${arm}-`));
  let original;
  if (repoPath) {
    extractRepoSnapshot(repoPath, dir);
    // Strip this eval harness's own source from the snapshot the AGENT sees —
    // its task prompts mention real identifiers (e.g. "hudInstalled"), so
    // leaving it in would let the model "correctly" find and edit a match
    // inside the eval tool itself, contaminating the ground truth.
    fs.rmSync(path.join(dir, 'plugin-lean', 'eval'), { recursive: true, force: true });
    spawnSync('git', ['init', '-q'], { cwd: dir });
    original = readTree(dir); // read back what was actually extracted — never assumed
  } else {
    original = buildFixture();
    writeTree(dir, original);
    spawnSync('git', ['init', '-q'], { cwd: dir }); // many tools key off a repo root; identical in both arms
  }

  const xdg = path.join(tmpRoot, `xdg-${arm}`);
  fs.mkdirSync(xdg, { recursive: true });
  const mcp = path.join(tmpRoot, `mcp-${arm}.json`);
  fs.writeFileSync(mcp, JSON.stringify({ mcpServers: arm === 'lean'
    ? { 'fleet-lean': { command: 'node', args: [SERVER], env: { XDG_CONFIG_HOME: xdg } } } : {} }));

  const args = ['-p', task.prompt, '--model', model, '--output-format', 'stream-json', '--verbose',
    '--strict-mcp-config', '--mcp-config', mcp, '--setting-sources', 'project',
    '--permission-mode', 'bypassPermissions', '--disallowedTools', ...DISALLOWED];

  return new Promise(resolve => {
    const started = Date.now();
    const child = spawn('claude', args, { cwd: dir, env: { ...process.env, XDG_CONFIG_HOME: xdg }, stdio: ['ignore', 'pipe', 'pipe'] });
    let buf = '', result = null, tools = {}, mcpStatus = null;
    const transcript = transcriptDir ? fs.createWriteStream(path.join(transcriptDir, `${taskName}-${arm}-rep${rep}.jsonl`)) : null;
    const timer = setTimeout(() => child.kill('SIGKILL'), 10 * 60 * 1000);
    child.stdout.on('data', d => {
      if (transcript) transcript.write(d);
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.type === 'system' && m.subtype === 'init') mcpStatus = m.mcp_servers;
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
      fs.rmSync(dir, { recursive: true, force: true });
      resolve({
        ts: new Date().toISOString(), task: taskName, arm, rep, model,
        pass: v.pass, problems: v.problems,
        costUSD: result ? result.total_cost_usd : null,
        turns: result ? result.num_turns : null,
        durationMs: Date.now() - started,
        inputTokens: u.input_tokens || 0, outputTokens: u.output_tokens || 0,
        cacheWriteTokens: u.cache_creation_input_tokens || 0, cacheReadTokens: u.cache_read_input_tokens || 0,
        tools, leanToolCalls: Object.entries(tools).filter(([k]) => k.includes('fleet-lean')).reduce((s, [, n]) => s + n, 0),
        mcpStatus, isError: result ? !!result.is_error : true, serverHash: SERVER_HASH,
      });
    });
  });
}

// ---------------------------------------------------------------------------
// summary
// ---------------------------------------------------------------------------

const median = xs => { const s = [...xs].sort((a, b) => a - b); const n = s.length; return n ? (n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2) : NaN; };
const sum = xs => xs.reduce((a, b) => a + b, 0);
const totalTok = r => r.inputTokens + r.outputTokens + r.cacheWriteTokens + r.cacheReadTokens;
const pct = (a, b) => b ? `${((1 - a / b) * 100).toFixed(1)}%` : 'n/a';

function summarize(rows) {
  const lines = [];
  const tasks = [...new Set(rows.map(r => r.task))];
  lines.push(`model: ${[...new Set(rows.map(r => r.model))].join(', ')}   server: ${[...new Set(rows.map(r => r.serverHash))].join(', ')}   runs: ${rows.length}`);
  lines.push('');
  lines.push('task      arm       pass   median $   median turns  median tokens  lean calls');
  const paired = { base: [], lean: [] };
  for (const t of tasks) {
    for (const arm of ['baseline', 'lean']) {
      const rs = rows.filter(r => r.task === t && r.arm === arm);
      if (!rs.length) continue;
      lines.push(`${t.padEnd(9)} ${arm.padEnd(9)} ${`${rs.filter(r => r.pass).length}/${rs.length}`.padEnd(6)} ` +
        `${median(rs.map(r => r.costUSD || 0)).toFixed(4).padStart(9)}  ${String(median(rs.map(r => r.turns || 0))).padStart(12)}  ` +
        `${String(Math.round(median(rs.map(totalTok)))).padStart(13)}  ${String(sum(rs.map(r => r.leanToolCalls))).padStart(10)}`);
    }
    // pair by rep: only reps where both arms passed count toward savings
    for (const rep of [...new Set(rows.filter(r => r.task === t).map(r => r.rep))]) {
      const b = rows.find(r => r.task === t && r.rep === rep && r.arm === 'baseline');
      const l = rows.find(r => r.task === t && r.rep === rep && r.arm === 'lean');
      if (b && l && b.pass && l.pass) { paired.base.push(b); paired.lean.push(l); }
    }
  }
  lines.push('');
  const n = paired.base.length;
  if (!n) {
    lines.push('No pairs where both arms passed — no savings claim can be made from this run.');
  } else {
    const bc = sum(paired.base.map(r => r.costUSD)), lc = sum(paired.lean.map(r => r.costUSD));
    const bt = sum(paired.base.map(totalTok)), lt = sum(paired.lean.map(totalTok));
    const bturn = sum(paired.base.map(r => r.turns)), lturn = sum(paired.lean.map(r => r.turns));
    const wins = paired.base.filter((b, i) => paired.lean[i].costUSD < b.costUSD).length;
    lines.push(`Over ${n} pairs where BOTH arms passed:`);
    lines.push(`  cost    baseline $${bc.toFixed(4)}  lean $${lc.toFixed(4)}  -> lean saves ${pct(lc, bc)}`);
    lines.push(`  tokens  baseline ${bt}  lean ${lt}  -> ${pct(lt, bt)}`);
    lines.push(`  turns   baseline ${bturn}  lean ${lturn}  -> ${pct(lturn, bturn)}`);
    lines.push(`  lean was cheaper in ${wins}/${n} pairs`);
    const unused = paired.lean.filter(r => !r.leanToolCalls).length;
    if (unused) lines.push(`  note: in ${unused}/${n} lean runs the model never called a fleet-lean tool (those differ only by noise + tool-schema overhead)`);
  }
  const fails = rows.filter(r => !r.pass);
  if (fails.length) {
    lines.push('');
    lines.push('Failures:');
    for (const f of fails) lines.push(`  ${f.task}/${f.arm}/rep${f.rep}: ${f.problems.join('; ')}`);
  }
  lines.push('');
  lines.push('$ = Claude Code\'s own total_cost_usd (list-price API cost; on a subscription this is the equivalent value, not a charge).');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------

async function main() {
  const argv = process.argv.slice(2);
  const opt = (name, dflt) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : dflt; };
  if (opt('summarize')) {
    const rows = fs.readFileSync(opt('summarize'), 'utf8').trim().split('\n').map(l => JSON.parse(l));
    console.log(summarize(rows));
    return;
  }
  if (argv.includes('--self-test')) return selfTest();
  const reps = Number(opt('reps', 3));
  const model = opt('model', 'sonnet');
  const repoPath = opt('repo', null) ? path.resolve(opt('repo', null)) : null;
  const taskSet = repoPath ? REPO_TASKS : TASKS;
  const tasks = opt('tasks', Object.keys(taskSet).join(',')).split(',');
  for (const t of tasks) if (!taskSet[t]) throw new Error(`unknown task ${t}; have ${Object.keys(taskSet).join(', ')}`);

  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const outFile = path.join(RESULTS_DIR, `${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`);
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-lean-eval-'));
  // Freeze the server under test: copy it once, so editing the plugin while
  // an eval runs can't silently mix two versions into one result file.
  const snap = path.join(tmpRoot, 'plugin');
  fs.mkdirSync(path.join(snap, 'server'), { recursive: true });
  for (const f of ['server/index.js', 'license.js', 'product.json']) {
    if (fs.existsSync(path.join(PLUGIN_ROOT, f))) fs.copyFileSync(path.join(PLUGIN_ROOT, f), path.join(snap, f));
  }
  SERVER = path.join(snap, 'server', 'index.js');
  SERVER_HASH = require('crypto').createHash('sha256').update(fs.readFileSync(SERVER)).digest('hex').slice(0, 12);
  const rows = [];
  const transcriptDir = outFile.replace(/\.jsonl$/, '');
  fs.mkdirSync(transcriptDir, { recursive: true });
  console.error(`fleet-lean eval: ${tasks.length} tasks x 2 arms x ${reps} reps, model ${model}, server ${SERVER_HASH}` +
    (repoPath ? `, repo ${repoPath}` : '') + `\n-> ${outFile}`);
  try {
    for (let rep = 1; rep <= reps; rep++) {
      for (const taskName of tasks) {
        // alternate arm order each rep so prompt-cache warmth doesn't systematically favor one arm
        const arms = rep % 2 ? ['baseline', 'lean'] : ['lean', 'baseline'];
        for (const arm of arms) {
          const row = await runOnce({ taskName, arm, model, rep, tmpRoot, transcriptDir, repoPath, taskSet });
          rows.push(row);
          fs.appendFileSync(outFile, JSON.stringify(row) + '\n');
          console.error(`  rep${rep} ${taskName.padEnd(7)} ${arm.padEnd(8)} ${row.pass ? 'PASS' : 'FAIL'} $${(row.costUSD || 0).toFixed(4)} turns=${row.turns} lean=${row.leanToolCalls} ${row.pass ? '' : row.problems.join('; ')}`);
        }
      }
    }
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
  console.log(summarize(rows));
}

// Verifies the harness itself without spending anything: the verifier must
// accept the expected tree and reject the untouched/over-edited one.
function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-lean-eval-self-'));
  let ok = true;
  const check = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) ok = false; };
  try {
    const orig = buildFixture();
    check(JSON.stringify(orig) === JSON.stringify(buildFixture()), 'fixture is deterministic');
    const bytes = sum(Object.values(orig).map(v => v.length));
    check(bytes > 50_000, `fixture is non-trivial (${Object.keys(orig).length} files, ${bytes} bytes)`);
    for (const [name, task] of Object.entries(TASKS)) {
      const d = fs.mkdtempSync(path.join(tmp, name));
      writeTree(d, task.expect(orig));
      check(verify(task, d, orig, task.answer ? 'src/services/logistics/rates.js' : '').pass, `${name}: expected tree passes`);
      if (task.expect(orig) !== orig && JSON.stringify(task.expect(orig)) !== JSON.stringify(orig)) {
        const d2 = fs.mkdtempSync(path.join(tmp, name + 'x'));
        writeTree(d2, orig);
        check(!verify(task, d2, orig, '').pass, `${name}: untouched tree fails`);
      } else {
        check(!verify(task, d, orig, 'src/services/logistics/carriers.js').pass, `${name}: wrong answer fails`);
      }
    }
    // over-editing the decoy must fail the retry task
    const d3 = fs.mkdtempSync(path.join(tmp, 'decoy'));
    writeTree(d3, mapTree(TASKS.retry.expect(orig), (k, v) => v.replace('EMAIL_RECEIPT_MAX_ATTEMPTS = 3', 'EMAIL_RECEIPT_MAX_ATTEMPTS = 5')));
    check(!verify(TASKS.retry, d3, orig, '').pass, 'retry: also changing the decoy constant fails');
    // every fixture JS file must parse, before and after each transformation
    for (const [name, task] of Object.entries(TASKS)) {
      const d = fs.mkdtempSync(path.join(tmp, name + 'syn'));
      writeTree(d, task.expect(orig));
      const bad = Object.keys(orig).filter(k => k.endsWith('.js') && spawnSync('node', ['--check', path.join(d, k)]).status !== 0);
      check(!bad.length, `${name}: all JS parses after transform${bad.length ? ' (' + bad.join(', ') + ')' : ''}`);
    }
    const counts = Object.values(orig).join('').split('formatCurrency').length - 1;
    check(counts >= 12, `rename touches many sites (${counts} occurrences)`);

    // --repo mode: extract this actual repo (read-only) and check the
    // REPO_TASKS transforms/verifier against it — no Claude call, no cost.
    const repoDir = fs.mkdtempSync(path.join(tmp, 'repo-'));
    extractRepoSnapshot(path.resolve(PLUGIN_ROOT, '..'), repoDir);
    fs.rmSync(path.join(repoDir, 'plugin-lean', 'eval'), { recursive: true, force: true }); // see runOnce's matching strip
    const repoOrig = readTree(repoDir);
    check(Object.keys(repoOrig).length > 50, `real repo snapshot extracted (${Object.keys(repoOrig).length} files)`);
    const hudFile = 'app/Sources/FleetApp/CockpitStore.swift';
    check((repoOrig[hudFile] || '').includes('hudInstalled'), 'real repo contains the expected hudInstalled identifier');
    for (const [name, task] of Object.entries(REPO_TASKS)) {
      const d = fs.mkdtempSync(path.join(tmp, 'repo-' + name));
      writeTree(d, task.expect(repoOrig));
      check(verify(task, d, repoOrig, task.answer ? 'app/Sources/FleetApp/HUDManager.swift' : '').pass, `repo/${name}: expected tree passes`);
      const d2 = fs.mkdtempSync(path.join(tmp, 'repo-' + name + 'x'));
      writeTree(d2, repoOrig);
      check(!verify(task, d2, repoOrig, 'app/Sources/FleetApp/CockpitStore.swift').pass, `repo/${name}: untouched tree fails`);
    }
    const hudCount = Object.values(repoOrig).join('').split('hudInstalled').length - 1;
    check(hudCount === 6, `hudRename touches exactly the 6 known real sites (found ${hudCount})`);
    const hudFiles = Object.entries(repoOrig).filter(([k, v]) => v.includes('hudInstalled')).length;
    check(hudFiles === 3, `hudInstalled occurs in exactly the 3 known real Swift files (found ${hudFiles})`);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  process.exitCode = ok ? 0 : 1;
}

if (require.main === module) main().catch(e => { console.error(e); process.exit(1); });
module.exports = { buildFixture, TASKS, REPO_TASKS, verify, summarize };
