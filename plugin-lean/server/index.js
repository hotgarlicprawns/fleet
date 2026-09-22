#!/usr/bin/env node
'use strict';

/*
 * fleet-lean — a local MCP server exposing two tools that fuse several
 * built-in Claude Code tool calls into one, to cut round-trips and token
 * spend on a session. No account, no network call, no telemetry that
 * leaves this machine.
 *
 * Pure Node, no dependencies — same rule bin/fleet.js follows. The stdio
 * MCP transport is newline-delimited JSON-RPC 2.0: no SDK needed for a
 * server this small.
 *
 * CRITICAL: stdout carries ONLY JSON-RPC. Any debug output must go to
 * stderr, or it corrupts the protocol stream for whatever is reading it.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');

function log(...args) { process.stderr.write('[fleet-lean] ' + args.join(' ') + '\n'); }

// ---------------------------------------------------------------------------
// savings sidecar — one file per server process lifetime (~= one Claude
// Code session, since Claude Code spawns one MCP server subprocess per
// session). Sits beside the HUD's own <sessionId>.json, deliberately a
// separate file so the two writers never race on the same path.
// ---------------------------------------------------------------------------

const CFG_DIR = path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'fleet');
const SESS_DIR = path.join(CFG_DIR, 'sessions');
const ROLLUP_FILE = path.join(CFG_DIR, 'lean-savings.json');
const RUN_ID = `${Date.now().toString(36)}-${crypto.randomBytes(4).toString('hex')}`;
const SIDECAR = path.join(SESS_DIR, `${RUN_ID}.lean.json`);

const estimateTokens = bytes => Math.ceil(bytes / 4); // chars/4 heuristic; no tokenizer dependency

/** Real (not estimated) count of built-in tool calls a fused call replaced —
 *  the exact heuristic documented in commands/fleet-lean-report.md, computed
 *  once here so the sidecar, the all-time rollup and the report all agree:
 *    lean_search -> 1 Glob + 1 Grep + filesMatched Reads
 *    lean_edit   -> 2 calls (Read + Edit) per edit in the batch
 *  This is a call *count*, which is exact given the tool's own output — it
 *  is deliberately NOT a "tokens saved" figure, since we never ran the
 *  avoided calls and don't know what they'd have cost (see real-metrics
 *  discipline: don't invent a number you can't back up). */
function callsAvoidedFor(name, args, out) {
  if (name === 'lean_search') return 1 + 1 + (out.filesMatched || 0);
  if (name === 'lean_edit') return 2 * ((args && args.edits && args.edits.length) || 0);
  return 0;
}

let calls = [];
function recordCall(rec) {
  const withTs = { ts: new Date().toISOString(), ...rec };
  calls.push(withTs);
  try {
    fs.mkdirSync(SESS_DIR, { recursive: true });
    // claudePid: the parent `claude` process's own PID. Claude Code spawns
    // this MCP server as a DIRECT child of the top-level `claude` process
    // for that session (verified empirically against real running Claude
    // Code sessions — MCP subprocesses share process.ppid with each other
    // and it equals `claude`'s own PID). The HUD's statusline.sh hook is
    // also invoked as a direct child of that same process, so it can write
    // the identical value as its own $PPID — giving both sidecars a real,
    // shared key instead of the previous "most recently modified file"
    // guess, which picks the wrong session whenever more than one Claude
    // pane is active (exactly Fleet's normal use case).
    fs.writeFileSync(SIDECAR, JSON.stringify({ runId: RUN_ID, pid: process.pid, claudePid: process.ppid, calls }, null, 2));
  } catch (e) { log('sidecar write failed:', e.message); }
  updateRollup(withTs); // must be the timestamped copy — the original `rec` has no .ts
}

/** Persistent local, cross-session rollup on this machine — free tier,
 *  no account, no network. Read-modify-write against a single small JSON
 *  file; not lock-protected (same best-effort tradeoff every other sidecar
 *  in this codebase makes — a lost update under true concurrent writers is
 *  a rollup undercount, never a crash or a fabricated number). */
