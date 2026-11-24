// Tolerant parser for `opencode run --format json` event streams.
// Never invents values: unknown fields are emitted as null.
// Usage: node parse_events.js <events.jsonl> <out.json>
const fs = require('fs');

const inFile = process.argv[2];
const outFile = process.argv[3];
if (!inFile || !outFile) { console.error('usage: node parse_events.js <events.jsonl> <out.json>'); process.exit(2); }

// PowerShell 5.1 writes redirected streams as UTF-16LE; accept both encodings.
let raw = '';
if (fs.existsSync(inFile)) {
  const buf = fs.readFileSync(inFile);
  if (buf.length >= 2 && buf[0] === 0xFF && buf[1] === 0xFE) raw = buf.toString('utf16le');
  else if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) raw = buf.toString('utf8').slice(1);
  else raw = buf.toString('utf8');
}
const events = [];
for (const line of raw.split(/\r?\n/)) {
  if (!line.trim()) continue;
  try { events.push(JSON.parse(line)); } catch (_) { /* partial line / non-json */ }
}

function walk(obj, fn, path) {
  if (!obj || typeof obj !== 'object') return;
  fn(obj, path || '');
  for (const k of Object.keys(obj)) walk(obj[k], fn, (path || '') + '/' + k);
}

function tsOf(o) {
  if (!o || typeof o !== 'object') return null;
  for (const k of ['timestamp', 'time', 'created_at', 'ts', 'at']) {
    const v = o[k];
    if (typeof v === 'number' && isFinite(v)) return v < 1e12 ? v * 1000 : v;
    if (typeof v === 'string') { const n = Date.parse(v); if (!isNaN(n)) return n; }
  }
  return null;
}

let usage = null;
const toolNames = {};
let toolCalls = 0;
let firstEventTs = null, lastEventTs = null, firstTextTs = null;
const editSteps = [], testSteps = [];

for (const e of events) {
  const t = tsOf(e);
  if (t != null) {
    if (firstEventTs == null || t < firstEventTs) firstEventTs = t;
    if (lastEventTs == null || t > lastEventTs) lastEventTs = t;
  }

  // V2 step_finish events carry PER-STEP deltas, not cumulative totals.
  // Sum them once per event (no nested double counting).
  const cand = (e.part && typeof e.part === 'object' && e.part.tokens) ? e.part.tokens
             : (e.tokens && typeof e.tokens === 'object') ? e.tokens
             : (e.usage && typeof e.usage === 'object') ? e.usage : null;
  if (cand) {
    if (!usage) usage = { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 };
    const add = (k, ...names) => {
      for (const n of names) if (typeof cand[n] === 'number') { usage[k] += cand[n]; return; }
    };
    add('input', 'input', 'prompt_tokens');
    add('output', 'output', 'completion_tokens');
    add('reasoning', 'reasoning', 'reasoning_tokens');
    const c = cand.cache || {};
    if (typeof c.read === 'number') usage.cache_read += c.read;
    if (typeof c.write === 'number') usage.cache_write += c.write;
  }

  // tool calls
  const typ = String(e.type || e.kind || e.event || '');
  let name = e.tool || e.toolName || (e.part && (e.part.tool || e.part.toolName)) || null;
  if (!name && e.function && e.function.name) name = e.function.name;
  const looksTool = /tool[-_]?(call|use|start|invoke)/i.test(typ) || (name && (e.args || e.input || e.arguments));
  if (looksTool) {
    toolCalls++;
    const n = String(name || 'unknown');
    toolNames[n] = (toolNames[n] || 0) + 1;
    if (/write|edit|patch|apply/i.test(n)) editSteps.push(t == null ? null : t);
    if (/shell|bash|exec|test|python|node|npm/i.test(n)) testSteps.push(t == null ? null : t);
  }

  // first assistant text delta
  if (firstTextTs == null) {
    walk(e, (o, p) => {
      if (firstTextTs != null) return;
      const v = o.delta != null ? o.delta : o.text;
      if (typeof v === 'string' && v.trim().length > 0 && !/tool|input|arguments/i.test(p)) {
        firstTextTs = tsOf(e);
      }
    });
  }
}

function num(...keys) {
  if (!usage) return null;
  for (const k of keys) {
    if (usage[k] != null && typeof usage[k] === 'number') return usage[k];
    if (usage.cache && usage.cache[k] != null && typeof usage.cache[k] === 'number') return usage.cache[k];
  }
  return null;
}

// heuristic repair attempts: count edit events after the first test event
const firstTest = testSteps.find(x => x != null);
const repairs = editSteps.filter(x => x != null && firstTest != null && x > firstTest).length;

const out = {
  events: events.length,
  first_event_ms: firstEventTs,
  last_event_ms: lastEventTs,
  ttft_ms: (firstEventTs != null && firstTextTs != null) ? Math.max(0, firstTextTs - firstEventTs) : null,
  first_text_ms: firstTextTs,
  tool_calls: toolCalls,
  tool_names: toolNames,
  edit_calls: editSteps.length,
  test_calls: testSteps.length,
  repair_attempts_heuristic: firstTest != null ? repairs : null,
  tokens: {
    input: num('input', 'prompt_tokens', 'inputTokens'),
    output: num('output', 'completion_tokens', 'outputTokens'),
    reasoning: num('reasoning', 'reasoning_tokens'),
    cache_read: num('cache_read', 'cacheRead', 'read'),
    cache_write: num('cache_write', 'cacheWrite', 'write'),
  },
  note: 'null means the JSON event stream did not expose that metric; no values were estimated.',
};

fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n');
console.log(JSON.stringify({ events: out.events, tool_calls: out.tool_calls, ttft_ms: out.ttft_ms }));
