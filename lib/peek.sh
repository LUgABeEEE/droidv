#!/usr/bin/env bash
# lib/peek.sh —— 文本优先的「看一眼」：先 CDP（快、准），退回 UI 树摘要（通用）
#   动机（真机实测 2026-11-03）：一页 UI 树 XML 55 KB ≈ 14k token，截图 411 KB ≈ 1.5k token
#   → 模型天然选截图。peek 把「读界面」的文本成本压到 ~0.6k token：让正确的路也是便宜的路。
DV_PEEK_REMOTE="${DV_PEEK_REMOTE:-/sdcard/dv-peek.xml}"

dv_help_peek() { cat <<EOF
dv peek [--json] [--limit N] [--all] [--no-cdp] [--dump-out FILE]
  一次调用回答「现在屏幕上有什么」：前台 App + 按阅读顺序的文本/可点元素摘要。
  两条后端自动选：① CDP（WebView 内，~150 ms，最准）② UI 树摘要（通用，~3 s）
  **不截图、不返回像素**；默认最多 60 项（--all 全列，--limit N 自定）。
  --no-cdp      只用 UI 树（原生 App，或 CDP 端点被占）
  --dump-out F  额外保留原始 UI 树 XML（默认丢弃——它才是 context 杀手）
退出码：0 成功 · 2 参数错误 · 3 无设备 · 4 两条后端都取不到 · 7 环境缺失
EOF
}

_peek_dump() {   # 打印 XML；失败返回非 0（与 uitree 同源策略：先 rm，防读到上一帧旧文件）
  adbq shell "rm -f $DV_PEEK_REMOTE" >/dev/null 2>&1
  local out
  out="$(adbq shell "uiautomator dump $DV_PEEK_REMOTE" 2>&1)"
  case "$out" in
    *"dumped to"*) ;;
    *) printf '%s' "$out" >&2; return 1 ;;
  esac
  adbq exec-out cat "$DV_PEEK_REMOTE" 2>/dev/null
}

# $1=XML 文件 $2=limit $3=json → 摘要（人读 / JSON）
_peek_render_tree() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, re, sys
import xml.etree.ElementTree as ET

limit, as_json = int(sys.argv[2]), sys.argv[3] == "1"
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:                      # 半截 XML / 空文件
    print(json.dumps({"ok": False, "code": 4, "reason": f"parse: {e}"}, ensure_ascii=False, separators=(",", ":")) if as_json
          else f"XML 解析失败：{e}")
    sys.exit(0 if as_json else 4)

items, total, texts, clickables = [], 0, 0, 0
for nd in root.iter("node"):
    total += 1
    t = (nd.get("text") or "").strip()
    d = (nd.get("content-desc") or "").strip()
    label = t or d
    click = nd.get("clickable") == "true"
    if click:
        clickables += 1
    if not label:
        continue
    texts += 1
    m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", nd.get("bounds") or "")
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    items.append({
        "text": label, "cls": (nd.get("class") or "").split(".")[-1], "tap": click,
        "x": (x1 + x2) // 2, "y": (y1 + y2) // 2, "w": x2 - x1, "h": y2 - y1,
        "id": (nd.get("resource-id") or "").split("/")[-1],
    })

items.sort(key=lambda i: (i["y"] // 12, i["x"]))          # 阅读顺序：行内从左到右
seen, uniq = set(), []
for i in items:                                            # 嵌套节点常重复同一段文字
    key = (i["text"], i["y"] // 12)
    if key not in seen:
        seen.add(key)
        uniq.append(i)

shown = uniq[:limit]
if as_json:
    print(json.dumps({"ok": True, "backend": "uitree", "nodes": total, "texts": texts,
                      "clickables": clickables, "items": shown,
                      "more": max(0, len(uniq) - len(shown))}, ensure_ascii=False, separators=(",", ":")))
    sys.exit(0)

print(f'节点 {total}（有文本 {texts} · 可点 {clickables}）  摘要 {len(shown)} 项')
print("─" * 46)
for i in shown:
    mark = "▸" if i["tap"] else " "
    cls = f'  {i["cls"]}' if i["cls"] else ""
    print(f'{mark} {i["x"]:>5},{i["y"]:>5}  「{i["text"][:60]}」{cls}')
if len(uniq) > len(shown):
    print(f'…还有 {len(uniq) - len(shown)} 项（--all 全列 / --limit N 调整）')
PY
}

_peek_via_cdp() {   # $1=前台包名 $2=limit → 打印 {"ok":true,...}；取不到返回非 0
  local fg="$1"
  [ -n "$fg" ] || return 1
  local js='JSON.stringify({t:document.title,n:(document.body.innerText||"").replace(/\n{2,}/g,"\n").slice(0,2000),b:document.querySelectorAll("button,[role=button],a").length,i:document.querySelectorAll("input,textarea").length,w:innerWidth,h:innerHeight})'
  local out
  out="$("$DV_BIN/dv" --serial "$SERIAL" --pkg "$fg" --json cdp eval "$js" 2>/dev/null)" || return 1
  # 数据只能走环境变量：python 的 stdin 已被 `-c` 的脚本占用（heredoc 同理会抢 stdin）
  PEEK_CDP_RAW="$out" python3 -c '
import json, os, sys
limit = int(sys.argv[1])
raw = (os.environ.get("PEEK_CDP_RAW") or "").strip()
try:
    env = json.loads(raw.splitlines()[-1])
    val = json.loads(env.get("value") or "{}")
except Exception:
    sys.exit(1)
if not env.get("ok"):
    sys.exit(1)
print(json.dumps({"ok": True, "backend": "cdp", "title": val.get("t", ""),
                  "viewport": "%sx%s" % (val.get("w"), val.get("h")),
                  "buttons": val.get("b", 0), "inputs": val.get("i", 0),
                  "text": (val.get("n") or "").splitlines()[:limit]}, ensure_ascii=False, separators=(",", ":")))
' "$2"
}

dv_cmd_peek() {
  local json=$JSON_MODE limit=60 all=0 no_cdp=0 dump_out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --limit) limit="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "--limit 需要值"; shift 2 ;;
      --all) all=1; shift ;;
      --no-cdp) no_cdp=1; shift ;;
      --dump-out) dump_out="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "--dump-out 需要值"; shift 2 ;;
      -h|--help) dv_help_peek; return "$EX_OK" ;;
      *) die "$EX_ARG" "peek 不认识的参数：$1" ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) die "$EX_ARG" "--limit 需要正整数" ;; esac
  [ "$all" = "1" ] && limit=100000

  dv_need_device

  local wake asleep=0 fg focus
  wake=$(adbq shell 'dumpsys power 2>/dev/null | grep -m1 mWakefulness' 2>/dev/null | tr -d '\r')
  case "$wake" in *Asleep*|*Dozing*) asleep=1 ;; esac
  focus=$(dv_focus_line 2>/dev/null || true)
  fg=$(dv_focus_pkg 2>/dev/null || true)

  # ① CDP：WebView 内直接取文本，~150 ms
  if [ "$no_cdp" = "0" ] && [ -n "$fg" ]; then
    local cdp
    if cdp="$(_peek_via_cdp "$fg" "$limit" 2>/dev/null)" && [ -n "$cdp" ]; then
      if [ "$json" = "1" ]; then
        printf '%s' "$cdp" | python3 -c 'import json,sys;d=json.load(sys.stdin);d["focus"]=sys.argv[1];d["fg"]=sys.argv[2];d["asleep"]=sys.argv[3]=="1";print(json.dumps(d,ensure_ascii=False,separators=(",",":")))' "$focus" "$fg" "$asleep"
        return "$EX_OK"
      fi
      printf '%s' "$cdp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"dv peek  ·  {sys.argv[1]}  ·  CDP（WebView 内取数，~150 ms）")
