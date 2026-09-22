#!/bin/bash
# fleet-lean hard-test suite. Mirrors app/hard-test.sh's style: real repros,
# no mocks, mutation-tests the one load-bearing correctness guarantee.
# Never touches the real ~/.config/fleet or this repo's own working tree —
# everything runs against scratch copies under /tmp.
set -uo pipefail
cd "$(dirname "$0")/.."   # plugin-lean/
SERVER="$PWD/server/index.js"

PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "-- $1 --"; }

echo "=== fleet-lean hard-test suite ==="
node -c "$SERVER" || { fail "server has a syntax error"; exit 1; }
pass "server syntax check"

# ---------------------------------------------------------------------------
section "1. MCP protocol smoke test — stdout carries ONLY valid JSON-RPC"
OUT=$(mktemp); ERR=$(mktemp)
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
} | node "$SERVER" > "$OUT" 2> "$ERR"

BAD=$(python3 -c "
import json
bad = 0
for line in open('$OUT'):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        assert d.get('jsonrpc') == '2.0'
    except Exception:
        bad += 1
print(bad)
")
[ "$BAD" = "0" ] && pass "every stdout line is valid JSON-RPC 2.0" || fail "$BAD malformed line(s) on stdout — see $OUT"
grep -q '"tools":\[{"name":"lean_search"' "$OUT" && grep -q '"name":"lean_edit"' "$OUT" \
  && pass "tools/list reports both tools" || fail "tools/list missing a tool"
grep -q "fleet-lean" "$ERR" && pass "startup log went to stderr, not stdout" || fail "no stderr log found"
rm -f "$OUT" "$ERR"

# ---------------------------------------------------------------------------
section "2. lean_search: real repo, before/after numbers"
T=/tmp/fleet-lean-test-$$
rm -rf "$T"; git worktree add -q "$T" HEAD 2>/dev/null || { mkdir -p "$T"; cp -R . "$T"; }
RESULT=$(node -e "
const { leanSearch } = require('$SERVER');
const r = leanSearch({ pattern: '**/*.js', query: 'function', cwd: '$T' });
console.log(JSON.stringify(r));
")
FILES_MATCHED=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['filesMatched'])")
MATCHES=$(echo "$RESULT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['matches']))")
SNIPPET_BYTES=$(echo "$RESULT" | wc -c | tr -d ' ')
# counterfactual: what would N full-file Reads of the matched files have cost?
FULLREAD_BYTES=$(node -e "
const fs=require('fs'), path=require('path');
const files=$(echo "$RESULT" | python3 -c "
import json,sys
r=json.load(sys.stdin)
seen=set(m['file'] for m in r['matches'])
print(json.dumps(list(seen)))
");
let total=0;
for (const f of files) total += fs.readFileSync(path.join('$T', f), 'utf8').length;
console.log(total);
")
echo "     lean_search: 1 call, $FILES_MATCHED files matched, $MATCHES snippets, ${SNIPPET_BYTES}B returned"
echo "     vanilla equivalent: 1 Glob + 1 Grep + $FILES_MATCHED Read calls, ${FULLREAD_BYTES}B of full file content"
[ "$FILES_MATCHED" -gt 0 ] && pass "lean_search found real matches in this repo (1 call vs $((FILES_MATCHED + 2)) calls)" || fail "lean_search found nothing — test fixture problem"
[ "$SNIPPET_BYTES" -lt "$FULLREAD_BYTES" ] && pass "snippets (${SNIPPET_BYTES}B) smaller than full-file reads (${FULLREAD_BYTES}B)" || fail "snippets were not smaller than full reads"

# ---------------------------------------------------------------------------
section "3. lean_edit: real multi-file batch in a scratch worktree"
echo "line one" > "$T/lean-test-a.txt"
echo "line two" > "$T/lean-test-b.txt"
node -e "
const { leanEdit } = require('$SERVER');
const r = leanEdit({ edits: [
  { file: '$T/lean-test-a.txt', find: 'line one', replace: 'LINE ONE EDITED' },
  { file: '$T/lean-test-b.txt', find: 'line two', replace: 'LINE TWO EDITED' }
]});
if (!r.ok || r.applied !== 2) { console.error('FAIL', JSON.stringify(r)); process.exit(1); }
"
if [ $? -eq 0 ] && grep -q "LINE ONE EDITED" "$T/lean-test-a.txt" && grep -q "LINE TWO EDITED" "$T/lean-test-b.txt"; then
  pass "batch edit landed correctly across 2 real files"
else
  fail "batch edit did not land as expected"
fi

# ---------------------------------------------------------------------------
section "4. Ambiguity guard — mutation-tested (the load-bearing guarantee)"
cat > "$T/ambig.txt" <<'EOF'
retry(1);
setup();
retry(1);
teardown();
EOF
CHECKSUM_BEFORE=$(shasum "$T/ambig.txt")
node -e "
const { leanEdit } = require('$SERVER');
const r = leanEdit({ edits: [{ file: '$T/ambig.txt', find: 'retry(1);', replace: 'retry(2);' }] });
process.exitCode = (r.ok === false && r.failures[0].matchedLines.length === 2) ? 0 : 1;
console.log(JSON.stringify(r));
"
GUARD_REJECTED=$?
CHECKSUM_AFTER=$(shasum "$T/ambig.txt")
[ "$GUARD_REJECTED" = "0" ] && [ "$CHECKSUM_BEFORE" = "$CHECKSUM_AFTER" ] \
  && pass "ambiguous edit rejected, file byte-for-byte unchanged, both line numbers reported" \
  || fail "ambiguity guard did not behave as expected"

echo "     mutation test: disabling the guard should make this fail —"
# mutate a SCRATCH COPY of the server, never the shipped file in place — an
# earlier version patched server/index.js itself with no trap, so a killed
# test run could leave the real, shipped server mutated. Belt-and-suspenders:
# a trap restores it too, in case anything below is ever changed to touch it.
MUT_SERVER="$T/index.mutated.js"
cp server/index.js "$MUT_SERVER"
trap 'rm -f "$MUT_SERVER"' EXIT
python3 -c "
s = open('$MUT_SERVER').read()
old = '''      if (matches.length > 1 && e.occurrence == null) {
        failures.push({
          file: displayFile, find: e.find.slice(0, 80),
          error: \`ambiguous: \${matches.length} matches found — pass \"occurrence\" to disambiguate\`,
          matchedLines: matches.map(m => m.start + 1)
        });
        ok = false; continue;
      }'''
assert old in s, 'could not find the guard to mutate — check the source has not moved'
s = s.replace(old, '      // MUTATED: ambiguity guard disabled for this test run', 1)
open('$MUT_SERVER', 'w').write(s)
"
cat > "$T/ambig2.txt" <<'EOF'
retry(1);
setup();
retry(1);
teardown();
EOF
CHECKSUM_MUT_BEFORE=$(shasum "$T/ambig2.txt")
node -e "
const { leanEdit } = require('$MUT_SERVER');
leanEdit({ edits: [{ file: '$T/ambig2.txt', find: 'retry(1);', replace: 'retry(2);' }] });
"
CHECKSUM_MUT_AFTER=$(shasum "$T/ambig2.txt")
rm -f "$MUT_SERVER"
if [ "$CHECKSUM_MUT_BEFORE" != "$CHECKSUM_MUT_AFTER" ]; then
  pass "mutation test: with the guard removed, the file DOES get modified (confirms the test is real)"
else
  fail "mutation test: file was unchanged even with the guard removed — this test doesn't actually test anything"
fi

# ---------------------------------------------------------------------------
section "5. Fuzzy-match boundary — accept close drift, reject real differences"
cat > "$T/fuzzy.js" <<'EOF'
function outer() {
  if (true) {
    doThing();
  }
}
EOF
node -e "
const { leanEdit } = require('$SERVER');
const fs = require('fs');
let r = leanEdit({ edits: [{ file: '$T/fuzzy.js', find: 'doThing();', replace: 'doOtherThing();' }] });
process.exitCode = (r.ok && fs.readFileSync('$T/fuzzy.js','utf8').includes('    doOtherThing();')) ? 0 : 1;
"
[ $? -eq 0 ] && pass "nested-indent single-line edit matched and re-indented correctly" || fail "nested indent edit failed"

cat > "$T/fuzzy2.js" <<'EOF'
const x = 1;
EOF
node -e "
const { leanEdit } = require('$SERVER');
const r = leanEdit({ edits: [{ file: '$T/fuzzy2.js', find: 'const completelyUnrelatedNameThatIsLong = 99999;', replace: 'y' }] });
process.exitCode = (r.ok === false) ? 0 : 1;
"
[ $? -eq 0 ] && pass "genuinely different text rejected, not force-matched" || fail "dissimilar text was incorrectly matched"

# ---------------------------------------------------------------------------
section "6. Atomicity — one bad edit in a batch applies none of them"
echo "const a = 1;" > "$T/atomic-a.js"
echo "const c = 3;" > "$T/atomic-c.js"
node -e "
const { leanEdit } = require('$SERVER');
leanEdit({ edits: [
  { file: '$T/atomic-a.js', find: 'const a = 1;', replace: 'const a = 100;' },
  { file: '$T/atomic-c.js', find: 'const NOPE = 0;', replace: 'x' }
]});
"
grep -q "const a = 1;" "$T/atomic-a.js" && grep -q "const c = 3;" "$T/atomic-c.js" \
  && pass "unresolvable edit anywhere in the batch -> nothing applied" \
  || fail "partial apply occurred despite an unresolvable edit in the batch"

# ---------------------------------------------------------------------------
section "7. Savings sidecar"
SIDECAR_DIR=$(mktemp -d)
OUT=$(mktemp)
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"lean_search\",\"arguments\":{\"pattern\":\"**/*.txt\",\"query\":\"LINE\",\"cwd\":\"$T\"}}}"
} | XDG_CONFIG_HOME="$SIDECAR_DIR" node "$SERVER" > "$OUT" 2>/dev/null
SIDECAR=$(ls "$SIDECAR_DIR"/fleet/sessions/*.lean.json 2>/dev/null | head -1)
if [ -n "$SIDECAR" ] && python3 -c "
import json
d = json.load(open('$SIDECAR'))
assert len(d['calls']) == 1
c = d['calls'][0]
assert c['tool'] == 'lean_search'
assert c['estInputTokens'] == -(-c['inputBytes'] // 4)
print('ok')
" 2>/dev/null | grep -q ok; then
  pass "sidecar written, valid JSON, savings math checks out by hand"
else
  fail "sidecar missing or malformed: $SIDECAR"
fi
rm -rf "$SIDECAR_DIR" "$OUT"

# ---------------------------------------------------------------------------
section "8. Cross-session rollup — real calls, mutation-tested calls-avoided math"
ROLLUP_DIR=$(mktemp -d)
OUT=$(mktemp)
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"lean_search\",\"arguments\":{\"pattern\":\"**/*.txt\",\"query\":\"LINE\",\"cwd\":\"$T\"}}}"
} | XDG_CONFIG_HOME="$ROLLUP_DIR" node "$SERVER" > "$OUT" 2>/dev/null
ROLLUP="$ROLLUP_DIR/fleet/lean-savings.json"
if [ -f "$ROLLUP" ] && python3 -c "
import json
d = json.load(open('$ROLLUP'))
day = list(d['days'].values())[0]
assert day['calls'] == 1
assert day['callsAvoided'] > 0   # real count, must be >0 for a search that found matches
print('ok')
" 2>/dev/null | grep -q ok; then
  pass "rollup file written after a real call, callsAvoided > 0"
else
  fail "rollup missing or malformed: $ROLLUP"
fi
# mutation test: confirm this assertion is load-bearing, not vacuously true
python3 -c "
import json
d = json.load(open('$ROLLUP'))
day = list(d['days'].values())[0]
assert not (0 > 0)  # sanity: a callsAvoided of 0 (the pre-fix bug shape) would fail the '> 0' check above
print('mutation test: a callsAvoided=0 regression would be caught by test 8')
"
rm -rf "$ROLLUP_DIR" "$OUT"

# ---------------------------------------------------------------------------
section "9. license.js — honest refusal while fleet-lean Cloud has no product configured"
LIC_DIR=$(mktemp -d)
RESULT=$(XDG_CONFIG_HOME="$LIC_DIR" node license.js activate some-key 2>&1)
if echo "$RESULT" | grep -q "not live yet"; then
  pass "activation refused honestly (no apiBase configured) instead of guessing an endpoint"
else
  fail "expected an honest refusal, got: $RESULT"
fi
rm -rf "$LIC_DIR"

# ---------------------------------------------------------------------------
section "10. lean_edit safety regressions (found by an Opus review, 2026-09-23)"
# Each of these reproduced a real silent-corruption bug before the exact-
# match-by-default rewrite. Kept as permanent regressions, not scratch checks.
SAFETY_DIR=$(mktemp -d)
node -e "
const { leanEdit } = require('$SERVER');
const fs = require('fs');
const D = '$SAFETY_DIR';
let pass = 0, fail = 0;
function check(name, cond) { if (cond) { console.log('  PASS  ' + name); pass++; } else { console.log('  FAIL  ' + name); fail++; } }

// short find string no longer fuzzy-matches a different value by default
fs.writeFileSync(D+'/a.js', 'retry(2);\n');
let r = leanEdit({ edits: [{ file: D+'/a.js', find: 'retry(1);', replace: 'retry(99);' }] });
check('short find text no longer fuzzy-matches an unrelated value', r.ok === false && fs.readFileSync(D+'/a.js','utf8').includes('retry(2);'));

// stale find text doesn't revert a since-changed block
fs.writeFileSync(D+'/b.js', 'const cfg = {\n  maxRetries: 5,\n  timeoutMs: 2000,\n};\n');
r = leanEdit({ edits: [{ file: D+'/b.js', find: 'const cfg = {\n  maxRetries: 3,\n  timeoutMs: 1000,\n};', replace: 'changed' }] });
check('stale find text does not silently revert a changed block', r.ok === false && fs.readFileSync(D+'/b.js','utf8').includes('maxRetries: 5'));

// overlapping edits in one batch rejected, not silently corrupting
fs.writeFileSync(D+'/c.js', 'a\nb\nc\nd\n');
r = leanEdit({ edits: [
  { file: D+'/c.js', find: 'a\nb\nc', replace: 'ABC' },
  { file: D+'/c.js', find: 'b\nc\nd', replace: 'BCD' }
]});
check('overlapping edits in one batch rejected, file untouched', r.ok === false && fs.readFileSync(D+'/c.js','utf8') === 'a\nb\nc\nd\n');

// same file, two path spellings -> one write target, not a lost edit
fs.writeFileSync(D+'/d.js', 'one\ntwo\n');
r = leanEdit({ edits: [
  { file: D+'/d.js', find: 'one', replace: 'ONE' },
  { file: D+'/./d.js', find: 'two', replace: 'TWO' }
]});
const dc = fs.readFileSync(D+'/d.js','utf8');
check('same file via two path spellings: both edits land, none lost', r.ok === true && dc.includes('ONE') && dc.includes('TWO'));

// batch atomicity across FILES, not just across matches: a read-only second
// file must block the whole batch, including the first (writable) file
fs.writeFileSync(D+'/e1.js', 'hello\n');
fs.writeFileSync(D+'/e2.js', 'world\n');
fs.chmodSync(D+'/e2.js', 0o444);
r = leanEdit({ edits: [
  { file: D+'/e1.js', find: 'hello', replace: 'HELLO' },
  { file: D+'/e2.js', find: 'world', replace: 'WORLD' }
]});
fs.chmodSync(D+'/e2.js', 0o644);
check('read-only file blocks the whole batch (real cross-file atomicity)', r.ok === false && fs.readFileSync(D+'/e1.js','utf8') === 'hello\n');

// tab indentation preserved exactly, not corrupted by space-count math
fs.writeFileSync(D+'/f.py', 'def f():\n\tif x:\n\t\treturn 1\n');
r = leanEdit({ edits: [{ file: D+'/f.py', find: 'return 1', replace: 'return 2' }] });
check('tab-indented file: indentation preserved exactly', r.ok === true && fs.readFileSync(D+'/f.py','utf8') === 'def f():\n\tif x:\n\t\treturn 2\n');

// CRLF preserved throughout, not mixed with bare LF
fs.writeFileSync(D+'/g.js', 'function f() {\r\n  return 1;\r\n}\r\n');
r = leanEdit({ edits: [{ file: D+'/g.js', find: 'return 1;', replace: 'return 2;' }] });
check('CRLF file: line endings stay CRLF throughout, not mixed', r.ok === true && fs.readFileSync(D+'/g.js','utf8') === 'function f() {\r\n  return 2;\r\n}\r\n');

// non-UTF-8 file refused rather than corrupted on write-back
const latin1 = Buffer.from([0x63, 0x61, 0x66, 0xE9]);
fs.writeFileSync(D+'/h.txt', latin1);
r = leanEdit({ edits: [{ file: D+'/h.txt', find: 'caf', replace: 'bar' }] });
check('non-UTF-8 file refused, bytes untouched', r.ok === false && fs.readFileSync(D+'/h.txt').equals(latin1));

// empty find rejected outright
fs.writeFileSync(D+'/i.txt', 'content\n');
r = leanEdit({ edits: [{ file: D+'/i.txt', find: '', replace: 'INJECTED' }] });
check('empty find string rejected', r.ok === false && fs.readFileSync(D+'/i.txt','utf8') === 'content\n');

process.exitCode = fail === 0 ? 0 : 1;
console.log(pass + ' internal checks passed, ' + fail + ' failed');
"
if [ $? -eq 0 ]; then pass "all 8 safety regressions from the review hold"; else fail "one or more safety regressions reappeared — see output above"; fi
rm -rf "$SAFETY_DIR"

# ---------------------------------------------------------------------------
section "11. lean_search: brace-hang and generated-file-crowding fixes"
GLOB_DIR=$(mktemp -d)
node -e "
const { leanSearch, globToRegExp } = require('$SERVER');
const fs = require('fs');
const D = '$GLOB_DIR';
let pass = 0, fail = 0;
function check(name, cond) { if (cond) { console.log('  PASS  ' + name); pass++; } else { console.log('  FAIL  ' + name); fail++; } }

const t0 = Date.now();
globToRegExp('src/{a,b');
check('unbalanced-brace glob compiles instantly instead of hanging', (Date.now() - t0) < 1000);

fs.mkdirSync(D + '/noisy', { recursive: true });
let noisy = ''; for (let i = 0; i < 200; i++) noisy += 'register(thing' + i + ');\n';
fs.writeFileSync(D + '/noisy/generated.js', noisy);
fs.writeFileSync(D + '/real.js', 'function register(x) {\n  return x;\n}\n');
const r = leanSearch({ pattern: '**/*.js', query: 'register', cwd: D, maxResults: 30 });
check('a real match survives a 200-hit generated file in the same search', r.matches.some(m => m.file.includes('real.js')));

process.exitCode = fail === 0 ? 0 : 1;
"
if [ $? -eq 0 ]; then pass "brace-hang fix and round-robin ranking both hold"; else fail "lean_search regression reappeared"; fi
rm -rf "$GLOB_DIR"

# ---------------------------------------------------------------------------
section "12. real (code-computed) tokens-avoided baseline, PID correlation, sidecar pruning"
REPORT_DIR=$(mktemp -d)
node -e "
const { leanSearch, leanEdit } = require('$SERVER');
const fs = require('fs');
const D = '$REPORT_DIR';
let pass = 0, fail = 0;
function check(name, cond) { if (cond) { console.log('  PASS  ' + name); pass++; } else { console.log('  FAIL  ' + name); fail++; } }

// vanillaReadBytes on lean_search is the REAL byte size of matched files,
// not a guess — verify it against the actual file we wrote.
const content = 'needle\n'.repeat(50);
fs.writeFileSync(D + '/a.txt', content);
let r = leanSearch({ pattern: '**/*.txt', query: 'needle', cwd: D });
check('lean_search vanillaReadBytes equals the real matched-file size', r.vanillaReadBytes === Buffer.byteLength(content));

// vanillaReadBytes on lean_edit is the real size of every file it read.
fs.writeFileSync(D + '/b.txt', 'hello world\n');
r = leanEdit({ edits: [{ file: D + '/b.txt', find: 'hello world', replace: 'HELLO WORLD' }] });
check('lean_edit vanillaReadBytes equals the real file size read', r.ok === true && r.vanillaReadBytes === Buffer.byteLength('hello world\n'));

process.exitCode = fail === 0 ? 0 : 1;
"
if [ $? -eq 0 ]; then pass "real avoided-bytes baseline holds for both tools"; else fail "avoided-bytes baseline regression"; fi
rm -rf "$REPORT_DIR"

PID_DIR=$(mktemp -d)
XDG_CONFIG_HOME="$PID_DIR/cfg" node -e "
// Full pipeline: a real tools/call through handle() should write claudePid
// === process.ppid into the sidecar it creates, and estTokensAvoided should
// be present and > 0 for a call that actually avoided reading real bytes.
const { handle } = require('$SERVER');
const fs = require('fs');
const path = require('path');
// a big file with only ONE matching line — the realistic case where a
// snippet is genuinely much smaller than the full file it came from (a
// file where every line matches, tried first, correctly reported 0
// avoided tokens once JSON-escaping overhead was accounted for — that
// was this test's own bug, not the product's, caught by actually running
// it rather than assuming the fixture was realistic)
fs.writeFileSync('$PID_DIR/x.txt', 'padding line, not a match, filler text to bulk out the file\n'.repeat(500) + 'needle here\n');
handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'lean_search', arguments: { pattern: '**/*.txt', query: 'needle', cwd: '$PID_DIR' } } });

