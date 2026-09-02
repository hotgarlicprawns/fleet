#!/usr/bin/env node
'use strict';

/*
 * fleet — organise multiple Claude Code terminals in one tiled screen,
 * keep the machine awake during long sessions, and control the display
 * without touching your monitor arrangement.
 *
 * Pure Node (no dependencies). macOS-first (tmux + caffeinate + pmset).
 */

const { spawn, spawnSync, execSync } = require('child_process');
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

const DEFAULT_CONFIG = {
  session: 'fleet',
  panes: 4,
  layout: 'tiled',            // tiled | even-horizontal | even-vertical | main-vertical
  command: 'claude',          // command run in every pane
  cwd: HOME,                  // where each pane starts
  perPaneCommands: [],        // optional: override command for pane i
  power: {
    mode: 'awake-blank',      // awake-blank | awake-on | prevent-all | off
    blankAfterMinutes: 0,     // 0 = blank immediately when mode blanks; >0 = delay
    releaseOnDetach: true     // release power locks when the fleet session ends
  },
  display: {
    manageArrangement: false, // if false we NEVER call displayplacer — safest for
                              // laptops with a dead built-in panel
    profileOnUp: null,        // name of a saved `fleet display save <name>` profile
    profileOnDown: null
  },
  ui: {
    theme: 'aurora',          // aurora | mono | nord | solar
    banner: true
  },
  license: {
    productId: '',            // Dodo Payments product id for the paid tier
    apiBase: 'https://live.dodopayments.com'
  }
};

function deepMerge(base, over) {
  if (Array.isArray(base) || typeof base !== 'object' || base === null) return over === undefined ? base : over;
  const out = { ...base };
  for (const k of Object.keys(over || {})) {
    out[k] = k in base ? deepMerge(base[k], over[k]) : over[k];
  }
  return out;
}

function loadConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8'));
    return deepMerge(DEFAULT_CONFIG, raw);
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

function saveConfig(cfg) {
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.writeFileSync(CFG_FILE, JSON.stringify(cfg, null, 2) + '\n');
}

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}
function saveState(s) {
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2) + '\n');
}
function clearState() { try { fs.unlinkSync(STATE_FILE); } catch {} }

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

function banner(cfg) {
  if (!cfg.ui.banner || !useColor) return;
  const art = [
    '   ▟█▙  ▗▄▄▖ ▗▄▄▖ ▗▄▄▖ ▗▄▄▖',
    '  ▟█ █▙ █    █    █▄▄  █   ',
    ' ▟█▄▄▄█▙▜▄▄▖ ▜▄▄▖ █▄▄  ▜▄▄▖'
  ];
  console.log();
  console.log('  ' + c.a('fleet') + c.dim('  ·  many terminals, one screen'));
  console.log();
}

function box(title, lines) {
  const w = Math.max(title.length + 4, ...lines.map(l => stripAnsi(l).length + 2), 40);
  const top = '╭' + '─'.repeat(w) + '╮';
  const bot = '╰' + '─'.repeat(w) + '╯';
  console.log(c.dim(top.replace('─'.repeat(w), c.b(' ' + title + ' ') + c.dim('─'.repeat(w - title.length - 3)))));
  for (const l of lines) {
    const pad = w - stripAnsi(l).length - 1;
    console.log(c.dim('│') + ' ' + l + ' '.repeat(Math.max(0, pad)) + c.dim('│'));
  }
  console.log(c.dim(bot));
}
const stripAnsi = s => String(s).replace(/\x1b\[[0-9;]*m/g, '');

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

function has(bin) {
  return spawnSync('which', [bin], { stdio: 'ignore' }).status === 0;
}
function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', ...opts });
}
function tmux(args, opts = {}) {
  return sh('tmux', args, opts);
}

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
    if (has('brew')) info(`install with:  ${c.c('brew install ' + missing.join(' '))}`);
    else info('install Homebrew first: https://brew.sh');
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// power / display
// ---------------------------------------------------------------------------