print("─" * 46)
print(f"标题  {d[\"title\"] or \"(无)\"}    视口 {d[\"viewport\"]}    链接/按钮 {d[\"buttons\"]} · 输入框 {d[\"inputs\"]}")
print("─" * 46)
for l in d["text"]:
    if l.strip():
        print(" ", l[:100])
' "$fg"
      return "$EX_OK"
    fi
  fi

  # ② UI 树摘要：通用兜底
  local xml="" attempt=0 max_try tmpf
  max_try=$(dv_t_retry)
  tmpf="$(mktemp "${TMPDIR:-/tmp}/dv-peek.XXXXXX")" || die "$EX_ENV" "无法创建临时文件"
  while [ "$attempt" -lt "$max_try" ]; do
    attempt=$((attempt + 1))
    if xml="$(_peek_dump 2>/dev/null)" && printf '%s' "$xml" | grep -q '</hierarchy>'; then
      printf '%s' "$xml" > "$tmpf"
      break
    fi
    xml=""
    # 页面在动画时 dump 单次空耗 ~11 s：只重试一次，不空转
    [ "$attempt" -ge 2 ] && break
    [ "$VERBOSE" = "1" ] && hint "peek 第 $attempt 次 dump 失败，sleep 2s 重试"
    dv_sleep 2
  done

  if [ -z "$xml" ]; then
    rm -f "$tmpf"
    if [ "$asleep" = "1" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"code":4,"reason":"asleep","asleep":true,"hint":"屏幕休眠：请用户唤醒解锁后重试"}\n'
      err "屏幕休眠（mWakefulness=Asleep），UI 树取不到"
      hint "让用户点亮解锁后再跑；或 dv shot 拿最后一帧像素（贵 ~10 倍 context）"
    else
      [ "$json" = "1" ] && printf '{"ok":false,"code":4,"reason":"dump_failed","asleep":false}\n'
      err "UI 树取数失败（页面可能持续动画 → could not get idle state）"
      hint "稍等重跑；原生动画页可改用 dv uitree --find <文本>"
    fi
    return "$EX_DATA"
  fi

  if [ -n "$dump_out" ]; then
    cp "$tmpf" "$dump_out" 2>/dev/null && [ "$json" = "0" ] && hint "原始 XML → $dump_out"
  fi

  if [ "$json" = "1" ]; then
    _peek_render_tree "$tmpf" "$limit" 1 | python3 -c 'import json,sys;d=json.load(sys.stdin);d["focus"]=sys.argv[1];d["fg"]=sys.argv[2];d["asleep"]=sys.argv[3]=="1";print(json.dumps(d,ensure_ascii=False,separators=(",",":")))' "$focus" "$fg" "$asleep"
    rm -f "$tmpf"
    return "$EX_OK"
  fi

  printf '%s\n' "dv peek  ·  ${SERIAL}  ·  UI 树摘要"
  [ -n "$focus" ] && printf '焦点  %s\n' "$focus"
  [ "$asleep" = "1" ] && warn "屏幕 Asleep（以下可能是最后一帧）"
  _peek_render_tree "$tmpf" "$limit" 0
  rm -f "$tmpf"
  [ -n "$fg" ] && hint "只需要 WebView 里的文本时：dv --pkg $fg cdp eval 'document.body.innerText'（~150 ms）"
  return "$EX_OK"
}