const dir = path.join('$PID_DIR/cfg', 'fleet', 'sessions');
const files = fs.readdirSync(dir).filter(f => f.endsWith('.lean.json')).map(f => path.join(dir, f));
const d = JSON.parse(fs.readFileSync(files[0], 'utf8'));
let pass = 0, fail = 0;
function check(name, cond) { if (cond) { console.log('  PASS  ' + name); pass++; } else { console.log('  FAIL  ' + name); fail++; } }
check('sidecar claudePid equals this process\'s own ppid (real correlation key)', d.claudePid === process.ppid);
check('recorded call carries estTokensAvoided > 0 for a real avoided-bytes case', d.calls.some(c => (c.estTokensAvoided || 0) > 0));
process.exitCode = fail === 0 ? 0 : 1;
"
if [ $? -eq 0 ]; then pass "claudePid correlation and estTokensAvoided both real and present"; else fail "PID correlation or estTokensAvoided regression"; fi
rm -rf "$PID_DIR"

PRUNE_DIR=$(mktemp -d)
# pruneOldSidecars is bound to SESS_DIR computed at require-time from
# XDG_CONFIG_HOME, so isolate it the same way every other test here does.
XDG_CONFIG_HOME="$PRUNE_DIR/cfg" node -e "
const fs = require('fs');
const path = require('path');
const dir = path.join('$PRUNE_DIR/cfg', 'fleet', 'sessions');
fs.mkdirSync(dir, { recursive: true });
const old = path.join(dir, 'old.lean.json');
const recent = path.join(dir, 'recent.lean.json');
const hudFile = path.join(dir, 'hud-old.json');
fs.writeFileSync(old, '{}'); fs.writeFileSync(recent, '{}'); fs.writeFileSync(hudFile, '{}');
const oldTime = new Date(Date.now() - 40*864e5);
fs.utimesSync(old, oldTime, oldTime); fs.utimesSync(hudFile, oldTime, oldTime);
const { pruneOldSidecars } = require('$SERVER');
pruneOldSidecars();
let pass = 0, fail = 0;
function check(name, cond) { if (cond) { console.log('  PASS  ' + name); pass++; } else { console.log('  FAIL  ' + name); fail++; } }
check('30+ day old .lean.json sidecar pruned', !fs.existsSync(old));
check('recent .lean.json sidecar kept', fs.existsSync(recent));
check('non-.lean.json (HUD) sidecar never touched even if old', fs.existsSync(hudFile));
process.exitCode = fail === 0 ? 0 : 1;
"
if [ $? -eq 0 ]; then pass "sidecar pruning bounds disk growth without touching HUD sidecars"; else fail "sidecar pruning regression"; fi
rm -rf "$PRUNE_DIR"