function updateRollup(rec) {
  const day = rec.ts.slice(0, 10); // YYYY-MM-DD, UTC — matches ts's own ISO format
  let data;
  try { data = JSON.parse(fs.readFileSync(ROLLUP_FILE, 'utf8')); } catch { data = { days: {} } }
  if (!data.days) data.days = {};
  const bucket = data.days[day] || { calls: 0, callsAvoided: 0, estTokens: 0, estTokensAvoided: 0, runs: [] };
  bucket.calls += 1;
  bucket.callsAvoided += rec.callsAvoided || 0;
  bucket.estTokens += (rec.estInputTokens || 0) + (rec.estOutputTokens || 0);
  bucket.estTokensAvoided = (bucket.estTokensAvoided || 0) + (rec.estTokensAvoided || 0);
  if (!bucket.runs.includes(RUN_ID)) bucket.runs.push(RUN_ID);
  data.days[day] = bucket;
  try {
    fs.mkdirSync(CFG_DIR, { recursive: true });
    fs.writeFileSync(ROLLUP_FILE, JSON.stringify(data, null, 2));
  } catch (e) { log('rollup write failed:', e.message); }
}

// Per-run *.lean.json sidecars are never cleaned up by the Fleet app's own
// pruning (SessionStats.pruneOlderThan in the Swift app): it tries to
// decode every "*.json" file as its own SessionStat schema, silently skips
// anything that fails to decode (a *.lean.json has a different shape), and
// so never deletes them — meaning someone using fleet-lean standalone
// (no Fleet app at all) had NO cleanup path and these accumulate forever.
// This is fleet-lean's own equivalent, run once per server startup (not
// per call — a full directory scan per call would be wasteful).
const SIDECAR_MAX_AGE_MS = 30 * 864e5; // 30 days, matches the app's own convention
function pruneOldSidecars() {
  let names;
  try { names = fs.readdirSync(SESS_DIR); } catch { return; }
  const cutoff = Date.now() - SIDECAR_MAX_AGE_MS;
  for (const n of names) {
    if (!n.endsWith('.lean.json')) continue; // never touch the HUD's own sidecars
    const full = path.join(SESS_DIR, n);
    try { if (fs.statSync(full).mtimeMs < cutoff) fs.unlinkSync(full); } catch { /* racing another process — fine, skip */ }
  }
}

// ---------------------------------------------------------------------------
// lean_search — fused glob + grep + read, returns ranked snippets instead
// of full file contents.
// ---------------------------------------------------------------------------

/** Minimal glob -> RegExp. Supports ** , * , ? , {a,b} , [...] — enough for
 *  real use without pulling in a glob dependency. */
function globToRegExp(glob) {
  let re = '', i = 0;
  while (i < glob.length) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') { re += '.*'; i += 2; if (glob[i] === '/') i++; }
      else { re += '[^/]*'; i++; }
    } else if (c === '?') { re += '[^/]'; i++; }
    else if (c === '{') {
      const end = glob.indexOf('}', i);
      if (end === -1) { re += '\\{'; i++; continue; } // unbalanced — treat literally, don't loop forever
      const opts = glob.slice(i + 1, end).split(',').map(s => s.replace(/[.+^${}()|[\]\\]/g, '\\$&'));
      re += `(?:${opts.join('|')})`; i = end + 1;
    } else if (c === '[') {
      const end = glob.indexOf(']', i + 1);
      if (end === -1) { re += '\\['; i++; continue; } // unbalanced — treat literally
      re += glob.slice(i, end + 1); // pass character class through as-is (regex syntax matches glob's here)
      i = end + 1;
    } else if ('.+^${}()|\\'.includes(c)) { re += '\\' + c; i++; }
    else { re += c; i++; }
  }
  return new RegExp('^' + re + '$');
}

const IGNORE_DIRS = new Set(['.git', 'node_modules', '.build', 'DerivedData', '.swiftpm', 'dist', 'build']);

/** Best-effort .gitignore support: only reads the root .gitignore, only
 *  matches whole path segments (not full gitignore glob semantics) — good
 *  enough to skip the common junk directories a project already excludes,
 *  not a complete implementation. */
