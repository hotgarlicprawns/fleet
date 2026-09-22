#!/usr/bin/env node
'use strict';

/*
 * fleet-lean Cloud — license activate/validate/deactivate against Dodo
 * Payments' public (no-API-key) license endpoints. Modeled directly on
 * bin/fleet.js's licenseActivate/licenseValidate/licenseDeactivate and
 * app/Sources/FleetApp/LicenseManager.swift's activate/revalidate/deactivate
 * (same 7-day offline grace, same endpoint shapes) — this is a SEPARATE
 * entitlement from Fleet Pro's one-time license: fleet-lean's core tools
 * (lean_search, lean_edit) are free forever and never check this file for
 * anything. This exists only for the optional fleet-lean Cloud subscription
 * (cross-machine savings sync) described in plugin-lean/README.md — until
 * that subscription product exists and a sync endpoint is wired up, this
 * file has nothing real to gate; it's built ahead of that so activation
 * works the moment both exist.
 *
 * Pure Node, no dependencies, same rule as server/index.js and bin/fleet.js.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const http = require('http');

const CFG_DIR = path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'fleet');
const LICENSE_FILE = path.join(CFG_DIR, 'lean-license.json');
const PRODUCT_FILE = path.join(__dirname, 'product.json');
const REQUEST_TIMEOUT_MS = 12_000; // same as LicenseManager.swift's timeout

function loadProduct() {
  const p = (() => { try { return JSON.parse(fs.readFileSync(PRODUCT_FILE, 'utf8')); } catch { return {}; } })();
  // Same override pattern as bin/fleet.js's FLEET_LICENSE_API — needed to
  // point this at Dodo's test-mode host instead of hardcoding live, e.g.
  // while testing against a real Dodo test-mode product before going live.
  if (process.env.FLEET_LICENSE_API) p.apiBase = process.env.FLEET_LICENSE_API;
  return p;
}

function loadLicense() {
  try { return JSON.parse(fs.readFileSync(LICENSE_FILE, 'utf8')); } catch { return null; }
}

function saveLicense(o) {
  fs.mkdirSync(CFG_DIR, { recursive: true });
  fs.writeFileSync(LICENSE_FILE, JSON.stringify(o, null, 2) + '\n', { mode: 0o600 });
}

function postJSON(url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = JSON.stringify(body);
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.request(u, {
      method: 'POST',
      timeout: REQUEST_TIMEOUT_MS,
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) }
    }, res => {
      let buf = ''; res.on('data', d => buf += d);
      res.on('end', () => { let p = {}; try { p = JSON.parse(buf); } catch {} resolve({ status: res.statusCode, body: p }); });
    });
    req.on('timeout', () => req.destroy(new Error(`request timed out after ${REQUEST_TIMEOUT_MS}ms`)));
    req.on('error', reject); req.write(data); req.end();
  });
}

/** Cached-only check, no network — safe to call at server startup. Honors
 *  the same 7-day offline grace as an online validate, but never refreshes
 *  it; call validate() to actually re-check with Dodo. */
function cachedMembership() {
  const lic = loadLicense();
  if (!lic || !lic.key || !lic.valid) return false;
  const last = Date.parse(lic.validatedAt || lic.activatedAt || 0);
  return Date.now() - last < 7 * 864e5;
}

async function activate(key) {
  const product = loadProduct();
  if (!product.apiBase) {
    return { ok: false, message: 'fleet-lean Cloud is not live yet — no product configured. See plugin-lean/README.md.' };
  }
  if (!key) return { ok: false, message: 'usage: activate <key>' };
  try {
    const r = await postJSON(`${product.apiBase}/licenses/activate`, { license_key: key, name: os.hostname() });
    if (r.status >= 200 && r.status < 300) {
      saveLicense({ key, instanceId: r.body.id || null, activatedAt: new Date().toISOString(), validatedAt: new Date().toISOString(), valid: true });
      return { ok: true, message: 'fleet-lean Cloud activated — thank you for supporting fleet-lean ♥' };
    }
    const m = { 403: 'key is inactive', 404: 'key not found', 422: 'activation limit reached — deactivate another device' }[r.status];
    return { ok: false, message: `activation failed (${r.status}): ${m || r.body.message || 'invalid key'}` };
  } catch (e) { return { ok: false, message: 'could not reach license server: ' + e.message }; }
}

async function validate() {
  const lic = loadLicense();
  if (!lic || !lic.key) return { ok: false, reason: 'no license on this machine' };
  const product = loadProduct();
  if (!product.apiBase) return { ok: false, reason: 'fleet-lean Cloud is not live yet — no product configured' };
  try {
    const r = await postJSON(`${product.apiBase}/licenses/validate`,
      { license_key: lic.key, license_key_instance_id: lic.instanceId || undefined });
    // Only an EXPLICIT rejection revokes the cached license: Dodo saying
    // valid:false, or 403/404 (key deactivated / not found). Any other
    // non-2xx (500, 429, a proxy hiccup) is treated the same as "couldn't
    // reach the server" below — a Dodo outage should never itself lock a
    // paying subscriber out. The prior version revoked on ANY non-2xx.
    if (r.body && r.body.valid === false) {
      saveLicense({ ...lic, valid: false });
      return { ok: false, body: r.body };
    }
    if (r.status === 403 || r.status === 404) {
      saveLicense({ ...lic, valid: false });
      return { ok: false, body: r.body };
    }
    if (r.status >= 200 && r.status < 300) {
      saveLicense({ ...lic, validatedAt: new Date().toISOString(), valid: true });
      return { ok: true, body: r.body };
    }
    // Ambiguous server error — fall back to offline grace rather than revoke.
    const grace = cachedMembership();
    return { ok: grace, offline: true, reason: `server returned ${r.status}; ${grace ? '7-day offline grace active' : 'grace expired'}` };
  } catch (e) {
    const grace = cachedMembership();
    return { ok: grace, offline: true, reason: grace ? '7-day offline grace active' : 'offline and grace expired' };
  }
}

async function deactivate() {
  const lic = loadLicense();
  if (!lic || !lic.key) return { ok: false, message: 'no fleet-lean Cloud license on this machine' };
  const product = loadProduct();
  if (!product.apiBase) return { ok: false, message: 'fleet-lean Cloud is not live yet — no product configured' };
  try {
    const body = { license_key: lic.key };
    if (lic.instanceId) body.license_key_instance_id = lic.instanceId; // omit rather than send null
    const r = await postJSON(`${product.apiBase}/licenses/deactivate`, body);
    if (r.status >= 200 && r.status < 300) {
      try { fs.unlinkSync(LICENSE_FILE); } catch {}
      return { ok: true, message: 'deactivated — a seat is freed' };
    }
    return { ok: false, message: `deactivation failed (${r.status})` };
  } catch (e) { return { ok: false, message: 'could not reach license server: ' + e.message }; }
}

module.exports = { loadLicense, saveLicense, cachedMembership, activate, validate, deactivate, LICENSE_FILE, PRODUCT_FILE };

// CLI wrapper — `node license.js activate <key>` / `validate` / `deactivate`
if (require.main === module) {
  const [, , sub, arg] = process.argv;
  (async () => {
    let r;
    if (sub === 'activate') r = await activate(arg);
    else if (sub === 'validate') r = await validate();
    else if (sub === 'deactivate') r = await deactivate();
    else { console.error('usage: license.js <activate <key>|validate|deactivate>'); process.exit(1); }
    console.log(JSON.stringify(r, null, 2));
    process.exit(r.ok ? 0 : 1);
  })();
}
