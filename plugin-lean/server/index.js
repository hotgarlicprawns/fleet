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

const SESS_DIR = path.join(
  process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'),
  'fleet', 'sessions'
);
const RUN_ID = `${Date.now().toString(36)}-${crypto.randomBytes(4).toString('hex')}`;
const SIDECAR = path.join(SESS_DIR, `${RUN_ID}.lean.json`);

const estimateTokens = bytes => Math.ceil(bytes / 4); // chars/4 heuristic; no tokenizer dependency

let calls = [];
function recordCall(rec) {
  calls.push({ ts: new Date().toISOString(), ...rec });
  try {
    fs.mkdirSync(SESS_DIR, { recursive: true });
    fs.writeFileSync(SIDECAR, JSON.stringify({ runId: RUN_ID, pid: process.pid, calls }, null, 2));
  } catch (e) { log('sidecar write failed:', e.message); }
}

// ---------------------------------------------------------------------------
// lean_search — fused glob + grep + read, returns ranked snippets instead
// of full file contents.
// ---------------------------------------------------------------------------

/** Minimal glob -> RegExp. Supports ** , * , ? , {a,b} — enough for real use
 *  without pulling in a glob dependency. */
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
      const opts = glob.slice(i + 1, end).split(',').map(s => s.replace(/[.+^${}()|[\]\\]/g, '\\$&'));
      re += `(?:${opts.join('|')})`; i = end + 1;
    } else if ('.+^${}()|[]\\'.includes(c)) { re += '\\' + c; i++; }
    else { re += c; i++; }
  }
  return new RegExp('^' + re + '$');
}

const IGNORE_DIRS = new Set(['.git', 'node_modules', '.build', 'DerivedData', '.swiftpm', 'dist', 'build']);

function walk(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    if (IGNORE_DIRS.has(e.name)) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else if (e.isFile()) out.push(full);
  }
}

function leanSearch({ pattern, query, isRegex = false, contextLines = 3, maxResults = 30, cwd }) {
  const root = path.resolve(cwd || process.cwd());
  const all = [];
  walk(root, all);
  const rel = f => path.relative(root, f);
  const matcher = globToRegExp(pattern);
  const files = all.filter(f => matcher.test(rel(f)));

  const needle = isRegex ? new RegExp(query) : null;
  const results = [];
  for (const file of files) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const lines = text.split('\n');
    const hits = [];
    lines.forEach((line, idx) => {
      const isMatch = isRegex ? needle.test(line) : line.includes(query);
      if (isMatch) hits.push(idx);
    });
    if (hits.length) results.push({ file: rel(file), hits, lines });
  }
  // rank: files with more matches first
  results.sort((a, b) => b.hits.length - a.hits.length);

  const out = [];
  for (const r of results) {
    for (const lineIdx of r.hits) {
      if (out.length >= maxResults) break;
      const start = Math.max(0, lineIdx - contextLines);
      const end = Math.min(r.lines.length, lineIdx + contextLines + 1);
      out.push({
        file: r.file,
        lineNumber: lineIdx + 1,
        snippet: r.lines.slice(start, end).join('\n')
      });
    }
    if (out.length >= maxResults) break;
  }
  return { matches: out, filesScanned: files.length, filesMatched: results.length };
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
    .replace(/\t/g, '  ')             // tabs -> 2sp, comparison only
    .split('\n').map(l => l.replace(/\s+$/, '')).join('\n'); // trailing ws
}

function indentOf(line) { const m = line.match(/^[ ]*/); return m[0].length; }

/** Compares `find` (as lines) against a same-length window of `fileLines`
 *  starting at `start`. Requires exact indent-delta-from-first-line match
 *  (base indent may differ; relative nesting may not) plus a normalized
 *  text match, exact first, then within a small Levenshtein budget. */
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

function tryMatch(findLines, fileLines, start) {
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
  if (findFlat === winFlat) return { start, end: start + n, distance: 0 };

  const budget = Math.max(2, Math.floor(0.05 * findFlat.length));
  const dist = levenshtein(findFlat, winFlat);
  if (dist <= budget) return { start, end: start + n, distance: dist };
  return null;
}

/** Finds every acceptable match of `find` in `text`. Never returns "the
 *  best" match silently — callers must check length and reject on >1. */
function findAllMatches(find, text) {
  const findLines = find.split('\n');
  const fileLines = text.split('\n');
  const out = [];
  for (let start = 0; start <= fileLines.length - findLines.length; start++) {
    const m = tryMatch(findLines, fileLines, start);
    if (m) out.push(m);
  }
  // exact matches (distance 0) take priority over fuzzy ones if both exist
  const exact = out.filter(m => m.distance === 0);
  return exact.length ? exact : out;
}