function readRootIgnoreNames(root) {
  const names = new Set();
  try {
    const lines = fs.readFileSync(path.join(root, '.gitignore'), 'utf8').split('\n');
    for (let l of lines) {
      l = l.trim();
      if (!l || l.startsWith('#')) continue;
      l = l.replace(/^\/+/, '').replace(/\/+$/, '');
      if (l && !l.includes('*') && !l.includes('/')) names.add(l);
    }
  } catch { /* no .gitignore, or unreadable — fine */ }
  return names;
}

/** First-4KB NUL-byte sniff — the same heuristic git and most tools use to
 *  guess "binary". Not perfect, but cheap and catches the common case
 *  (compiled binaries, images) that has no business being searched or
 *  edited as text. */
function looksBinary(buf) {
  const n = Math.min(buf.length, 4096);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

function walk(dir, out, ignoreNames) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    if (IGNORE_DIRS.has(e.name) || (ignoreNames && ignoreNames.has(e.name))) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out, ignoreNames);
    else if (e.isFile()) out.push(full);
  }
}

const MAX_OUTPUT_BYTES = 60_000;   // keep the fused call itself from becoming the token cost
const MAX_LINE_CHARS = 300;        // one absurdly long line (minified JS) shouldn't dominate a snippet

function truncateLine(l) {
  return l.length > MAX_LINE_CHARS ? l.slice(0, MAX_LINE_CHARS) + ' …[truncated]' : l;
}

function leanSearch({ pattern, query, isRegex = false, caseInsensitive = false, contextLines = 3, maxResults = 30, cwd }) {
  const root = path.resolve(cwd || process.cwd());
  const ignoreNames = readRootIgnoreNames(root);
  const all = [];
  walk(root, all, ignoreNames);
  const rel = f => path.relative(root, f);
  const matcher = globToRegExp(pattern);
  const files = all.filter(f => matcher.test(rel(f)));

  const flags = caseInsensitive ? 'i' : '';
  const needle = isRegex ? new RegExp(query, flags) : null;
  const needleLower = caseInsensitive && !isRegex ? query.toLowerCase() : query;

  const results = [];
  let filesSkippedBinary = 0;
  let vanillaReadBytes = 0; // REAL, not estimated: the actual byte size of every
                            // file that matched — what a built-in Read would have
                            // cost per file, since we already have these bytes
                            // in hand from searching them
  for (const file of files) {
    let buf;
    try { buf = fs.readFileSync(file); } catch { continue; }
    if (looksBinary(buf)) { filesSkippedBinary++; continue; }
    const text = buf.toString('utf8');
    const lines = text.split('\n');
    const hits = [];
    lines.forEach((line, idx) => {
      const isMatch = isRegex ? needle.test(line)
        : caseInsensitive ? line.toLowerCase().includes(needleLower) : line.includes(query);
      if (isMatch) hits.push(idx);
    });
    if (hits.length) { results.push({ file: rel(file), hits, lines }); vanillaReadBytes += buf.length; }
  }

  // Merge each file's hit lines into non-overlapping context windows first,
  // so a cluster of nearby hits produces one snippet instead of N
  // overlapping ones (a real prior bug: a 20-line file could return >10x
  // its own size in repeated context). Then round-robin one window per
  // matched file at a time, instead of sorting by raw hit count and
  // cutting off — a single generated file with hundreds of hits should not
  // be able to push every other matched file out of the results.
  const perFile = results.map(r => {
    const windows = [];
    for (const lineIdx of r.hits) {
      const start = Math.max(0, lineIdx - contextLines);
      const end = Math.min(r.lines.length, lineIdx + contextLines + 1);
      const last = windows[windows.length - 1];
      if (last && start <= last.end) { last.end = Math.max(last.end, end); last.hitLines.push(lineIdx + 1); }
      else windows.push({ start, end, hitLines: [lineIdx + 1] });
    }
    return { file: r.file, lines: r.lines, windows, hitCount: r.hits.length };
  });

  const out = [];
  let outBytes = 0, truncated = false;
  let round = 0, remaining = perFile.filter(f => f.windows.length > 0);
  outer:
  while (remaining.length) {
    for (const f of remaining) {
      if (round >= f.windows.length) continue;
      if (out.length >= maxResults) break outer;
      const w = f.windows[round];
      const snippet = f.lines.slice(w.start, w.end).map(truncateLine).join('\n');
      const entry = { file: f.file, lineNumber: w.hitLines[0], matchedLines: w.hitLines, snippet };
      const entryBytes = JSON.stringify(entry).length;
      if (outBytes + entryBytes > MAX_OUTPUT_BYTES) { truncated = true; break outer; }
      out.push(entry); outBytes += entryBytes;
    }
    round++;
    remaining = remaining.filter(f => round < f.windows.length);
  }

  return {
    matches: out,
    filesScanned: files.length,
    filesMatched: results.length,
    filesSkippedBinary,
    truncated, // true if results were cut short by the output size cap, not just maxResults
    vanillaReadBytes // real byte total of matched files — the Read-equivalent cost this call avoided
  };
}

