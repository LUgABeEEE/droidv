#!/usr/bin/env node
// lib/cdp-eval.mjs —— 通过 CDP WebSocket 发一条 Runtime.evaluate（零第三方依赖，Node 22+ 原生 WebSocket）
// 用法: node cdp-eval.mjs --port 9333 [--pick N | --match SUBSTR] --expr '<js>' [--timeout MS]
// 输出: 首行人类摘要，末行一行 JSON（便于 jq）

const args = process.argv.slice(2);
const opt = { port: 9333, pick: 0, match: null, expr: null, timeout: 8000 };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--port') opt.port = Number(args[++i]);
  else if (a === '--pick') opt.pick = Number(args[++i]);
  else if (a === '--match') opt.match = args[++i];
  else if (a === '--expr') opt.expr = args[++i];
  else if (a === '--timeout') opt.timeout = Number(args[++i]);
  else { console.error('unknown arg: ' + a); process.exit(2); }
}
if (!opt.expr) { console.error('--expr required'); process.exit(2); }

const base = `http://127.0.0.1:${opt.port}`;
const t0 = Date.now();

async function getJson(path) {
  const r = await fetch(base + path, { signal: AbortSignal.timeout(opt.timeout) });
  if (!r.ok) throw new Error(`HTTP ${r.status} for ${path}`);
  return r.json();
}

function pickTarget(list) {
  if (opt.match) {
    const hit = list.find((t) => (t.url || '').includes(opt.match) || (t.title || '').includes(opt.match));
    if (!hit) throw new Error(`no target matching "${opt.match}"`);
    return hit;
  }
  return list[opt.pick] || list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) || list[0];
}

async function main() {
  const list = await getJson('/json/list');
  if (!list.length) throw new Error('no targets');
  const target = pickTarget(list);
  if (!target.webSocketDebuggerUrl) throw new Error('target has no webSocketDebuggerUrl');

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const msg = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`ws timeout ${opt.timeout}ms`)), opt.timeout);
    ws.addEventListener('open', () => ws.send(JSON.stringify({
      id: 1, method: 'Runtime.evaluate',
      params: { expression: opt.expr, returnByValue: true, awaitPromise: true },
    })));
    ws.addEventListener('message', (ev) => {
      let m; try { m = JSON.parse(typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString()); } catch { return; }
      if (m.id !== 1) return;
      clearTimeout(timer); resolve(m);
    });
    ws.addEventListener('error', (e) => { clearTimeout(timer); reject(new Error('ws error: ' + (e.message || '?'))); });
    ws.addEventListener('close', () => { clearTimeout(timer); reject(new Error('ws closed before reply')); });
  });
  try { ws.close(); } catch {}
  const r = msg.result || {};
  if (r.exceptionDetails) {
    console.log(JSON.stringify({ ok: false, phase: 'evaluate', exception: r.exceptionDetails.text, ms: Date.now() - t0 }));
    process.exit(6);
  }
  const value = r.result ? r.result.value : undefined;
  console.log(`# target=${target.id} url=${JSON.stringify(target.url)} ms=${Date.now() - t0}`);
  console.log(JSON.stringify({ ok: true, targetId: target.id, url: target.url, value, ms: Date.now() - t0 }));
}

main().catch((e) => {
  console.log(JSON.stringify({ ok: false, phase: 'fatal', error: String(e && e.message || e), ms: Date.now() - t0 }));
  process.exit(5);
}).finally(() => {
  // 兜底：无论成败都别让 WS 把事件循环留住（否则 CLI 会悬挂）
  setTimeout(() => process.exit(process.exitCode || 0), 50).unref();
});