function applyReplace(text, find, replace, match) {
  const fileLines = text.split('\n');
  const findLines = find.split('\n');
  const replaceLines = replace.split('\n');
  // preserve the matched block's actual base indentation, since `replace`
  // is written relative to `find`'s own indentation in the caller's head
  const actualBase = indentOf(fileLines[match.start]);
  const findBase = indentOf(findLines[0]);
  const shift = actualBase - findBase;
  // Every line's own indentation is adjusted by the same delta, including
  // the first — an earlier version exempted line 0, which silently dropped
  // its indentation whenever `replace` was written flush-left (the common
  // case for a single-line edit). Also handles negative shift (dedenting),
  // which the previous clamp-to-zero-shift version couldn't.
  const shifted = replaceLines.map(l => {
    if (shift === 0 || l.length === 0) return l;
    const curIndent = indentOf(l);
    const newIndent = Math.max(0, curIndent + shift);
    return ' '.repeat(newIndent) + l.slice(curIndent);
  });
  fileLines.splice(match.start, match.end - match.start, ...shifted);
  return fileLines.join('\n');
}

function leanEdit({ edits }) {
  if (!Array.isArray(edits) || edits.length === 0) {
    return { ok: false, error: 'edits must be a non-empty array' };
  }
  // group by file so multiple edits to the same file resolve against
  // each other's original positions before any are applied
  const byFile = new Map();
  for (const e of edits) {
    if (!byFile.has(e.file)) byFile.set(e.file, []);
    byFile.get(e.file).push(e);
  }

  const plan = []; // { file, text, matchesToApply: [{edit, match}] }
  const failures = [];

  for (const [file, fileEdits] of byFile) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (e) {
      failures.push({ file, error: `cannot read file: ${e.message}` });
      continue;
    }
    const resolved = [];
    let ok = true;
    for (const e of fileEdits) {
      const matches = findAllMatches(e.find, text);
      if (matches.length === 0) {
        failures.push({ file, find: e.find.slice(0, 80), error: 'no match found (not even fuzzy)' });
        ok = false; continue;
      }
      if (matches.length > 1 && e.occurrence == null) {
        failures.push({
          file, find: e.find.slice(0, 80),
          error: `ambiguous: ${matches.length} matches found — pass "occurrence" to disambiguate`,
          matchedLines: matches.map(m => m.start + 1)
        });
        ok = false; continue;
      }
      let chosen;
      if (e.occurrence != null) {
        chosen = matches[e.occurrence - 1];
        if (!chosen) {
          failures.push({ file, find: e.find.slice(0, 80), error: `occurrence ${e.occurrence} out of range (${matches.length} matches)` });
          ok = false; continue;
        }
      } else {
        chosen = matches[0];
      }
      resolved.push({ edit: e, match: chosen });
    }
    if (!ok) continue;
    plan.push({ file, text, resolved });
  }

  // atomic: if anything anywhere failed, apply nothing
  if (failures.length > 0) return { ok: false, applied: 0, failures };

  let applied = 0;
  const written = [];
  for (const { file, text, resolved } of plan) {
    // apply in reverse line order so earlier matches' line numbers don't shift
    resolved.sort((a, b) => b.match.start - a.match.start);
    let out = text;
    for (const { edit, match } of resolved) {
      out = applyReplace(out, edit.find, edit.replace, match);
      applied++;
    }
    fs.writeFileSync(file, out);
    written.push(file);
  }
  return { ok: true, applied, filesWritten: written };
}

// ---------------------------------------------------------------------------
// MCP stdio JSON-RPC 2.0 loop
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: 'lean_search',
    description: 'Search files by glob pattern and content match in one call, returning ranked snippets (matched line ± context) instead of full file contents. Use this instead of separate Glob+Grep+Read calls.',
    inputSchema: {
      type: 'object',
      properties: {
        pattern: { type: 'string', description: 'Glob for files to search, e.g. **/*.swift' },
        query: { type: 'string', description: 'Text or regex to match within files' },
        isRegex: { type: 'boolean', default: false },
        contextLines: { type: 'integer', default: 3 },
        maxResults: { type: 'integer', default: 30 },
        cwd: { type: 'string', description: 'Root directory to search from (default: server cwd)' }
      },
      required: ['pattern', 'query']
    }
  },
  {
    name: 'lean_edit',
    description: 'Apply one or more find-and-replace edits across one or more files in a single call. Matching tolerates whitespace/indentation and unicode punctuation look-alikes, but rejects (with no changes made) if a find text matches more than one place and no "occurrence" was given — it never guesses. Use this instead of separate Read+Edit calls, especially across multiple files.',
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
              occurrence: { type: 'integer', description: '1-based index to disambiguate multiple matches' }
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
        estOutputTokens: estimateTokens(outStr.length)
      });
      return reply({ content: [{ type: 'text', text: outStr }] });
    } catch (e) {
      return replyErr(-32000, e.message);
    }
  }
  return replyErr(-32601, `unknown method: ${method}`);
}

// Guarded so `require()`-ing this file for unit tests doesn't also start a
// stdio loop that waits forever for input the test never sends.
if (require.main === module) {
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

module.exports = { globToRegExp, normalizeForMatch, findAllMatches, applyReplace, leanSearch, leanEdit, handle };