// ---------------------------------------------------------------------------
// lean_edit — batch multi-file find/replace with fuzzy matching.
// Correctness contract: never guess. Ambiguous -> reject the whole file's
// edit and say why. Partial failure anywhere in the batch -> apply nothing.
// ---------------------------------------------------------------------------

function normalizeForMatch(s) {
  return s
    .replace(/[‘’‚‛]/g, "'")
    .replace(/[“”„‟]/g, '"')
    .replace(/[–−]/g, '-')   // en dash, minus
    .replace(/—/g, '-')          // em dash
    .replace(/…/g, '...')        // ellipsis
    .replace(/ /g, ' ')          // nbsp
    .replace(/\t/g, '  ')             // tabs -> 2sp, COMPARISON ONLY — never used
                                       // when actually writing a line back out
    .split('\n').map(l => l.replace(/\s+$/, '')).join('\n'); // trailing ws
}

function indentOf(line) { const m = line.match(/^[ ]*/); return m[0].length; }
/** Raw leading-whitespace prefix, spaces AND tabs, exactly as written —
 *  used when actually reconstructing a line so tab-indented files don't
 *  get silently corrupted by the space-only count above (which is fine for
 *  the pre-normalized comparison in tryMatch, but was wrongly reused for
 *  real reindentation in a prior version — a tab-indented Python file with
 *  a line starting a tab counted as indent 0, then had spaces spliced onto
 *  column 0, breaking the file). */
function indentPrefix(line) { const m = line.match(/^[ \t]*/); return m[0]; }

function levenshtein(a, b) {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] = a[i - 1] === b[j - 1]
        ? dp[i - 1][j - 1]
        : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
    }
  }
  return dp[a.length][b.length];
}

// A short find string tolerating a 2-character Levenshtein budget is how
// "retry(1);" silently matched and overwrote "retry(2);" in testing — one
// digit is within budget for a string that short. Fuzzy matching is now
// OPT-IN (edit.fuzzy === true) and additionally refuses to run at all
// below this length, no matter what the caller asks for.
const MIN_FUZZY_LEN = 24;

/** Compares `find` (as lines) against a same-length window of `fileLines`
 *  starting at `start`. Requires exact indent-delta-from-first-line match
 *  (base indent may differ; relative nesting may not) plus a normalized
 *  text match — exact only, unless `fuzzy` is explicitly true AND the
 *  find text clears MIN_FUZZY_LEN, in which case a small Levenshtein
 *  budget is allowed as a fallback. Always reports the actual matched
 *  text and distance so a fuzzy match is never silently invisible. */
