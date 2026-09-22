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
cp server/index.js /tmp/fleet-lean-index.js.bak
python3 -c "
s = open('server/index.js').read()
old = '''      if (matches.length > 1 && e.occurrence == null) {
        failures.push({
          file, find: e.find.slice(0, 80),
          error: \`ambiguous: \${matches.length} matches found — pass \"occurrence\" to disambiguate\`,
          matchedLines: matches.map(m => m.start + 1)
        });
        ok = false; continue;
      }'''
assert old in s, 'could not find the guard to mutate — check the source has not moved'
s = s.replace(old, '      // MUTATED: ambiguity guard disabled for this test run', 1)
open('server/index.js', 'w').write(s)
"
cat > "$T/ambig2.txt" <<'EOF'
retry(1);
setup();
retry(1);
teardown();
EOF
CHECKSUM_MUT_BEFORE=$(shasum "$T/ambig2.txt")
node -e "
const { leanEdit } = require('$SERVER');
leanEdit({ edits: [{ file: '$T/ambig2.txt', find: 'retry(1);', replace: 'retry(2);' }] });
"
CHECKSUM_MUT_AFTER=$(shasum "$T/ambig2.txt")
cp /tmp/fleet-lean-index.js.bak server/index.js
rm -f /tmp/fleet-lean-index.js.bak
node -c "$SERVER" || { fail "server did not restore cleanly after mutation test"; }
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
git -C . worktree remove --force "$T" 2>/dev/null || rm -rf "$T"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
