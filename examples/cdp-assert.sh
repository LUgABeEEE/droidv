#!/usr/bin/env bash
# cdp-assert.sh —— 用断言代替截图：一次 CDP 求值，判「页面里有没有 / 元素够不够大 / URL 对不对」
#
# 为什么不是截图：截图 515 ms + 人读 5–20 s，而且「看起来没问题」不是判据；
# CDP Runtime.evaluate 一次 ~177 ms，拿到的是 DOM 与几何事实，可以直接用退出码回答。
#
# 用法:
#   examples/cdp-assert.sh --find "设置"                 # 页面里必须出现这段文本
#   examples/cdp-assert.sh --find "保存" --max-small 0   # 且不允许存在 <44dp 的触控目标
#   examples/cdp-assert.sh --url /settings --pkg com.example.app.debug --serial <serial>
#
# 注意：`dv cdp` 要求包名（--pkg / DV_PKG / dv.conf 的 CONF_PKG），所以通常必须给 --pkg，否则 dv 直接 exit 2。
#
# 退出码: 0 断言全过 · 1 断言失败 · 2 参数错误 · 3/5/6 透传 dv（无设备/通道不可用/认领失败）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DV="${DV:-$HERE/../dv}"

FIND=""; URL_SUB=""; MIN_TAP=44; MAX_SMALL=""; PKG=""; SERIAL=""; PORT=""

die() { printf '✘ %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --find) FIND="${2:-}"; shift 2 ;;
    --url) URL_SUB="${2:-}"; shift 2 ;;
    --min-tap) MIN_TAP="${2:-44}"; shift 2 ;;
    --max-small) MAX_SMALL="${2:-}"; shift 2 ;;
    --pkg) PKG="${2:-}"; shift 2 ;;
    --serial) SERIAL="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "不认识的参数：$1（-h 看用法）" ;;
  esac
done

[ -n "$FIND$URL_SUB$MAX_SMALL" ] || die "至少给一个断言：--find / --url / --max-small"

# 全局选项必须写在子命令之前（见 docs/redlines.md 第 3 条）
G=(--json)
[ -n "$SERIAL" ] && G+=(--serial "$SERIAL")
[ -n "$PKG" ] && G+=(--pkg "$PKG")

# 把用户文本安全地塞进 JS：走 JSON 编码，避免引号/反斜杠把表达式搞坏
js_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
FIND_JS="$(js_str "$FIND")"
URL_JS="$(js_str "$URL_SUB")"

IFS= read -r -d '' EXPR <<JS || true
JSON.stringify((() => {
  const small = [...document.querySelectorAll('button,[role=button],input,select,textarea,a[href]')]
    .filter(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && Math.min(r.width, r.height) < $MIN_TAP; })
    .map(e => { const r = e.getBoundingClientRect();
                return { t: (e.textContent || e.getAttribute('aria-label') || '').trim().slice(0, 24),
                         w: Math.round(r.width), h: Math.round(r.height) }; });
  const body = document.body ? document.body.innerText : '';
  return {
    url: location.href,
    title: document.title,
    nodes: document.querySelectorAll('*').length,
    found: $FIND_JS ? body.includes($FIND_JS) : null,
    url_ok: $URL_JS ? location.href.includes($URL_JS) : null,
    small: small.slice(0, 10),
    small_count: small.length,
  };
})())
JS

OUT="$( "$DV" "${G[@]}" cdp eval "$EXPR" ${PORT:+--port "$PORT"} 2>&1 )"
RC=$?
if [ "$RC" != "0" ]; then
  printf '✘ cdp eval 失败（exit %s）\n%s\n' "$RC" "$OUT" >&2
  printf '  ↳ 5 = 没有 devtools socket（release 包 / 未开 WebContentsDebuggingEnabled）\n' >&2
  printf '  ↳ 6 = Android-Package 不匹配（forward 落到了别的 App/浏览器）\n' >&2
  exit "$RC"
fi

# 注意：stdin 已经被 heredoc 占用了，所以把 dv 的输出去一个临时文件再交给 python
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/dv-assert.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT
printf '%s\n' "$OUT" > "$TMP_OUT"

python3 - "$TMP_OUT" "$FIND" "$URL_SUB" "$MAX_SMALL" <<'PY'
import json, sys
data_path, find, url_sub, max_small = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

raw = [l for l in open(data_path, encoding='utf-8', errors='replace').read().splitlines() if l.strip()]
payload = None
for line in reversed(raw):                       # 末行是 dv 的 JSON
    if line.startswith('{'):
        try:
            payload = json.loads(line); break
        except Exception:
            continue
if not payload or not payload.get('ok'):
    print('✘ 没拿到可解析的 JSON：%s' % (raw[-1] if raw else '(空)')); sys.exit(1)

fact = payload.get('value')
if isinstance(fact, str):
    try:
        fact = json.loads(fact)
    except Exception:
        print('✘ eval 返回值不是 JSON：%r' % (fact[:200],)); sys.exit(1)
if not isinstance(fact, dict):
    print('✘ eval 返回的不是对象：%r' % (fact,)); sys.exit(1)

fails = []
print('url      %s' % fact.get('url'))
print('title    %s' % fact.get('title'))
print('nodes    %s' % fact.get('nodes'))

if find:
    ok = bool(fact.get('found'))
    print('%s find   %r' % ('✔' if ok else '✘', find))
    if not ok:
        fails.append('页面文本里没有 %r' % find)

if url_sub:
    ok = bool(fact.get('url_ok'))
    print('%s url    %r' % ('✔' if ok else '✘', url_sub))
    if not ok:
        fails.append('URL 里没有 %r' % url_sub)

n_small = fact.get('small_count') or 0
if max_small != '':
    ok = n_small <= int(max_small)
    print('%s tap    %d 个 <44dp（上限 %s）' % ('✔' if ok else '✘', n_small, max_small))
    if not ok:
        fails.append('%d 个触控目标 <44dp' % n_small)
        for s in fact.get('small') or []:
            print('         · %s×%s  %s' % (s.get('w'), s.get('h'), s.get('t')))

if fails:
    print('\n断言失败：')
    for f in fails:
        print('  ✘ %s' % f)
    sys.exit(1)
print('\n✔ 断言全过')
PY