function tryMatch(findLines, fileLines, start, fuzzy) {
  const n = findLines.length;
  if (start + n > fileLines.length) return null;
  const window = fileLines.slice(start, start + n);

  const findNorm = findLines.map(normalizeForMatch);
  const winNorm = window.map(normalizeForMatch);

  const findBaseIndent = indentOf(findNorm[0]);
  const winBaseIndent = indentOf(winNorm[0]);
  for (let i = 0; i < n; i++) {
    const fDelta = indentOf(findNorm[i]) - findBaseIndent;
    const wDelta = indentOf(winNorm[i]) - winBaseIndent;
    if (fDelta !== wDelta) return null; // relative nesting must match exactly
  }

  const findFlat = findNorm.map(l => l.trim()).join('\n');
  const winFlat = winNorm.map(l => l.trim()).join('\n');
  if (findFlat === winFlat) return { start, end: start + n, distance: 0, matchedText: window.join('\n') };

  if (!fuzzy || findFlat.length < MIN_FUZZY_LEN) return null;

  // Edit distance can never be smaller than the length difference — skip
  // the O(n*m) DP entirely for windows that are already too different in
  // length to fit the budget. This is what keeps a large-file fuzzy search
  // from being an accidental denial of service.
  const budget = Math.max(2, Math.floor(0.05 * findFlat.length));
  if (Math.abs(findFlat.length - winFlat.length) > budget) return null;

  const dist = levenshtein(findFlat, winFlat);
  if (dist <= budget) return { start, end: start + n, distance: dist, matchedText: window.join('\n') };
  return null;
}

/** Finds every acceptable match of `find` in `text`. Never returns "the
 *  best" match silently — callers must check length and reject on >1.
 *  Exact (distance 0) matches always take priority over fuzzy ones. */
function findAllMatches(find, text, fuzzy = false) {
  const findLines = find.split('\n');
  const fileLines = text.split('\n');
  const out = [];
  for (let start = 0; start <= fileLines.length - findLines.length; start++) {
    const exact = tryMatch(findLines, fileLines, start, false);
    if (exact) { out.push(exact); continue; }
    if (fuzzy) {
      const fz = tryMatch(findLines, fileLines, start, true);
      if (fz) out.push(fz);
    }
  }
  const exactOnly = out.filter(m => m.distance === 0);
  return exactOnly.length ? exactOnly : out;
}

function applyReplace(text, find, replace, match) {
  const fileLines = text.split('\n');
  const findLines = find.split('\n');
  const replaceLines = replace.split('\n');
  // Preserve the matched block's ACTUAL indentation prefix (spaces or tabs,
  // literally, not a recomputed space count) and graft each replace line's
  // own relative indent (whatever's beyond find's own base prefix) onto it.
  // This works for space- or tab-indented files alike, and for negative
  // shifts (dedenting), without ever assuming a particular indent unit.
  const actualBasePrefix = indentPrefix(fileLines[match.start]);
  const findBasePrefix = indentPrefix(findLines[0]);
  const shifted = replaceLines.map(l => {
    if (l.length === 0) return l;
    const linePrefix = indentPrefix(l);
    const rel = linePrefix.startsWith(findBasePrefix) ? linePrefix.slice(findBasePrefix.length) : '';
    return actualBasePrefix + rel + l.slice(linePrefix.length);
  });
  fileLines.splice(match.start, match.end - match.start, ...shifted);
  return fileLines.join('\n');
}

/** Resolve a file argument to a stable dedup key. realpathSync requires the
 *  file to exist, which it must (we're about to read it) — falls back to
 *  path.resolve only if realpath itself throws for some other reason. This
 *  is what makes `f.js` and `./f.js` in the same batch resolve to one file
 *  instead of racing two independent writes against it. */
function realKey(file) {
  try { return fs.realpathSync(file); } catch { return path.resolve(file); }
}