// caffeinate flags:
//   -d prevent display sleep   -i prevent idle sleep
//   -m prevent disk sleep      -s prevent system sleep (on AC)
const POWER_FLAGS = {
  'awake-blank': ['-i', '-s'],   // system stays up, display allowed to sleep / be blanked
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
  st.caffeinatePid = child.pid;
  st.powerMode = mode;
  st.startedAt = new Date().toISOString();
  saveState(st);
  good(`power: ${c.bold(mode)} ${c.dim('(caffeinate pid ' + child.pid + ')')}`);

  if (mode === 'awake-blank') {
    const delay = Number(cfg.power.blankAfterMinutes) || 0;
    if (delay > 0) {
      info(`display will blank in ${delay} min ${c.dim('(system stays awake)')}`);
      // schedule a detached blank
      spawn('/bin/sh', ['-c', `sleep ${delay * 60}; pmset displaysleepnow`], { detached: true, stdio: 'ignore' }).unref();
    } else if (delay === 0) {
      blankDisplay();
    }
    // delay < 0 → caller (e.g. `fleet watch`) manages blanking itself
  }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

function idleSeconds() {
  const out = sh('/bin/sh', ['-c',
    "ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF/1000000000; exit}'"]).stdout;
  return parseFloat(out) || 0;
}

async function watchLoop(cfg) {
  requireMac();
  const mins = Number(cfg.power.blankAfterMinutes) > 0 ? Number(cfg.power.blankAfterMinutes) : 10;
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  box('fleet watch', [
    `${c.dim('idle threshold ')} ${mins} min → blank display`,
    `${c.dim('system         ')} kept awake (${cfg.power.mode === 'off' ? 'awake-blank' : cfg.power.mode})`,
    `${c.dim('display        ')} arrangement never touched`,
    c.dim('Ctrl-C to stop')
  ]);
  const keepMode = cfg.power.mode === 'off' ? 'awake-blank' : cfg.power.mode;
  if (!loadState().caffeinatePid) {
    startPower({ ...cfg, power: { ...cfg.power, mode: keepMode, blankAfterMinutes: -1 } });
  }
  process.on('SIGINT', () => { if (cfg.power.releaseOnDetach) stopPower(); process.exit(0); });

  let blanked = false;
  for (;;) {
    const idle = idleSeconds();
    if (!blanked && idle >= mins * 60) {
      info(`${Math.round(idle / 60)} min idle → blanking`);
      blankDisplay();
      blanked = true;
    } else if (blanked && idle < 5) {
      info('activity resumed');
      blanked = false;
    }
    await sleep(15000);
  }
}

function stopPower() {
  const st = loadState();
  if (st.caffeinatePid) {
    try { process.kill(st.caffeinatePid, 'SIGTERM'); good('power locks released'); }
    catch { /* already gone */ }
  }
  // also sweep any strays we may have spawned
  sh('pkill', ['-f', 'caffeinate ' + '-i']);
}

function blankDisplay() {
  const r = sh('pmset', ['displaysleepnow']);
  if (r.status === 0) good('display blanked ' + c.dim('(press a key / move mouse to wake — arrangement untouched)'));
  else warn('could not blank display: ' + (r.stderr || '').trim());
}

function powerStatusLine() {
  const st = loadState();
  if (!st.caffeinatePid) return c.dim('inactive');
  let alive = false;
  try { process.kill(st.caffeinatePid, 0); alive = true; } catch {}
  if (!alive) return c.warn('stale (process gone)');
  const since = st.startedAt ? Math.round((Date.now() - Date.parse(st.startedAt)) / 60000) : '?';
  return c.ok(st.powerMode) + c.dim(`  ·  ${since} min`);
}

// ---- displayplacer (opt-in only) ----
function displaySave(name, cfg) {
  checkDeps({ needDisplayplacer: true });
  const out = sh('displayplacer', ['list']).stdout || '';
  const line = out.split('\n').find(l => l.startsWith('displayplacer '));
  if (!line) { fail('could not read displayplacer profile'); return; }
  const profiles = readProfiles();
  profiles[name] = line.trim();
  fs.writeFileSync(path.join(CFG_DIR, 'profiles.json'), JSON.stringify(profiles, null, 2) + '\n');
  good(`saved display profile ${c.bold(name)}`);
}
function displayApply(name) {
  const profiles = readProfiles();
  if (!profiles[name]) { fail(`no display profile named "${name}"`); return; }
  const r = sh('/bin/sh', ['-c', profiles[name]]);
  if (r.status === 0) good(`applied display profile ${c.bold(name)}`);
  else fail('displayplacer failed: ' + (r.stderr || '').trim());
}
function readProfiles() {
  try { return JSON.parse(fs.readFileSync(path.join(CFG_DIR, 'profiles.json'), 'utf8')); } catch { return {}; }
}

// ---------------------------------------------------------------------------
// tmux layout
// ---------------------------------------------------------------------------

function sessionExists(name) {
  return tmux(['has-session', '-t', name], { stdio: 'ignore' }).status === 0;
}

function buildFleet(cfg) {
  const name = cfg.session;
  const n = Math.max(1, Math.min(16, Number(cfg.panes) || 1));
  const cmdFor = i => (cfg.perPaneCommands && cfg.perPaneCommands[i]) || cfg.command;

  if (sessionExists(name)) {
    info(`session ${c.bold(name)} already exists — attaching`);
    return attach(name);
  }

  info(`building ${c.bold(n)} panes in session ${c.bold(name)} …`);
  tmux(['new-session', '-d', '-s', name, '-c', cfg.cwd, cmdFor(0)]);

  for (let i = 1; i < n; i++) {
    tmux(['split-window', '-t', name, '-c', cfg.cwd, cmdFor(i)]);
    tmux(['select-layout', '-t', name, 'tiled']);
  }
  tmux(['select-layout', '-t', name, cfg.layout || 'tiled']);
  tmux(['set-option', '-t', name, 'mouse', 'on']);
  tmux(['set-option', '-t', name, 'pane-border-status', 'top']);
  tmux(['set-option', '-t', name, 'pane-border-format', ' #{pane_index} #{pane_current_command} ']);
  tmux(['select-pane', '-t', name + '.0']);

  const st = loadState();
  st.session = name;
  st.panes = n;
  saveState(st);
  good(`fleet ready — ${n} panes`);
  return attach(name);
}

function attach(name) {
  const inside = !!process.env.TMUX;
  const args = inside ? ['switch-client', '-t', name] : ['attach-session', '-t', name];
  const r = spawnSync('tmux', args, { stdio: 'inherit' });
  return r.status || 0;
}

function tearDown(cfg) {
  const name = cfg.session;
  if (sessionExists(name)) {
    tmux(['kill-session', '-t', name]);
    good(`session ${c.bold(name)} killed`);
  } else {
    info('no fleet session running');
  }
  if (cfg.power.releaseOnDetach) stopPower();
  if (cfg.display.manageArrangement && cfg.display.profileOnDown) displayApply(cfg.display.profileOnDown);
  clearState();
}

// ---------------------------------------------------------------------------
// license (Dodo Payments)
// ---------------------------------------------------------------------------

function loadLicense() {
  try { return JSON.parse(fs.readFileSync(LICENSE_FILE, 'utf8')); } catch { return null; }
}
function saveLicense(obj) {
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.writeFileSync(LICENSE_FILE, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600 });
}

