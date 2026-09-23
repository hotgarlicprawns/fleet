'use strict';
// Run by hard-test.sh section 14 (SERVER and E14 come from the environment).
const m = require(process.env.SERVER), fs = require('fs'), path = require('path'), assert = require('assert');
const d = process.env.E14, f = path.join(d, 'a.js'), g = path.join(d, 'b.js');
const src = 'function x() {\n  a(fmt(1));\n  return fmt(2) + fmt(3);\n}\n';
fs.writeFileSync(f, src); fs.writeFileSync(g, 'const y = fmt(9);\n');
// 1. fragment find (not a whole line) matches, like the built-in Edit tool
let r = m.leanEdit({ edits: [{ file: f, find: 'a(fmt(1))', replace: 'a(fmt(10))' }] });
assert.ok(r.ok, JSON.stringify(r));
assert.ok(fs.readFileSync(f, 'utf8').includes('  a(fmt(10));'), 'fragment edit kept the surrounding line intact');
// 2. ambiguous fragment still rejected, file untouched
const before = fs.readFileSync(f, 'utf8');
r = m.leanEdit({ edits: [{ file: f, find: 'fmt(', replace: 'money(' }] });
assert.ok(!r.ok && /ambiguous: 3 matches/.test(r.failures[0].error), JSON.stringify(r));
assert.strictEqual(fs.readFileSync(f, 'utf8'), before);
// 3. replaceAll across two files in one atomic call
r = m.leanEdit({ edits: [{ file: f, find: 'fmt(', replace: 'money(', replaceAll: true }, { file: g, find: 'fmt(', replace: 'money(', replaceAll: true }] });
assert.ok(r.ok && r.applied === 4, JSON.stringify(r));
assert.ok(!fs.readFileSync(f, 'utf8').includes('fmt(') && fs.readFileSync(g, 'utf8') === 'const y = money(9);\n');
// 4. whitespace-drifted multi-line find still falls back to the line matcher
//    (block indented deeper in the file than in the find: not a substring, same relative nesting)
fs.writeFileSync(f, 'function w() {\n  if (a) {\n    go();\n  }\n}\n');
r = m.leanEdit({ edits: [{ file: f, find: 'if (a) {\n  go();\n}', replace: 'if (b) {\n  go();\n}' }] });
assert.ok(r.ok, JSON.stringify(r));
assert.strictEqual(fs.readFileSync(f, 'utf8'), 'function w() {\n  if (b) {\n    go();\n  }\n}\n', 'replacement reindented to the file');
// 5. model-facing output is plain text, grep-style, with an explicit completeness footer
const res = m.handle({ id: 1, method: 'tools/call', params: { name: 'lean_search', arguments: { pattern: '*.js', query: 'money(', cwd: d } } });
const text = res.result.content[0].text;
assert.ok(/^b\.js:1:const y = money\(9\);$/m.test(text), text);
assert.ok(/\[complete: every match in 1 file is listed above; the other 1 scanned file have no match\]/.test(text), text);
assert.ok(!text.includes('\\"'), 'no JSON-escaped quotes in model-facing output');
const lim = m.handle({ id: 2, method: 'tools/call', params: { name: 'lean_search', arguments: { pattern: '*.js', query: 'o', maxResults: 1, cwd: d } } });
assert.ok(/INCOMPLETE: maxResults reached/.test(lim.result.content[0].text), lim.result.content[0].text);
const edit = m.handle({ id: 3, method: 'tools/call', params: { name: 'lean_edit', arguments: { edits: [{ file: g, find: 'const y', replace: 'const z' }] } } });
assert.ok(/^ok: applied 1 edit to 1 file: /.test(edit.result.content[0].text), edit.result.content[0].text);
// 6. MCP initialize carries server instructions (MCP tools are deferred; without these the model never used them)
assert.ok(/lean_search/.test(m.handle({ id: 4, method: 'initialize' }).result.instructions || ''));
console.log('ok');
