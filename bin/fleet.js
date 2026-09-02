#!/usr/bin/env node
'use strict';

/*
 * fleet — organise multiple Claude Code terminals in one tiled screen,
 * keep the machine awake during long sessions, control the display without
 * touching your monitor arrangement, and see cost + context for every
 * session right on its pane border.
 *
 * Pure Node (no dependencies). macOS-first (tmux + caffeinate + pmset).
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const readline = require('readline');

// ---------------------------------------------------------------------------
// paths + config
// ---------------------------------------------------------------------------

const HOME = os.homedir();
const CFG_DIR = path.join(process.env.XDG_CONFIG_HOME || path.join(HOME, '.config'), 'fleet');
const CFG_FILE = path.join(CFG_DIR, 'config.json');
const STATE_FILE = path.join(CFG_DIR, 'state.json');
const LICENSE_FILE = path.join(CFG_DIR, 'license.json');
const TRIAL_FILE = path.join(CFG_DIR, 'trial.json');
const LAYOUT_FILE = path.join(CFG_DIR, 'layout.json');
const SESS_DIR = path.join(CFG_DIR, 'sessions');
const HUD_SCRIPT = path.join(__dirname, '..', 'hud', 'statusline.sh');
const GUI_HTML = path.join(__dirname, '..', 'gui', 'index.html');
const CLAUDE_SETTINGS = path.join(HOME, '.claude', 'settings.json');

const TRIAL_DAYS = 14;
const FREE_PANE_LIMIT = 3;

const DEFAULT_CONFIG = {
  session: 'fleet',
  panes: 4,                    // a number, or an array of pane objects (see README)
  layout: 'tiled',             // tiled | even-horizontal | even-vertical | main-vertical
  command: 'claude',           // default command for every pane
  cwd: HOME,
  perPaneCommands: [],
  power: {
    mode: 'awake-on',          // awake-on | awake-blank | prevent-all | off
    blankAfterMinutes: 10,     // awake-blank / fleet watch: minutes idle before the
                               // screen is allowed to blank. fleet never blanks on launch.
    releaseOnDetach: true
  },
  display: { manageArrangement: false, profileOnUp: null, profileOnDown: null },
  budget: {
    warnUsd: 5,                // pane border turns amber at this session cost
    capUsd: 15,                // …and red past this
    dailyUsd: 40               // `fleet report` flags days over this
  },
  hud: { enabled: true },       // show model · cost · context on pane borders
  templates: {},                // name → { panes:[…], layout?, power? }
  ui: { theme: 'aurora', banner: true },
  license: { productId: '', apiBase: 'https://live.dodopayments.com' }
};

const ACCENT_TMUX = {
  cyan: 'colour80', teal: 'colour80', aurora: 'colour80',
  amber: 'colour215', yellow: 'colour222', gold: 'colour178',
  green: 'colour114', magenta: 'colour177', purple: 'colour177',
  blue: 'colour110', red: 'colour203', grey: 'colour244', default: 'default'
};

function deepMerge(base, over) {
  if (Array.isArray(base) || typeof base !== 'object' || base === null) return over === undefined ? base : over;
  const out = { ...base };
  for (const k of Object.keys(over || {})) out[k] = k in base ? deepMerge(base[k], over[k]) : over[k];
  return out;
}
function loadConfig() {
  try { return deepMerge(DEFAULT_CONFIG, JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'))); }
  catch { return JSON.parse(JSON.stringify(DEFAULT_CONFIG)); }
}
function saveConfig(cfg) {
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.writeFileSync(CFG_FILE, JSON.stringify(cfg, null, 2) + '\n');
}
function loadState() { try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return {}; } }
function saveState(s) { fs.mkdirSync(CFG_DIR, { recursive: true }); fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2) + '\n'); }
function clearState() { try { fs.unlinkSync(STATE_FILE); } catch {} }
function readJSON(f) { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } }
function writeJSON(f, o) { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(o, null, 2) + '\n'); }

// ---------------------------------------------------------------------------
// theming / ui
// ---------------------------------------------------------------------------

const THEMES = {
  aurora: { a: '38;5;80', b: '38;5;177', c: '38;5;222', dim: '38;5;244', ok: '38;5;114', warn: '38;5;215', err: '38;5;203' },
  mono:   { a: '38;5;255', b: '38;5;250', c: '38;5;245', dim: '38;5;240', ok: '38;5;255', warn: '38;5;250', err: '38;5;245' },
  nord:   { a: '38;5;110', b: '38;5;109', c: '38;5;144', dim: '38;5;240', ok: '38;5;108', warn: '38;5;222', err: '38;5;167' },
  solar:  { a: '38;5;136', b: '38;5;33',  c: '38;5;166', dim: '38;5;244', ok: '38;5;64',  warn: '38;5;136', err: '38;5;160' }
};
let THEME = THEMES.aurora;
const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code, s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
const c = {
  a: s => paint(THEME.a, s), b: s => paint(THEME.b, s), c: s => paint(THEME.c, s),
  dim: s => paint(THEME.dim, s), ok: s => paint(THEME.ok, s),
  warn: s => paint(THEME.warn, s), err: s => paint(THEME.err, s), bold: s => paint('1', s)
};
const stripAnsi = s => String(s).replace(/\x1b\[[0-9;]*m/g, '');

function banner(cfg) {
  if (!cfg.ui.banner || !useColor) return;
  console.log('\n  ' + c.a('fleet') + c.dim('  ·  many terminals, one screen') + '\n');
}
function box(title, lines) {
  const w = Math.max(title.length + 4, ...lines.map(l => stripAnsi(l).length + 2), 44);
  console.log(c.dim('╭─ ') + c.b(title) + c.dim(' ' + '─'.repeat(Math.max(0, w - title.length - 3)) + '╮'));
  for (const l of lines) {
    const pad = w - stripAnsi(l).length - 1;
    console.log(c.dim('│') + ' ' + l + ' '.repeat(Math.max(0, pad)) + c.dim('│'));
  }
  console.log(c.dim('╰' + '─'.repeat(w) + '╯'));
}
function info(s) { console.log('  ' + c.b('›') + ' ' + s); }
function good(s) { console.log('  ' + c.ok('✔') + ' ' + s); }
function warn(s) { console.log('  ' + c.warn('!') + ' ' + s); }
function fail(s) { console.log('  ' + c.err('✗') + ' ' + s); }
function ask(q) {
  return new Promise(res => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question('  ' + c.b('?') + ' ' + q + ' ', a => { rl.close(); res(a.trim()); });
  });
}

// ---------------------------------------------------------------------------
// shell helpers
// ---------------------------------------------------------------------------

const has = bin => spawnSync('which', [bin], { stdio: 'ignore' }).status === 0;
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...opts });
const tmux = (args, opts = {}) => sh('tmux', args, opts);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function requireMac() {
  if (process.platform !== 'darwin') {
    fail('fleet currently supports macOS only. Linux (systemd-inhibit + tmux) is on the roadmap.');
    process.exit(1);
  }
}
function checkDeps({ needDisplayplacer = false } = {}) {
  const missing = [];
  if (!has('tmux')) missing.push('tmux');
  if (needDisplayplacer && !has('displayplacer')) missing.push('displayplacer');
  if (missing.length) {
    fail(`missing: ${missing.join(', ')}`);
    info(has('brew') ? `install:  ${c.c('brew install ' + missing.join(' '))}` : 'install Homebrew first: https://brew.sh');
    process.exit(1);
  }
}
function realpath(p) { try { return fs.realpathSync(p); } catch { return p; } }

// ---------------------------------------------------------------------------
// entitlement — license OR active trial
// ---------------------------------------------------------------------------

function trialInfo() {
  let t = readJSON(TRIAL_FILE);
  if (!t) { t = { startedAt: new Date().toISOString() }; writeJSON(TRIAL_FILE, t); }
  const days = Math.floor((Date.now() - Date.parse(t.startedAt)) / 864e5);
  return { active: days < TRIAL_DAYS, daysLeft: Math.max(0, TRIAL_DAYS - days) };
}
async function entitlement(cfg) {
  const v = await licenseValidate(cfg, { quiet: true });
  if (v.ok) return { ok: true, kind: 'pro' };
  const t = trialInfo();
  if (t.active) return { ok: true, kind: 'trial', daysLeft: t.daysLeft };
  return { ok: false, kind: 'free' };
}
async function gate(cfg, feature) {
  const e = await entitlement(cfg);
  if (e.ok) return true;
  const n = Array.isArray(cfg.panes) ? cfg.panes.length : Number(cfg.panes) || 1;
  if (feature === 'panes' && n <= FREE_PANE_LIMIT) return true;
  if (feature === 'power' && ['awake-on', 'off'].includes(cfg.power.mode)) return true;
  if (feature === 'hud') return true; // the HUD stays free forever — it's the hook
  const unlock = c.c('fleet buy');
  if (feature === 'display') fail(`saved display profiles are Pro — ${unlock}`);
  else if (feature === 'watch') fail(`smart-blank (fleet watch) is Pro — ${unlock}`);
  else warn(`Free tier: ${FREE_PANE_LIMIT} panes, awake-on/off. Unlock everything with ${unlock}`);
  return false;
}

// ---------------------------------------------------------------------------
// power / display
// ---------------------------------------------------------------------------

const POWER_FLAGS = {
  'awake-blank': ['-i', '-s'],
  'awake-on':    ['-d', '-i', '-s'],
  'prevent-all': ['-d', '-i', '-m', '-s'],
  'off':         null
};
function startPower(cfg) {
  const mode = cfg.power.mode;
  if (mode === 'off' || !POWER_FLAGS[mode]) { info('power management: ' + c.dim('off')); return; }
  const child = spawn('caffeinate', POWER_FLAGS[mode], { detached: true, stdio: 'ignore' });
  child.unref();
  const st = loadState();
  st.caffeinatePid = child.pid; st.powerMode = mode; st.startedAt = new Date().toISOString();
  saveState(st);
  good(`power: ${c.bold(mode)} ${c.dim('(caffeinate pid ' + child.pid + ')')}`);
  // awake-blank keeps the system awake but does NOT force the display off — it
  // simply doesn't hold the -d assertion, so macOS's own displaysleep applies.
  // Blanking is only ever explicit: `fleet blank`, or `fleet watch` on idle.
  if (mode === 'awake-blank') info(c.dim('display follows your macOS sleep setting; blank now with `fleet blank`'));
}
function stopPower() {
  const st = loadState();
  if (st.caffeinatePid) {
    try { process.kill(st.caffeinatePid, 'SIGTERM'); good('power locks released'); } catch {}
  }
  sh('pkill', ['-f', 'caffeinate -i']);
}
function blankDisplay() {
  const r = sh('pmset', ['displaysleepnow']);
  if (r.status === 0) good('display blanked ' + c.dim('(key/mouse to wake — arrangement untouched)'));
  else warn('could not blank display: ' + (r.stderr || '').trim());
}
function powerStatusLine() {
  const st = loadState();
  if (!st.caffeinatePid) return c.dim('inactive');
  let alive = false;
  try { process.kill(st.caffeinatePid, 0); alive = true; } catch {}
  if (!alive) return c.warn('stale');
  const since = st.startedAt ? Math.round((Date.now() - Date.parse(st.startedAt)) / 60000) : '?';
  return c.ok(st.powerMode) + c.dim(`  ·  ${since} min`);
}
function idleSeconds() {
  const out = sh('/bin/sh', ['-c', "ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF/1000000000; exit}'"]).stdout;
  return parseFloat(out) || 0;
}
function anySessionWaiting() {
  return readSessions().some(s => s.attention && (Date.now() / 1000 - s.updated) < 3600);
}
async function watchLoop(cfg) {
  requireMac();
  if (!(await gate(cfg, 'watch'))) process.exit(1);
  const mins = Number(cfg.power.blankAfterMinutes) > 0 ? Number(cfg.power.blankAfterMinutes) : 10;
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  box('fleet watch', [
    `${c.dim('idle threshold ')} ${mins} min → blank display`,
    `${c.dim('system         ')} kept awake (${cfg.power.mode === 'off' ? 'awake-blank' : cfg.power.mode})`,
    `${c.dim('wake-on        ')} a session needing your input un-blanks the screen`,
    c.dim('Ctrl-C to stop')
  ]);
  const keepMode = cfg.power.mode === 'off' ? 'awake-blank' : cfg.power.mode;
  if (!loadState().caffeinatePid) startPower({ ...cfg, power: { ...cfg.power, mode: keepMode, blankAfterMinutes: -1 } });
  process.on('SIGINT', () => { if (cfg.power.releaseOnDetach) stopPower(); process.exit(0); });

  let blanked = false;
  for (;;) {
    const idle = idleSeconds();
    if (blanked && anySessionWaiting()) {
      info('a session needs you → waking display');
      sh('caffeinate', ['-u', '-t', '1']);
      blanked = false;
    } else if (!blanked && idle >= mins * 60 && !anySessionWaiting()) {
      info(`${Math.round(idle / 60)} min idle → blanking`);
      blankDisplay(); blanked = true;
    } else if (blanked && idle < 5) {
      blanked = false;
    }
    await sleep(12000);
  }
}

// displayplacer (opt-in)
function readProfiles() { return readJSON(path.join(CFG_DIR, 'profiles.json')) || {}; }
function displaySave(name) {
  checkDeps({ needDisplayplacer: true });
  const line = (sh('displayplacer', ['list']).stdout || '').split('\n').find(l => l.startsWith('displayplacer '));
  if (!line) { fail('could not read displayplacer profile'); return; }
  const p = readProfiles(); p[name] = line.trim();
  writeJSON(path.join(CFG_DIR, 'profiles.json'), p);
  good(`saved display profile ${c.bold(name)}`);
}
function displayApply(name) {
  const p = readProfiles();
  if (!p[name]) { fail(`no display profile "${name}"`); return; }
  const r = sh('/bin/sh', ['-c', p[name]]);
  r.status === 0 ? good(`applied display profile ${c.bold(name)}`) : fail('displayplacer failed: ' + (r.stderr || '').trim());
}
function displayList() {
  checkDeps({ needDisplayplacer: true });
  const out = sh('displayplacer', ['list']).stdout || '';
  const blocks = out.split(/\n\n+/).filter(b => /Persistent screen id/.test(b));
  box('displays', blocks.map(b => {
    const id = (b.match(/Persistent screen id:\s*(\S+)/) || [])[1];
    const type = (b.match(/Type:\s*(.+)/) || [])[1] || '';
    const res = (b.match(/Resolution:\s*(.+)/) || [])[1] || '';
    const main = /main display/i.test(b) ? c.warn('  ← main') : '';
    return `${c.b((id || '?').slice(0, 8))}  ${type.padEnd(22)} ${c.dim(res)}${main}`;
  }));
  info(`built-in dead? save a good arrangement with the external as main, then:`);
  info(`  ${c.c('fleet display save office')}  →  ${c.c('fleet display apply office')} after each wake`);
}

// ---------------------------------------------------------------------------
// HUD sessions — read the sidecar files written by hud/statusline.sh
// ---------------------------------------------------------------------------

function readSessions() {
  try {
    return fs.readdirSync(SESS_DIR)
      .filter(f => f.endsWith('.json'))
      .map(f => readJSON(path.join(SESS_DIR, f)))
      .filter(Boolean);
  } catch { return []; }
}
function sessionForPath(p) {
  const rp = realpath(p);
  const base = path.basename(rp);
  const now = Date.now() / 1000;
  const cands = readSessions()
    .filter(s => s.dir && (now - (s.updated || 0)) < 8 * 3600)
    .filter(s => realpath(s.dir) === rp || path.basename(s.dir) === base);
  cands.sort((a, b) => (b.updated || 0) - (a.updated || 0));
  return cands[0] || null;
}

// `fleet paneinfo <path>` — one tmux pane-border segment. Called by tmux #().
function paneInfo(p, cfg) {
  const s = sessionForPath(p);
  if (!s) { process.stdout.write(''); return; }
  const parts = [];
  if (s.attention) parts.push('#[fg=colour80,bold]● waiting#[default]');
  else if (s.state === 'idle') parts.push('#[fg=colour244]○ idle#[default]');
  if (s.model) parts.push(String(s.model).replace(/claude-|-\d{8}$/gi, ''));
  const cost = Number(s.costUsd) || 0;
  if (cost > 0) {
    const col = cost >= (cfg.budget.capUsd || 1e9) ? 'colour203'
      : cost >= (cfg.budget.warnUsd || 1e9) ? 'colour215' : 'colour244';
    parts.push(`#[fg=${col}]$${cost.toFixed(2)}${cost >= (cfg.budget.warnUsd || 1e9) ? ' ⚠' : ''}#[default]`);
  }
  if (s.ctxPct) parts.push(`#[fg=colour244]ctx ${s.ctxPct}%#[default]`);
  process.stdout.write(parts.join(' · '));
}

// ---------------------------------------------------------------------------
// tmux layout
// ---------------------------------------------------------------------------

function sessionExists(name) { return tmux(['has-session', '-t', name], { stdio: 'ignore' }).status === 0; }

function resolvePanes(cfg) {
  if (Array.isArray(cfg.panes)) {
    return cfg.panes.map((p, i) => ({
      name: p.name || `pane ${i}`,
      cwd: (p.cwd || cfg.cwd).replace(/^~/, HOME),
      command: p.command || cfg.command,
      accent: p.accent || 'default',
      glyph: p.glyph || ''
    }));
  }
  const n = Math.max(1, Math.min(16, Number(cfg.panes) || 1));
  return Array.from({ length: n }, (_, i) => ({
    name: `pane ${i}`,
    cwd: ((cfg.perPaneCwds && cfg.perPaneCwds[i]) || cfg.cwd).replace(/^~/, HOME),
    command: (cfg.perPaneCommands && cfg.perPaneCommands[i]) || cfg.command,
    accent: 'default', glyph: ''
  }));
}

function applyBorders(name, panes, cfg) {
  tmux(['set-option', '-t', name, 'pane-border-status', 'top']);
  tmux(['set-option', '-t', name, 'status-interval', '5']);
  panes.forEach((p, i) => {
    const col = ACCENT_TMUX[p.accent] || 'default';
    const label = `${p.glyph ? p.glyph + ' ' : ''}${p.name}`;
    const stats = cfg.hud.enabled ? "  #(fleet paneinfo '#{pane_current_path}')" : '';
    const fmt = ` #[fg=${col},bold]${label}#[nobold,default]${stats} `;
    tmux(['set-option', '-p', '-t', `${name}.${i}`, 'pane-border-format', fmt]);
    tmux(['set-option', '-p', '-t', `${name}.${i}`, '@fleet_name', p.name]);
  });
}

function buildFleet(cfg, { resumeLayout, noAttach } = {}) {
  const name = cfg.session;
  const panes = resumeLayout || resolvePanes(cfg);

  if (sessionExists(name)) {
    if (noAttach) { info(`session ${c.bold(name)} already running`); return 0; }
    info(`session ${c.bold(name)} exists — attaching`); return attach(name);
  }

  info(`building ${c.bold(panes.length)} panes in ${c.bold(name)} …`);
  tmux(['new-session', '-d', '-s', name, '-c', panes[0].cwd, panes[0].command]);
  for (let i = 1; i < panes.length; i++) {
    tmux(['split-window', '-t', name, '-c', panes[i].cwd, panes[i].command]);
    tmux(['select-layout', '-t', name, 'tiled']);
  }
  tmux(['select-layout', '-t', name, cfg.layout || 'tiled']);
  tmux(['set-option', '-t', name, 'mouse', 'on']);
  tmux(['set-option', '-t', name, 'history-limit', '8000']); // gentler on memory
  applyBorders(name, panes, cfg);
  tmux(['select-pane', '-t', name + '.0']);

  writeJSON(LAYOUT_FILE, { savedAt: new Date().toISOString(), layout: cfg.layout, panes });
  saveState({ ...loadState(), session: name, panes: panes.length });
  good(`fleet ready — ${panes.length} panes` + (cfg.hud.enabled ? c.dim('  · HUD on') : ''));
  return noAttach ? 0 : attach(name);
}

// shared by the `up` command and the GUI's Launch button
async function doUp(cfg, template, { noAttach = false, noBlank = false } = {}) {
  let eff = cfg;
  if (template && cfg.templates[template]) eff = deepMerge(cfg, cfg.templates[template]);
  else if (template) throw new Error(`no template "${template}" — have: ${Object.keys(cfg.templates).join(', ') || 'none'}`);
  if (!(await gate(eff, 'panes'))) {
    if (Array.isArray(eff.panes)) eff.panes = eff.panes.slice(0, FREE_PANE_LIMIT);
    else eff.panes = Math.min(eff.panes, FREE_PANE_LIMIT);
  }
  if (!(await gate(eff, 'power'))) eff.power.mode = eff.power.mode === 'off' ? 'off' : 'awake-on';
  if (eff.display.manageArrangement && eff.display.profileOnUp && await gate(eff, 'display')) displayApply(eff.display.profileOnUp);
  startPower(noBlank ? { ...eff, power: { ...eff.power, blankAfterMinutes: -1 } } : eff);
  return buildFleet(eff, { noAttach });
}
function attach(name) {
  const inside = !!process.env.TMUX;
  const r = spawnSync('tmux', inside ? ['switch-client', '-t', name] : ['attach-session', '-t', name], { stdio: 'inherit' });
  return r.status || 0;
}
function tearDown(cfg) {
  if (sessionExists(cfg.session)) { tmux(['kill-session', '-t', cfg.session]); good(`session ${c.bold(cfg.session)} killed`); }
  else info('no fleet session running');
  if (cfg.power.releaseOnDetach) stopPower();
  if (cfg.display.manageArrangement && cfg.display.profileOnDown) displayApply(cfg.display.profileOnDown);
  clearState();
}

function nameP(cfg, idx, newName) {
  if (idx == null || !newName) { fail('usage: fleet name <pane-index> <name>'); return; }
  if (!sessionExists(cfg.session)) { fail('no fleet session running'); return; }
  const target = `${cfg.session}.${idx}`;
  const panes = tmux(['list-panes', '-t', cfg.session, '-F', '#{pane_index}']).stdout.trim().split('\n');
  if (!panes.includes(String(idx))) { fail(`no pane ${idx}`); return; }
  tmux(['set-option', '-p', '-t', target, '@fleet_name', newName]);
  const stats = cfg.hud.enabled ? "  #(fleet paneinfo '#{pane_current_path}')" : '';
  tmux(['set-option', '-p', '-t', target, 'pane-border-format', ` #[fg=default,bold]${newName}#[nobold,default]${stats} `]);
  // persist to layout
  const lay = readJSON(LAYOUT_FILE);
  if (lay && lay.panes && lay.panes[idx]) { lay.panes[idx].name = newName; writeJSON(LAYOUT_FILE, lay); }
  good(`pane ${idx} → ${c.bold(newName)}`);
}

function nextWaiting(cfg) {
  if (!sessionExists(cfg.session)) { fail('no fleet session running'); return; }
  const rows = tmux(['list-panes', '-t', cfg.session, '-F', '#{pane_index}\t#{pane_current_path}\t#{?pane_active,1,0}'])
    .stdout.trim().split('\n').map(r => r.split('\t'));
  const active = rows.findIndex(r => r[2] === '1');
  const order = [...rows.slice(active + 1), ...rows.slice(0, active + 1)];
  const hit = order.find(r => { const s = sessionForPath(r[1]); return s && s.attention; });
  if (!hit) { info('no session is waiting for input'); return; }
  tmux(['select-pane', '-t', `${cfg.session}.${hit[0]}`]);
  good(`jumped to pane ${hit[0]} ${c.dim('(waiting)')}`);
}

// ---------------------------------------------------------------------------
// report — spend across sessions
// ---------------------------------------------------------------------------

function report(cfg, span) {
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  const now = Date.now() / 1000;
  const cutoff = span === 'week' ? 7 * 864e2 : span === 'all' ? Infinity : 864e2;
  const rows = readSessions().filter(s => (now - (s.updated || 0)) < cutoff && (Number(s.costUsd) || 0) > 0);
  if (!rows.length) {
    box(`spend · ${span || 'today'}`, [c.dim('no billed sessions yet — the HUD records them once installed')]);
    info(`turn it on with  ${c.c('fleet hud install')}`);
    return;
  }
  const byDir = {};
  for (const s of rows) {
    const k = path.basename(s.dir || 'unknown');
    byDir[k] = byDir[k] || { cost: 0, n: 0, ctx: 0 };
    byDir[k].cost += Number(s.costUsd) || 0;
    byDir[k].n++;
    byDir[k].ctx = Math.max(byDir[k].ctx, s.ctxPct || 0);
  }
  const total = rows.reduce((a, s) => a + (Number(s.costUsd) || 0), 0);
  const lines = Object.entries(byDir).sort((a, b) => b[1].cost - a[1].cost).map(([k, v]) =>
    `${c.b(k.padEnd(20))} ${c.dim(String(v.n).padStart(2) + ' sess')}   ${('$' + v.cost.toFixed(2)).padStart(9)}`);
  lines.push(c.dim('─'.repeat(42)));
  const over = span !== 'week' && total > (cfg.budget.dailyUsd || 1e9);
  lines.push(`${c.bold('total'.padEnd(20))} ${''.padStart(8)}   ${(over ? c.err : c.ok)(('$' + total.toFixed(2)).padStart(9))}`);
  box(`spend · ${span || 'today'}${span !== 'week' ? '  (last 24h)' : '  (last 7 days)'}`, lines);
  if (over) warn(`over your ${c.bold('$' + cfg.budget.dailyUsd)} daily budget`);
  console.log();
}

// ---------------------------------------------------------------------------
// HUD install — wire our statusline into ~/.claude/settings.json
// ---------------------------------------------------------------------------

const HUD_INSTALLED = path.join(CFG_DIR, 'statusline.sh');
function hudInstall() {
  if (!fs.existsSync(HUD_SCRIPT)) { fail('HUD script missing at ' + HUD_SCRIPT); return; }
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.copyFileSync(HUD_SCRIPT, HUD_INSTALLED);        // copy so it survives repo moves
  fs.chmodSync(HUD_INSTALLED, 0o755);
  fs.mkdirSync(path.dirname(CLAUDE_SETTINGS), { recursive: true });
  const s = readJSON(CLAUDE_SETTINGS) || {};
  if (s.statusLine && s.statusLine.command && !s.statusLine.command.includes('fleet')) {
    const cfg = loadConfig();
    cfg._previousStatusLine = s.statusLine;
    saveConfig(cfg);
    info('saved your existing statusLine (restored on `fleet hud uninstall`)');
  }
  s.statusLine = { type: 'command', command: HUD_INSTALLED, padding: 0 };
  writeJSON(CLAUDE_SETTINGS, s);
  fs.mkdirSync(SESS_DIR, { recursive: true });
  good('HUD installed — new Claude Code sessions report model · cost · context');
  info('pane borders update every 5s; run `fleet report` for spend totals');
}
function hudUninstall() {
  const s = readJSON(CLAUDE_SETTINGS) || {};
  const cfg = loadConfig();
  if (cfg._previousStatusLine) { s.statusLine = cfg._previousStatusLine; delete cfg._previousStatusLine; saveConfig(cfg); }
  else delete s.statusLine;
  writeJSON(CLAUDE_SETTINGS, s);
  good('HUD removed from ~/.claude/settings.json');
}
function hudStatus() {
  const s = readJSON(CLAUDE_SETTINGS) || {};
  const on = !!(s.statusLine && String(s.statusLine.command || '').includes('fleet'));
  const sess = readSessions();
  box('HUD', [
    `${c.dim('installed  ')} ${on ? c.ok('yes') : c.dim('no — run `fleet hud install`')}`,
    `${c.dim('sessions   ')} ${sess.length} tracked`,
    `${c.dim('script     ')} ${c.dim(HUD_SCRIPT)}`
  ]);
  for (const x of sess.slice(0, 8)) {
    console.log(`   ${x.attention ? c.a('●') : c.dim('○')} ${c.b(path.basename(x.dir || '?').padEnd(18))} ${(x.model || '').padEnd(12)} $${(Number(x.costUsd) || 0).toFixed(2)}  ctx ${x.ctxPct || 0}%`);
  }
  console.log();
}

// ---------------------------------------------------------------------------
// tune — lighten memory pressure (GPU accel etc.)
// ---------------------------------------------------------------------------

function tune() {
  const targets = [
    ['VS Code', path.join(HOME, 'Library/Application Support/Code/User/settings.json')],
    ['Cursor', path.join(HOME, 'Library/Application Support/Cursor/User/settings.json')],
    ['VS Code Insiders', path.join(HOME, 'Library/Application Support/Code - Insiders/User/settings.json')]
  ];
  let done = 0;
  for (const [label, f] of targets) {
    if (!fs.existsSync(f)) continue;
    const s = readJSON(f) || {};
    s['terminal.integrated.gpuAcceleration'] = 'off';
    writeJSON(f, s);
    good(`${label}: terminal.integrated.gpuAcceleration → "off"`);
    done++;
  }
  if (!done) info('no VS Code / Cursor settings found — nothing to tune');
  info(`inside Claude Code you can also run  ${c.c('/terminal-setup')}`);
  info(`fleet sessions already cap tmux history at 8000 lines to save memory`);
}

// ---------------------------------------------------------------------------
// license (Dodo Payments — public endpoints, no API key)
// ---------------------------------------------------------------------------

function loadLicense() { return readJSON(LICENSE_FILE); }
function saveLicense(o) { fs.mkdirSync(CFG_DIR, { recursive: true }); fs.writeFileSync(LICENSE_FILE, JSON.stringify(o, null, 2) + '\n', { mode: 0o600 }); }
function postJSON(url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = JSON.stringify(body);
    const req = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } }, res => {
      let buf = ''; res.on('data', d => buf += d);
      res.on('end', () => { let p = {}; try { p = JSON.parse(buf); } catch {} resolve({ status: res.statusCode, body: p }); });
    });
    req.on('error', reject); req.write(data); req.end();
  });
}
async function licenseActivate(key, cfg) {
  if (!key) { fail('usage: fleet license activate <key>'); return; }
  info('activating with Dodo Payments …');
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/activate`, { license_key: key, name: os.hostname() });
    if (r.status >= 200 && r.status < 300) {
      saveLicense({ key, instanceId: r.body.id || null, activatedAt: new Date().toISOString(), valid: true });
      good('license activated — thank you for supporting fleet ♥');
    } else {
      const m = { 403: 'key is inactive', 404: 'key not found', 422: 'activation limit reached — deactivate another device' }[r.status];
      fail(`activation failed (${r.status}): ${m || r.body.message || 'invalid key'}`);
    }
  } catch (e) { fail('could not reach license server: ' + e.message); }
}
async function licenseValidate(cfg, { quiet = false } = {}) {
  const lic = loadLicense();
  if (!lic || !lic.key) return { ok: false, reason: 'no license' };
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/validate`,
      { license_key: lic.key, license_key_instance_id: lic.instanceId || undefined });
    const ok = r.status >= 200 && r.status < 300 && r.body.valid !== false;
    if (!quiet) ok ? good('license valid') : fail('license invalid: ' + (r.body.message || r.status));
    return { ok, body: r.body };
  } catch {
    const grace = Date.now() - Date.parse(lic.activatedAt || 0) < 7 * 864e5;
    if (!quiet) warn(`offline — ${grace ? '7-day grace active' : 'grace expired'}`);
    return { ok: grace, offline: true };
  }
}
async function licenseDeactivate(cfg) {
  const lic = loadLicense();
  if (!lic || !lic.key) { fail('no license on this machine'); return; }
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/deactivate`, { license_key: lic.key, license_key_instance_id: lic.instanceId });
    if (r.status >= 200 && r.status < 300) { try { fs.unlinkSync(LICENSE_FILE); } catch {} good('deactivated — a seat is freed'); }
    else fail(`deactivation failed (${r.status})`);
  } catch (e) { fail('could not reach license server: ' + e.message); }
}

// ---------------------------------------------------------------------------
// status + config
// ---------------------------------------------------------------------------

async function statusDashboard(cfg) {
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  const running = sessionExists(cfg.session);
  let rows = [];
  if (running) {
    rows = (tmux(['list-panes', '-t', cfg.session, '-F',
      '#{pane_index}\t#{pane_current_path}\t#{pane_width}x#{pane_height}\t#{?pane_active,1,}']).stdout || '')
      .trim().split('\n').filter(Boolean);
  }
  const e = await entitlement(cfg);
  const tier = e.kind === 'pro' ? c.ok('Pro') : e.kind === 'trial' ? c.warn(`Trial · ${e.daysLeft} days left`) : c.dim(`Free · ${FREE_PANE_LIMIT} panes`);
  const hudOn = (readJSON(CLAUDE_SETTINGS) || {}).statusLine;
  box('fleet', [
    `${c.dim('session  ')} ${running ? c.ok(cfg.session + ' · running') : c.dim(cfg.session + ' · stopped')}`,
    `${c.dim('panes    ')} ${running ? rows.length : (Array.isArray(cfg.panes) ? cfg.panes.length : cfg.panes)} ${c.dim('(' + cfg.layout + ')')}`,
    `${c.dim('power    ')} ${powerStatusLine()}`,
    `${c.dim('display  ')} ${cfg.display.manageArrangement ? c.warn('managed') : c.ok('untouched (safe)')}`,
    `${c.dim('HUD      ')} ${hudOn && String(hudOn.command).includes('fleet') ? c.ok('on') : c.dim('off — fleet hud install')}`,
    `${c.dim('plan     ')} ${tier}`
  ]);
  if (rows.length) {
    console.log();
    for (const r of rows) {
      const [idx, p, size, active] = r.split('\t');
      const s = sessionForPath(p);
      const name = tmux(['show-option', '-p', '-t', `${cfg.session}.${idx}`, '-v', '@fleet_name']).stdout.trim() || `pane ${idx}`;
      const mark = s && s.attention ? c.a('●') : active ? c.b('●') : c.dim('○');
      const stat = s ? c.dim(`  ${s.model || ''}  $${(Number(s.costUsd) || 0).toFixed(2)}  ctx ${s.ctxPct || 0}%${s.attention ? c.warn('  waiting') : ''}`) : '';
      console.log(`   ${mark} ${c.bold(name.padEnd(16))}${c.dim(size)}${stat}`);
    }
  }
  console.log();
  info(`${c.c('fleet up')}  ${c.c('fleet next')}  ${c.c('fleet report')}  ${c.c('fleet name <i> <name>')}  ${c.c('fleet config')}`);
  console.log();
}

async function configWizard(cfg) {
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  box('configure fleet', [c.dim('enter keeps the current value')]);
  console.log();
  if (!Array.isArray(cfg.panes)) {
    const p = await ask(`panes ${c.dim('[' + cfg.panes + ']')}`);
    if (p) cfg.panes = Math.max(1, Math.min(16, parseInt(p, 10) || cfg.panes));
  } else info(`panes: ${cfg.panes.length} named panes (edit ${c.dim(CFG_FILE)} to change)`);
  const layout = await ask(`layout — tiled / even-horizontal / even-vertical / main-vertical ${c.dim('[' + cfg.layout + ']')}`);
  if (layout) cfg.layout = layout;
  const cmd = await ask(`command per pane ${c.dim('[' + cfg.command + ']')}`);
  if (cmd) cfg.command = cmd;
  const cwd = await ask(`start directory ${c.dim('[' + cfg.cwd + ']')}`);
  if (cwd) cfg.cwd = cwd.replace(/^~/, HOME);
  const pmode = await ask(`power — awake-blank / awake-on / prevent-all / off ${c.dim('[' + cfg.power.mode + ']')}`);
  if (pmode) cfg.power.mode = pmode;
  if (cfg.power.mode === 'awake-blank') {
    const d = await ask(`blank display after N minutes, 0 = now ${c.dim('[' + cfg.power.blankAfterMinutes + ']')}`);
    if (d) cfg.power.blankAfterMinutes = parseInt(d, 10) || 0;
  }
  const wb = await ask(`budget: warn / cap USD per session ${c.dim('[' + cfg.budget.warnUsd + ' / ' + cfg.budget.capUsd + ']')}`);
  if (wb) { const m = wb.split(/[\s/]+/).map(Number); if (m[0]) cfg.budget.warnUsd = m[0]; if (m[1]) cfg.budget.capUsd = m[1]; }
  const hud = await ask(`show cost + context on pane borders? Y/n ${c.dim('[' + (cfg.hud.enabled ? 'Y' : 'n') + ']')}`);
  if (hud) cfg.hud.enabled = !/^n/i.test(hud);
  const theme = await ask(`theme — aurora / mono / nord / solar ${c.dim('[' + cfg.ui.theme + ']')}`);
  if (theme && THEMES[theme]) cfg.ui.theme = theme;
  saveConfig(cfg);
  console.log();
  good('saved to ' + c.dim(CFG_FILE));
  if (cfg.hud.enabled && !String((readJSON(CLAUDE_SETTINGS) || {}).statusLine?.command || '').includes('fleet'))
    info(`run  ${c.c('fleet hud install')}  to turn the HUD on`);
}

// ---------------------------------------------------------------------------
// gui — a local settings + status panel (127.0.0.1 only, no dependencies)
// ---------------------------------------------------------------------------

async function guiState(cfg) {
  const running = sessionExists(cfg.session);
  let panes = [];
  if (running) {
    panes = (tmux(['list-panes', '-t', cfg.session, '-F', '#{pane_index}\t#{pane_current_path}\t#{?pane_active,1,0}']).stdout || '')
      .trim().split('\n').filter(Boolean).map(r => {
        const [idx, p, active] = r.split('\t');
        const name = tmux(['show-option', '-p', '-t', `${cfg.session}.${idx}`, '-v', '@fleet_name']).stdout.trim();
        const s = sessionForPath(p) || {};
        return { idx: +idx, name: name || `pane ${idx}`, active: active === '1', path: p,
          model: s.model || null, costUsd: Number(s.costUsd) || 0, ctxPct: s.ctxPct || 0, attention: !!s.attention, state: s.state || null };
      });
  }
  const e = await entitlement(cfg);
  const st = loadState();
  return {
    config: cfg, running, panes,
    power: st.caffeinatePid ? { mode: st.powerMode, since: st.startedAt } : null,
    hud: !!((readJSON(CLAUDE_SETTINGS) || {}).statusLine && String((readJSON(CLAUDE_SETTINGS) || {}).statusLine.command || '').includes('fleet')),
    entitlement: e,
    templates: Object.keys(cfg.templates || {})
  };
}

function guiServer(cfg, { port, open }) {
  const http = require('http');
  if (!fs.existsSync(GUI_HTML)) { fail('GUI page missing at ' + GUI_HTML); return; }
  const html = fs.readFileSync(GUI_HTML);

  const send = (res, code, body, type = 'application/json') => {
    res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  const readBody = req => new Promise(r => { let b = ''; req.on('data', d => b += d); req.on('end', () => { try { r(JSON.parse(b || '{}')); } catch { r({}); } }); });

  const server = http.createServer(async (req, res) => {
    try {
      const u = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && u.pathname === '/') return send(res, 200, html, 'text/html; charset=utf-8');
      if (req.method === 'GET' && u.pathname === '/api/state') return send(res, 200, await guiState(loadConfig()));

      if (req.method === 'POST' && u.pathname === '/api/config') {
        const patch = await readBody(req);
        const merged = deepMerge(loadConfig(), patch);
        saveConfig(merged);
        return send(res, 200, { ok: true, config: merged });
      }
      if (req.method === 'POST' && u.pathname === '/api/action') {
        const { action, mode, template, idx, name } = await readBody(req);
        const cur = loadConfig();
        if (action === 'up') { try { await doUp(cur, template, { noAttach: true, noBlank: true }); } catch (e) { return send(res, 400, { error: e.message }); } }
        else if (action === 'down') tearDown(cur);
        else if (action === 'blank') blankDisplay();
        else if (action === 'power' && mode) { cur.power.mode = mode; saveConfig(cur); if (await gate(cur, 'power')) { stopPower(); startPower(cur); } }
        else if (action === 'next') nextWaiting(cur);
        else if (action === 'name' && idx != null && name) nameP(cur, String(idx), name);
        else if (action === 'hud-install') hudInstall();
        else if (action === 'hud-uninstall') hudUninstall();
        else return send(res, 400, { error: 'unknown action' });
        return send(res, 200, await guiState(loadConfig()));
      }
      send(res, 404, { error: 'not found' });
    } catch (e) { send(res, 500, { error: e.message }); }
  });

  server.listen(port, '127.0.0.1', () => {
    const url = `http://127.0.0.1:${port}`;
    banner(cfg);
    box('fleet gui', [
      `${c.dim('url    ')} ${c.c(url)}`,
      `${c.dim('bind   ')} 127.0.0.1 only — nothing is exposed to the network`,
      c.dim('Ctrl-C to stop')
    ]);
    if (open) sh('open', [url]);
  });
  return new Promise(() => {}); // run until killed
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

const HELP = `
  ${c.a('fleet')} ${c.dim('— many Claude Code terminals, one tiled screen')}

  ${c.bold('GRID')}
    fleet up [template]      build + attach the tiled fleet
    fleet resume             rebuild the last layout (names + dirs)
    fleet down               kill it, release power locks
    fleet status             dashboard — panes, cost, context, plan
    fleet name <i> <name>    rename pane i on its border
    fleet next               jump to the next session waiting for input

  ${c.bold('MONEY / CONTEXT')}
    fleet hud install        wire the cost+context HUD into Claude Code
    fleet hud status         what the HUD is tracking
    fleet report [week|all]  spend, grouped by project

  ${c.bold('POWER / DISPLAY')}
    fleet power <mode>       awake-blank | awake-on | prevent-all | off
    fleet blank              blank the display now (arrangement untouched)
    fleet watch              keep awake, auto-blank when idle, wake when a session needs you
    fleet display list       show connected displays (spot a dead built-in panel)
    fleet display save|apply <name>

  ${c.bold('SETUP')}
    fleet config             interactive settings (terminal)
    fleet gui                open the settings + status panel in a browser
    fleet tune               reduce editor memory use (GPU accel off)
    fleet doctor             check dependencies
    fleet buy                how to get Pro
    fleet license activate <key> | status | deactivate

  ${c.bold('CONFIG')}  ${c.dim(CFG_FILE)}
`;

async function main() {
  const [cmd, sub, ...rest] = process.argv.slice(2);
  const cfg = loadConfig();
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;

  switch (cmd) {
    case undefined: case 'help': case '-h': case '--help':
      console.log(HELP); break;

    case 'paneinfo':  // internal, called by tmux
      paneInfo(sub || '', cfg); break;

    case 'doctor': {
      requireMac(); banner(cfg);
      box('doctor', [
        `${has('tmux') ? c.ok('✔') : c.err('✗')} tmux`,
        `${has('caffeinate') ? c.ok('✔') : c.err('✗')} caffeinate ${c.dim('(built-in)')}`,
        `${has('pmset') ? c.ok('✔') : c.err('✗')} pmset ${c.dim('(built-in)')}`,
        `${has('displayplacer') ? c.ok('✔') : c.dim('–')} displayplacer ${c.dim('(optional)')}`,
        `${has('jq') ? c.ok('✔') : c.dim('–')} jq ${c.dim('(optional — faster HUD)')}`,
        `${has('brew') ? c.ok('✔') : c.dim('–')} brew`
      ]);
      if (!has('tmux')) info(`fix: ${c.c('brew install tmux')}`);
      break;
    }

    case 'up': {
      requireMac(); checkDeps();
      banner(cfg);
      if (sub) info(`template ${c.bold(sub)}`);
      try { process.exit(await doUp(cfg, sub)); }
      catch (e) { fail(e.message); process.exit(1); }
      break;
    }

    case '_build':  // internal — GUI Launch button (no TTY attach)
      requireMac(); checkDeps();
      try { await doUp(cfg, sub, { noAttach: true }); } catch (e) { fail(e.message); }
      break;

    case 'gui':
      requireMac();
      await guiServer(cfg, { port: Number(process.env.FLEET_PORT) || 7787, open: sub !== '--no-open' });
      break;

    case 'resume': {
      requireMac(); checkDeps();
      const lay = readJSON(LAYOUT_FILE);
      if (!lay || !lay.panes) { fail('no saved layout — run `fleet up` first'); break; }
      banner(cfg);
      startPower(cfg);
      process.exit(buildFleet({ ...cfg, layout: lay.layout || cfg.layout }, { resumeLayout: lay.panes }));
      break;
    }

    case 'down': case 'stop': requireMac(); tearDown(cfg); break;
    case 'status': case 'ls': requireMac(); await statusDashboard(cfg); break;
    case 'config': await configWizard(cfg); break;
    case 'name': requireMac(); nameP(cfg, sub, rest.join(' ')); break;
    case 'next': requireMac(); nextWaiting(cfg); break;
    case 'report': requireMac(); report(cfg, sub); break;
    case 'blank': requireMac(); blankDisplay(); break;
    case 'watch': await watchLoop(cfg); break;
    case 'tune': requireMac(); tune(); break;

    case 'hud': {
      requireMac();
      if (sub === 'install') hudInstall();
      else if (sub === 'uninstall') hudUninstall();
      else hudStatus();
      break;
    }

    case 'power': {
      requireMac();
      if (!sub || !(sub in POWER_FLAGS)) { fail('mode: ' + Object.keys(POWER_FLAGS).join(' | ')); break; }
      cfg.power.mode = sub; saveConfig(cfg);
      if (!(await gate(cfg, 'power'))) break;
      stopPower(); startPower(cfg);
      break;
    }

    case 'display': {
      requireMac();
      if (sub === 'list') displayList();
      else if (sub === 'save' && rest[0]) displaySave(rest[0]);
      else if (sub === 'apply' && rest[0]) displayApply(rest[0]);
      else fail('usage: fleet display list | save <name> | apply <name>');
      break;
    }

    case 'buy': {
      banner(cfg);
      const pid = cfg.license.productId;
      box('get fleet Pro', [
        `${c.dim('Pro unlocks ')} 4–16 panes · fleet watch · display profiles · templates`,
        `${c.dim('price       ')} one-time, see checkout`,
        `${c.dim('checkout    ')} ${pid ? c.c('https://checkout.dodopayments.com/buy/' + pid) : c.dim('(set license.productId in config)')}`,
        `${c.dim('then        ')} ${c.c('fleet license activate <key>')}`
      ]);
      const t = trialInfo();
      if (t.active) info(`your trial has ${c.bold(t.daysLeft + ' days')} left — everything is unlocked`);
      console.log();
      break;
    }

    case 'license':
      if (sub === 'activate') await licenseActivate(rest[0], cfg);
      else if (sub === 'status') {
        if (!loadLicense()) { const t = trialInfo(); t.active ? info(`Trial · ${t.daysLeft} days left`) : fail('Free tier — `fleet buy`'); }
        else await licenseValidate(cfg);
      }
      else if (sub === 'deactivate') await licenseDeactivate(cfg);
      else fail('usage: fleet license activate <key> | status | deactivate');
      break;

    default:
      fail(`unknown command: ${cmd}`); console.log(HELP); process.exit(1);
  }
}

main().catch(e => { fail(e.stack || e.message); process.exit(1); });