function postJSON(url, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = JSON.stringify(body);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data), ...headers }
    }, res => {
      let buf = '';
      res.on('data', d => buf += d);
      res.on('end', () => {
        let parsed = {};
        try { parsed = JSON.parse(buf); } catch {}
        resolve({ status: res.statusCode, body: parsed });
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

async function licenseActivate(key, cfg) {
  if (!key) { fail('usage: fleet license activate <key>'); return; }
  const instanceName = `${os.hostname()}`;
  info('activating with Dodo Payments …');
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/activate`,
      { license_key: key, name: instanceName });
    if (r.status >= 200 && r.status < 300) {
      saveLicense({ key, instanceId: r.body.id || null, licenseKeyId: r.body.license_key_id || r.body.license_key || null, activatedAt: new Date().toISOString(), valid: true });
      good('license activated — thank you for supporting fleet ♥');
    } else {
      const msg = { 403: 'license key is inactive / cannot be activated', 404: 'license key not found', 422: 'activation limit reached — deactivate another device first' }[r.status];
      fail(`activation failed (${r.status}): ${msg || r.body.message || 'invalid key'}`);
    }
  } catch (e) {
    fail('could not reach license server: ' + e.message);
  }
}

async function licenseValidate(cfg, { quiet = false } = {}) {
  const lic = loadLicense();
  if (!lic || !lic.key) return { ok: false, reason: 'no license' };
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/validate`,
      { license_key: lic.key, license_key_instance_id: lic.instanceId || undefined });
    const ok = r.status >= 200 && r.status < 300 && (r.body.valid !== false);
    if (!quiet) ok ? good('license valid') : fail('license invalid: ' + (r.body.message || r.status));
    return { ok, body: r.body };
  } catch (e) {
    // offline grace: trust local record for 7 days
    const age = Date.now() - Date.parse(lic.activatedAt || 0);
    const grace = age < 7 * 864e5;
    if (!quiet) warn(`offline — ${grace ? 'using 7-day grace period' : 'grace expired'}`);
    return { ok: grace, offline: true };
  }
}

async function licenseDeactivate(cfg) {
  const lic = loadLicense();
  if (!lic || !lic.key) { fail('no license on this machine'); return; }
  try {
    const r = await postJSON(`${cfg.license.apiBase}/licenses/deactivate`,
      { license_key: lic.key, license_key_instance_id: lic.instanceId });
    if (r.status >= 200 && r.status < 300) { try { fs.unlinkSync(LICENSE_FILE); } catch {} good('license deactivated on this machine — a seat is freed'); }
    else fail(`deactivation failed (${r.status}): ${r.body.message || ''}`);
  } catch (e) { fail('could not reach license server: ' + e.message); }
}

const FREE_PANE_LIMIT = 2;

async function gate(cfg, feature) {
  // free tier: up to FREE_PANE_LIMIT panes, awake-on only, no display profiles
  const v = await licenseValidate(cfg, { quiet: true });
  if (v.ok) return true;
  if (feature === 'panes' && (Number(cfg.panes) || 1) <= FREE_PANE_LIMIT) return true;
  if (feature === 'power' && cfg.power.mode === 'awake-on') return true;
  if (feature === 'power' && cfg.power.mode === 'off') return true;
  if (feature === 'display') { fail('display profiles are a Pro feature — `fleet license activate <key>`'); return false; }
  warn(`Free tier: ${FREE_PANE_LIMIT} panes + "awake-on". Unlock more with ${c.c('fleet license activate <key>')}`);
  return false;
}

// ---------------------------------------------------------------------------
// status dashboard
// ---------------------------------------------------------------------------

function statusDashboard(cfg) {
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  const running = sessionExists(cfg.session);
  let paneRows = [];
  if (running) {
    const out = tmux(['list-panes', '-t', cfg.session, '-F',
      '#{pane_index}\t#{pane_current_command}\t#{pane_width}x#{pane_height}\t#{?pane_active,active,}']).stdout || '';
    paneRows = out.trim().split('\n').filter(Boolean);
  }
  const lic = loadLicense();

  box('fleet status', [
    `${c.dim('session   ')} ${running ? c.ok(cfg.session + ' · running') : c.dim(cfg.session + ' · stopped')}`,
    `${c.dim('panes     ')} ${running ? paneRows.length : cfg.panes} ${c.dim('(' + cfg.layout + ')')}`,
    `${c.dim('power     ')} ${powerStatusLine()}`,
    `${c.dim('display   ')} ${cfg.display.manageArrangement ? c.warn('arrangement managed') : c.ok('untouched (safe)')}`,
    `${c.dim('license   ')} ${lic && lic.valid ? c.ok('Pro') : c.dim('Free tier · ' + FREE_PANE_LIMIT + ' panes')}`,
    `${c.dim('theme     ')} ${cfg.ui.theme}`
  ]);

  if (paneRows.length) {
    console.log();
    for (const row of paneRows) {
      const [idx, cmd, size, active] = row.split('\t');
      const mark = active ? c.a('●') : c.dim('○');
      console.log(`   ${mark} ${c.bold('pane ' + idx)}  ${c.b(cmd)}  ${c.dim(size)}`);
    }
  }
  console.log();
  info(`commands: ${c.c('fleet up')}  ${c.c('fleet down')}  ${c.c('fleet power <mode>')}  ${c.c('fleet config')}`);
  console.log();
}

// ---------------------------------------------------------------------------
// interactive config
// ---------------------------------------------------------------------------

async function configWizard(cfg) {
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
  banner(cfg);
  box('configure fleet', [c.dim('press enter to keep the current value')]);
  console.log();

  const panes = await ask(`how many panes? ${c.dim('[' + cfg.panes + ']')}`);
  if (panes) cfg.panes = Math.max(1, Math.min(16, parseInt(panes, 10) || cfg.panes));

  const layout = await ask(`layout — tiled / even-horizontal / even-vertical / main-vertical ${c.dim('[' + cfg.layout + ']')}`);
  if (layout) cfg.layout = layout;

  const cmd = await ask(`command per pane ${c.dim('[' + cfg.command + ']')}`);
  if (cmd) cfg.command = cmd;

  const cwd = await ask(`start directory ${c.dim('[' + cfg.cwd + ']')}`);
  if (cwd) cfg.cwd = cwd.replace(/^~/, HOME);

  const pmode = await ask(`power — awake-blank / awake-on / prevent-all / off ${c.dim('[' + cfg.power.mode + ']')}`);
  if (pmode) cfg.power.mode = pmode;

  if (cfg.power.mode === 'awake-blank') {
    const d = await ask(`blank display after N minutes (0 = immediately) ${c.dim('[' + cfg.power.blankAfterMinutes + ']')}`);
    if (d) cfg.power.blankAfterMinutes = parseInt(d, 10) || 0;
  }

  const theme = await ask(`theme — aurora / mono / nord / solar ${c.dim('[' + cfg.ui.theme + ']')}`);
  if (theme && THEMES[theme]) cfg.ui.theme = theme;

  const manage = await ask(`let fleet manage display arrangement? risky on laptops with a dead panel — y/N ${c.dim('[' + (cfg.display.manageArrangement ? 'y' : 'N') + ']')}`);
  if (manage) cfg.display.manageArrangement = /^y/i.test(manage);

  saveConfig(cfg);
  console.log();
  good('saved to ' + c.dim(CFG_FILE));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

const HELP = `
  ${c.a('fleet')} ${c.dim('— many Claude Code terminals, one tiled screen')}

  ${c.bold('USAGE')}
    fleet up                 build + attach the tiled fleet (config-driven)
    fleet down               kill the fleet, release power locks
    fleet status             pretty dashboard of panes + power + license
    fleet config             interactive configuration wizard
    fleet power <mode>       awake-blank | awake-on | prevent-all | off
    fleet blank              blank the display now (arrangement untouched)
    fleet watch              keep awake + auto-blank after N min idle, restore on activity
    fleet display save <n>   save current monitor arrangement as profile <n>
    fleet display apply <n>  re-apply a saved arrangement profile
    fleet license activate <key>
    fleet license status | deactivate
    fleet doctor             check dependencies

  ${c.bold('CONFIG')}  ${c.dim(CFG_FILE)}

  ${c.bold('POWER MODES')}
    awake-blank   system stays awake, display sleeps/blanks   ${c.dim('(default, best for long runs)')}
    awake-on      nothing sleeps, screen stays on
    prevent-all   also blocks disk sleep
    off           no power management
`;

async function main() {
  const [cmd, sub, ...rest] = process.argv.slice(2);
  const cfg = loadConfig();
  THEME = THEMES[cfg.ui.theme] || THEMES.aurora;

  switch (cmd) {
    case undefined:
    case 'help': case '-h': case '--help':
      console.log(HELP); break;

    case 'doctor': {
      requireMac();
      banner(cfg);
      const rows = [
        `${has('tmux') ? c.ok('✔') : c.err('✗')} tmux`,
        `${has('caffeinate') ? c.ok('✔') : c.err('✗')} caffeinate ${c.dim('(built-in)')}`,
        `${has('pmset') ? c.ok('✔') : c.err('✗')} pmset ${c.dim('(built-in)')}`,
        `${has('displayplacer') ? c.ok('✔') : c.dim('–')} displayplacer ${c.dim('(optional — display profiles)')}`,
        `${has('brew') ? c.ok('✔') : c.dim('–')} brew`
      ];
      box('doctor', rows);
      if (!has('tmux')) info(`fix: ${c.c('brew install tmux')}`);
      break;
    }

    case 'up': {
      requireMac(); checkDeps();
      THEME = THEMES[cfg.ui.theme] || THEMES.aurora;
      banner(cfg);
      if (!(await gate(cfg, 'panes'))) { cfg.panes = Math.min(cfg.panes, FREE_PANE_LIMIT); }
      if (!(await gate(cfg, 'power'))) { cfg.power.mode = cfg.power.mode === 'off' ? 'off' : 'awake-on'; }
      if (cfg.display.manageArrangement && cfg.display.profileOnUp) {
        if (await gate(cfg, 'display')) displayApply(cfg.display.profileOnUp);
      }
      startPower(cfg);
      process.exit(buildFleet(cfg));
      break;
    }

    case 'down': case 'stop':
      requireMac();
      tearDown(cfg); break;

    case 'status': case 'ls':
      requireMac(); statusDashboard(cfg); break;

    case 'config':
      await configWizard(cfg); break;

    case 'power': {
      requireMac();
      if (!sub || !(sub in POWER_FLAGS)) { fail('mode must be: ' + Object.keys(POWER_FLAGS).join(' | ')); break; }
      cfg.power.mode = sub; saveConfig(cfg);
      if (!(await gate(cfg, 'power'))) break;
      stopPower();
      startPower(cfg);
      break;
    }

    case 'blank':
      requireMac(); blankDisplay(); break;

    case 'watch':
      await watchLoop(cfg); break;

    case 'display': {
      requireMac();
      if (sub === 'save' && rest[0]) displaySave(rest[0], cfg);
      else if (sub === 'apply' && rest[0]) displayApply(rest[0]);
      else fail('usage: fleet display save|apply <name>');
      break;
    }

    case 'license': {
      if (sub === 'activate') await licenseActivate(rest[0], cfg);
      else if (sub === 'status') {
        if (!loadLicense()) fail('no license — Free tier (' + FREE_PANE_LIMIT + ' panes). `fleet license activate <key>`');
        else await licenseValidate(cfg);
      }
      else if (sub === 'deactivate') await licenseDeactivate(cfg);
      else fail('usage: fleet license activate <key> | status | deactivate');
      break;
    }

    default:
      fail(`unknown command: ${cmd}`);
      console.log(HELP);
      process.exit(1);
  }
}

main().catch(e => { fail(e.stack || e.message); process.exit(1); });
