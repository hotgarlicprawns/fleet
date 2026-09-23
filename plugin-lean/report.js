#!/usr/bin/env node
'use strict';

/*
 * fleet-lean savings report — computed entirely in code, not by an LLM
 * reading JSON and doing arithmetic (an earlier version of /fleet-lean-report
 * asked Claude to sum the sidecar itself, which is exactly the kind of
 * "trust the model's mental math" step this project's own testing
 * discipline warns against — a review confirmed it could and did produce
 * inconsistent totals). This script is the single source of truth for the
 * numbers; the slash command just runs it and shows the output verbatim.
 *
 * Correlates "this session" by claudePid: a Bash tool call from Claude Code
 * runs as a direct child of the same top-level `claude` process as the
 * fleet-lean MCP server subprocess (verified empirically — both share
 * process.ppid), so this script's own process.ppid is the same key the
 * server already wrote into each sidecar. Falls back to "most recently
 * modified sidecar" ONLY if no sidecar matches that PID, and says so
 * plainly rather than silently guessing.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const CFG_DIR = path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'fleet');
const SESS_DIR = path.join(CFG_DIR, 'sessions');
const ROLLUP_FILE = path.join(CFG_DIR, 'lean-savings.json');

function listLeanSidecars() {
  let names;
  try { names = fs.readdirSync(SESS_DIR); } catch { return []; }
  return names.filter(n => n.endsWith('.lean.json')).map(n => path.join(SESS_DIR, n));
}

function readJSONSafe(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function sumCalls(calls) {
  const s = { calls: 0, callsAvoided: 0, estTokensUsed: 0, estTokensAvoided: 0, tools: {} };
  for (const c of calls || []) {
    s.calls++;
    s.callsAvoided += c.callsAvoided || 0;
    s.estTokensUsed += (c.estInputTokens || 0) + (c.estOutputTokens || 0);
    s.estTokensAvoided += c.estTokensAvoided || 0;
    s.tools[c.tool] = (s.tools[c.tool] || 0) + 1;
  }
  return s;
}

function findThisSession() {
  const files = listLeanSidecars();
  const myPid = String(process.ppid);
  const matches = files
    .map(f => ({ f, data: readJSONSafe(f) }))
    .filter(x => x.data && String(x.data.claudePid) === myPid);

  if (matches.length > 0) {
    // Normally exactly one MCP server subprocess per Claude Code session,
    // but merge defensively if more than one sidecar shares the PID.
    const allCalls = matches.flatMap(m => m.data.calls || []);
    return { calls: allCalls, correlation: 'claudePid', matchedFiles: matches.length };
  }

  // Fallback: most-recently-modified sidecar, clearly labeled as a guess.
  const withMtime = files
    .map(f => { try { return { f, mtime: fs.statSync(f).mtimeMs }; } catch { return null; } })
    .filter(Boolean)
    .sort((a, b) => b.mtime - a.mtime);
  if (withMtime.length === 0) return { calls: [], correlation: 'none', matchedFiles: 0 };
  const data = readJSONSafe(withMtime[0].f);
  return { calls: (data && data.calls) || [], correlation: 'most-recent-fallback', matchedFiles: 1 };
}

function allTimeRollup() {
  const data = readJSONSafe(ROLLUP_FILE);
  if (!data || !data.days) return { calls: 0, callsAvoided: 0, estTokensUsed: 0, estTokensAvoided: 0, days: 0 };
  const days = Object.values(data.days);
  return {
    calls: days.reduce((n, d) => n + (d.calls || 0), 0),
    callsAvoided: days.reduce((n, d) => n + (d.callsAvoided || 0), 0),
    estTokensUsed: days.reduce((n, d) => n + (d.estTokens || 0), 0),
    estTokensAvoided: days.reduce((n, d) => n + (d.estTokensAvoided || 0), 0),
    days: days.length
  };
}

function fmt(n) {
  n = Math.round(n);
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

function main() {
  const session = findThisSession();
  const s = sumCalls(session.calls);
  const all = allTimeRollup();

  const lines = [];
  lines.push('fleet-lean savings — this session' +
    (session.correlation === 'most-recent-fallback' ? ' (no matching sidecar found for this session; showing the most recently modified one instead — may belong to a different pane)' :
     session.correlation === 'none' ? ' — no fleet-lean activity recorded yet' : ''));
  lines.push('');
  lines.push(`  fleet-lean calls made:        ${s.calls}`);
  lines.push(`  built-in calls avoided:       ${s.callsAvoided}  (exact count, from the tool's own output)`);
  lines.push(`  est. tokens used by fleet-lean: ~${fmt(s.estTokensUsed)}  (bytes/4 heuristic, not exact)`);
  lines.push(`  est. tokens avoided:          ~${fmt(s.estTokensAvoided)}  (vs. reading every matched file in full —` +
    ` an upper bound, NOT a measured saving: see caveat below)`);

  lines.push('');
  lines.push(`all-time (this machine, ${all.days} day${all.days === 1 ? '' : 's'} with activity):`);
  lines.push(`  calls avoided:                ${all.callsAvoided}`);
  lines.push(`  est. tokens avoided:          ~${fmt(all.estTokensAvoided)}`);
  lines.push('');
  lines.push('CAVEAT: the "avoided" numbers compare against built-in calls Claude Code');
  lines.push('often would NOT have made (it searches with grep via Bash, not whole-file');
  lines.push('Reads). A real A/B eval (plugin-lean/eval/RESULTS.md) found fleet-lean');
  lines.push('costs ~11% MORE than plain Claude Code on typical search/edit tasks.');
  lines.push('');
  lines.push('No dollar figure: the HUD sidecar records total session cost, not a token');
  lines.push('count, so there is no $/token ratio to convert against without guessing one.');
  lines.push('(fleet hud install gives you the $ total for the session separately.)');

  console.log(lines.join('\n'));
}

// Guarded so `require()`-ing this file for tests doesn't also print a
// report as a side effect (server/index.js follows the same pattern).
if (require.main === module) main();

module.exports = { sumCalls, findThisSession, allTimeRollup, fmt };