function leanEdit({ edits }) {
  if (!Array.isArray(edits) || edits.length === 0) {
    return { ok: false, error: 'edits must be a non-empty array' };
  }
  for (const e of edits) {
    if (!e.find || e.find.length === 0) {
      return { ok: false, applied: 0, failures: [{ file: e.file, error: 'find must be a non-empty string (an empty find would match everywhere)' }] };
    }
  }

  // group by REAL path so multiple edits to the same file — however it was
  // spelled in the batch — resolve against each other's original positions
  // before any are applied, instead of racing two independent writes
  const byFile = new Map(); // realpath -> { displayFile, edits: [] }
  for (const e of edits) {
    const key = realKey(e.file);
    if (!byFile.has(key)) byFile.set(key, { displayFile: e.file, edits: [] });
    byFile.get(key).edits.push(e);
  }

  const plan = []; // { file, originalRaw, hadCRLF, text, resolved }
  const failures = [];

  for (const [realFile, { displayFile, edits: fileEdits }] of byFile) {
    let originalRaw;
    try { originalRaw = fs.readFileSync(realFile); } catch (e) {
      failures.push({ file: displayFile, error: `cannot read file: ${e.message}` });
      continue;
    }
    if (looksBinary(originalRaw)) {
      failures.push({ file: displayFile, error: 'file looks binary (contains a NUL byte) — refusing to edit it as text' });
      continue;
    }
    const decoded = originalRaw.toString('utf8');
    if (!Buffer.from(decoded, 'utf8').equals(originalRaw)) {
      failures.push({ file: displayFile, error: 'file is not valid UTF-8 — refusing to edit it (would corrupt bytes on write-back)' });
      continue;
    }
    const hadCRLF = decoded.includes('\r\n');
    const text = hadCRLF ? decoded.replace(/\r\n/g, '\n') : decoded; // work in LF, restore CRLF on write

    const resolved = [];
    let ok = true;
    for (const e of fileEdits) {
      const matches = findAllMatches(e.find, text, e.fuzzy === true);
      if (matches.length === 0) {
        failures.push({ file: displayFile, find: e.find.slice(0, 80), error: 'no match found' + (e.fuzzy ? ' (not even fuzzy)' : ' — pass fuzzy:true to allow approximate matches') });
        ok = false; continue;
      }
      if (matches.length > 1 && e.occurrence == null) {
        failures.push({
          file: displayFile, find: e.find.slice(0, 80),
          error: `ambiguous: ${matches.length} matches found — pass "occurrence" to disambiguate`,
          matchedLines: matches.map(m => m.start + 1)
        });
        ok = false; continue;
      }
      let chosen;
      if (e.occurrence != null) {
        chosen = matches[e.occurrence - 1];
        if (!chosen) {
          failures.push({ file: displayFile, find: e.find.slice(0, 80), error: `occurrence ${e.occurrence} out of range (${matches.length} matches)` });
          ok = false; continue;
        }
      } else {
        chosen = matches[0];
      }
      resolved.push({ edit: e, match: chosen });
    }
    if (!ok) continue;

    // Reject overlapping matches within the same file — applying both would
    // corrupt the file (one edit's line range eating into another's), and
    // there is no "correct" way to guess which one the caller meant to win.
    resolved.sort((a, b) => a.match.start - b.match.start);
    for (let i = 1; i < resolved.length; i++) {
      if (resolved[i].match.start < resolved[i - 1].match.end) {
        failures.push({
          file: displayFile,
          error: `overlapping edits: match at line ${resolved[i - 1].match.start + 1} and match at line ${resolved[i].match.start + 1} touch the same lines — split into separate calls or adjust the find text`
        });
        ok = false; break;
      }
    }
    if (!ok) continue;

    plan.push({ file: realFile, displayFile, originalRaw, hadCRLF, text, resolved });
  }

  // Collect fuzzy matches for the response BEFORE anything is written, so
  // a fuzzy match is always visible in the result — never a silent swap.
  const fuzzyUsed = [];
  for (const { displayFile, resolved } of plan) {
    for (const { match } of resolved) {
      if (match.distance > 0) fuzzyUsed.push({ file: displayFile, line: match.start + 1, distance: match.distance, matchedText: match.matchedText });
    }
  }

  // atomic: if anything anywhere failed to RESOLVE, apply nothing
  if (failures.length > 0) return { ok: false, applied: 0, failures };

  // Check writability of every target before touching anything.
  for (const { file, displayFile } of plan) {
    try { fs.accessSync(file, fs.constants.W_OK); } catch (e) {
      return { ok: false, applied: 0, failures: [{ file: displayFile, error: `file is not writable: ${e.message}` }] };
    }
  }

  // Build every file's final content in memory first — no disk writes yet.
  const writePlan = plan.map(({ file, displayFile, originalRaw, hadCRLF, text, resolved }) => {
    // apply in reverse line order so earlier matches' line numbers don't shift
    const inReverse = [...resolved].sort((a, b) => b.match.start - a.match.start);
    let out = text;
    for (const { edit, match } of inReverse) out = applyReplace(out, edit.find, edit.replace, match);
    if (hadCRLF) out = out.replace(/\n/g, '\r\n');
    return { file, displayFile, originalRaw, out, tmpPath: `${file}.leanedit-${process.pid}.tmp`, editCount: resolved.length };
  });

  // Genuinely atomic multi-file write: write every file's new content to a
  // temp path first; only once ALL temp writes succeed do we rename any of
  // them into place. If a rename fails partway through, already-renamed
  // files are rolled back to their original bytes — a real attempt at
  // "nothing changed" rather than a partially-applied batch.
  const writtenTmp = [];
  try {
    for (const wp of writePlan) { fs.writeFileSync(wp.tmpPath, wp.out); writtenTmp.push(wp); }
  } catch (e) {
    for (const wp of writtenTmp) { try { fs.unlinkSync(wp.tmpPath); } catch {} }
    return { ok: false, applied: 0, failures: [{ error: `failed while staging writes, nothing changed: ${e.message}` }] };
  }

  const renamed = [];
  try {
    for (const wp of writePlan) { fs.renameSync(wp.tmpPath, wp.file); renamed.push(wp); }
  } catch (e) {
    for (const wp of renamed) { try { fs.writeFileSync(wp.file, wp.originalRaw); } catch {} }
    for (const wp of writePlan) { try { fs.unlinkSync(wp.tmpPath); } catch {} }
    return { ok: false, applied: 0, failures: [{ error: `failed while finalizing writes — rolled back already-applied files: ${e.message}` }] };
  }

  const applied = writePlan.reduce((n, wp) => n + wp.editCount, 0);
  // REAL, not estimated: the actual byte size of every file this batch
  // touched — a normal Read-then-Edit workflow needs a full Read of each
  // file first, and we already have those bytes in hand from originalRaw.
  const vanillaReadBytes = writePlan.reduce((n, wp) => n + wp.originalRaw.length, 0);
  const result = { ok: true, applied, filesWritten: writePlan.map(wp => wp.displayFile), vanillaReadBytes };
  if (fuzzyUsed.length) result.fuzzyMatches = fuzzyUsed; // always visible, never a silent swap
  return result;
}