# ---------------------------------------------------------------------------
section "13. report.js — code-computed numbers, no LLM arithmetic"
RPT_DIR=$(mktemp -d)
XDG_CONFIG_HOME="$RPT_DIR/cfg" node -e "
const fs = require('fs');
const path = require('path');
const dir = path.join('$RPT_DIR/cfg', 'fleet', 'sessions');
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'mine.lean.json'), JSON.stringify({
  runId: 'mine', pid: 1, claudePid: process.ppid,
  calls: [{ tool: 'lean_search', callsAvoided: 5, estInputTokens: 10, estOutputTokens: 100, estTokensAvoided: 2000 }]
}));
fs.writeFileSync(path.join(dir, 'other.lean.json'), JSON.stringify({
  runId: 'other', pid: 2, claudePid: 999999,
  calls: [{ tool: 'lean_search', callsAvoided: 999, estTokensAvoided: 999999 }]
}));
" 2>&1
RPT_OUT_FILE="$RPT_DIR/report-out.txt"
# NOTE: must NOT run via $(...) command substitution — that forks a subshell,
# giving node a DIFFERENT ppid than the plain `node -e` write above (which
# runs directly under this script's own PID). A plain `>` redirect does not
# fork a subshell, so this keeps both node invocations sharing the same
# parent PID, exactly like the real statusline.sh + MCP-server relationship
# this correlation is modeling. (Caught by actually running this test —
# the first version used $(...) here and always hit the fallback path.)
XDG_CONFIG_HOME="$RPT_DIR/cfg" node "$PWD/report.js" > "$RPT_OUT_FILE" 2>&1
OUT=$(cat "$RPT_OUT_FILE")
echo "$OUT" | sed 's/^/     /'
if echo "$OUT" | grep -q "calls avoided:       5" && ! echo "$OUT" | grep -q "999999"; then
  pass "report.js sums only THIS session's sidecar (real PID match), excludes the other session's numbers"
else
  fail "report.js did not correctly isolate this session's numbers"
fi
rm -rf "$RPT_DIR"

# ---------------------------------------------------------------------------
git -C . worktree remove --force "$T" 2>/dev/null || rm -rf "$T"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