// ---------------------------------------------------------------------------
// MCP stdio JSON-RPC 2.0 loop
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'lean_search',
    description: 'Search files by glob pattern and content match in one call, returning ranked snippets (matched line ± context) instead of full file contents. Skips binary files. Output is capped in size (~60KB) and merges overlapping context windows, and spreads results round-robin across matched files so one noisy file can\'t crowd out the rest. Use this instead of separate Glob+Grep+Read calls.',
    inputSchema: {
      type: 'object',
      properties: {
        pattern: { type: 'string', description: 'Glob for files to search, e.g. **/*.swift' },
        query: { type: 'string', description: 'Text or regex to match within files' },
        isRegex: { type: 'boolean', default: false },
        caseInsensitive: { type: 'boolean', default: false },
        contextLines: { type: 'integer', default: 3 },
        maxResults: { type: 'integer', default: 30 },
        cwd: { type: 'string', description: 'Root directory to search from (default: server cwd)' }
      },
      required: ['pattern', 'query']
    }
  },
  {
    name: 'lean_edit',
    description: 'Apply one or more find-and-replace edits across one or more files in a single call. Matches EXACT text only by default (after whitespace/unicode-punctuation normalization) — it never guesses. Rejects with no changes made if a find text matches more than one place (pass "occurrence" to disambiguate) or if two edits in the same batch would touch overlapping lines. The whole batch is atomic: if anything fails to resolve or write, no file is changed. Set fuzzy:true on an edit to allow a small Levenshtein-distance match when no exact match exists (only for find text of 24+ characters, to avoid short strings matching the wrong nearby line) — any fuzzy match actually used is always reported back in the result, never applied silently. Use this instead of separate Read+Edit calls, especially across multiple files.',
    inputSchema: {
      type: 'object',
      properties: {
        edits: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              file: { type: 'string' },
              find: { type: 'string' },
              replace: { type: 'string' },
              occurrence: { type: 'integer', description: '1-based index to disambiguate multiple matches' },
              fuzzy: { type: 'boolean', default: false, description: 'Allow an approximate match if no exact match is found (find must be 24+ chars)' }
            },
            required: ['file', 'find', 'replace']
          }
        }
      },
      required: ['edits']
    }
  }
];

function handle(req) {
  const { id, method, params } = req;
  const reply = result => ({ jsonrpc: '2.0', id, result });
  const replyErr = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

  if (method === 'initialize') {
    return reply({
      protocolVersion: '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'fleet-lean', version: '0.1.0' }
    });
  }
  if (method === 'notifications/initialized' || method === 'notifications/cancelled') {
    return null; // no response for notifications
  }
  if (method === 'tools/list') {
    return reply({ tools: TOOLS });
  }
  if (method === 'tools/call') {
    const { name, arguments: args } = params || {};
    const before = JSON.stringify(args || {}).length;
    try {
      let out;
      if (name === 'lean_search') out = leanSearch(args || {});
      else if (name === 'lean_edit') out = leanEdit(args || {});
      else return replyErr(-32601, `unknown tool: ${name}`);

      const outStr = JSON.stringify(out);
      recordCall({
        tool: name,
        inputBytes: before,
        outputBytes: outStr.length,
        estInputTokens: estimateTokens(before),
        estOutputTokens: estimateTokens(outStr.length),
        callsAvoided: callsAvoidedFor(name, args, out),
        // REAL avoided-token estimate: tokens(bytes of the files a vanilla
        // Read would have returned in full) minus tokens(what THIS call
        // actually returned). Floored at 0 — if a call's own output
        // somehow exceeded the vanilla baseline, that's not a saving.
        // This is computed from real file bytes we already read, not a
        // guess; still an estimate only insofar as bytes/4 is (labeled
        // as such everywhere it's shown).
        estTokensAvoided: Math.max(0, estimateTokens(out.vanillaReadBytes || 0) - estimateTokens(outStr.length))
      });
      return reply({ content: [{ type: 'text', text: outStr }] });
    } catch (e) {
      return replyErr(-32000, e.message);
    }
  }
  return replyErr(-32601, `unknown method: ${method}`);
}

// ---------------------------------------------------------------------------
// fleet-lean Cloud membership — cached-only at startup, never blocks the
// server on a network call. `license.js` is the thing that actually talks
// to Dodo (on-demand, via the /fleet-lean-license command); this just reads
// whatever it last cached, so a subscriber's status here can be up to
// license.js's own offline-grace window stale. Not wired to gate anything
// yet — there is no cloud sync endpoint to gate (see plugin-lean/README.md
// for why), this only makes the cached status observable/loggable so the
// sync feature has a home to plug into once that endpoint exists.
// ---------------------------------------------------------------------------
let isCloudMember = false;
try {
  const { cachedMembership } = require('../license.js');
  isCloudMember = cachedMembership();
} catch (e) { /* license.js missing or unreadable license file — free tier, not an error */ }

// Guarded so `require()`-ing this file for unit tests doesn't also start a
// stdio loop that waits forever for input the test never sends.
if (require.main === module) {
  log('fleet-lean Cloud membership (cached):', isCloudMember ? 'active' : 'free tier');
  pruneOldSidecars();
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  rl.on('line', line => {
    if (!line.trim()) return;
    let req;
    try { req = JSON.parse(line); } catch (e) { log('bad JSON line, ignoring:', e.message); return; }
    let res;
    try { res = handle(req); } catch (e) { res = { jsonrpc: '2.0', id: req.id, error: { code: -32000, message: e.message } }; }
    if (res) process.stdout.write(JSON.stringify(res) + '\n');
  });
  rl.on('close', () => process.exit(0));
  log('fleet-lean MCP server ready, run', RUN_ID);
}

module.exports = {
  globToRegExp, normalizeForMatch, findAllMatches, applyReplace, leanSearch, leanEdit, handle,
  callsAvoidedFor, updateRollup, ROLLUP_FILE, pruneOldSidecars, SESS_DIR
};
