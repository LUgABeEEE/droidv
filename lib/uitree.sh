#!/usr/bin/env bash
# lib/uitree.sh —— 原生 UI 树：rm→dump→三件套校验→sleep 2 重试→3 次后重启轮询
#
# 实测教训：
#   · dump 失败时会**保留上一次的旧 XML** → 必须先 rm
#   · `ERROR: could not get idle state.` 单次空耗 ~11 s；失败后**等 2 s 再重试**比连发有效
#   · 失败 3 次后 force-stop + am start -W + sleep 8，再用「轮询关键标记」的方式等页面
#   · 顶层窗口可能被别的 App/安装弹窗顶掉 → 校验 package=

DV_UI_REMOTE=/data/local/tmp/dv-ui.xml

dv_help_uitree() { cat <<EOF
dv uitree [--marker M] [--find TEXT] [--json] [--dump-out FILE]
  --marker M     必须出现的标记（如 '[dvmeta:'）；出现即视为页面就绪
  --find TEXT    在节点文本/描述里查这个子串，命中的节点打印出来
  --dump-out F   把 XML 存到 F（默认不落盘）
校验三件套：</hierarchy> 完整 / package=被测包 / marker 存在
--timeout N   超时预算（默认 $DV_TIMEOUT s）；重试间隔 = N/15、重启后首等 = N/4、轮询间隔 = N/10
              （N=30 时就是 2s / 8s(7.5) / 3s，与历史行为一致）
  --restart-app         失败时重启被测 App 再轮询（默认**不重启**；release 包需再加 --allow-restart-release）
  --allow-restart-release  允许对 release 包使用 --restart-app（默认拒绝，避免打断用户）
退出码：0 成功 · 2 参数错误 · 3 无设备 · 4 取数失败（默认立即返回，不重启） · 6 release 重启被拒（含 dump 报 could not get idle state 时**立即失败**，不再空转重试）
EOF
}

_UI_ERR_FILE="${TMPDIR:-/tmp}/dv-ui-err.$$"
_ui_last_error() { cat "$_UI_ERR_FILE" 2>/dev/null || true; }

_ui_dump_once() {   # 返回 0 并打印 XML；失败返回非 0
  : > "$_UI_ERR_FILE" 2>/dev/null || true
  adbq shell "rm -f $DV_UI_REMOTE" >/dev/null 2>&1
  local out
  out="$(adbq shell "uiautomator dump $DV_UI_REMOTE" 2>&1)"
  case "$out" in
    *"dumped to"*) ;;
    *) printf '%s' "$out" > "$_UI_ERR_FILE" 2>/dev/null; printf '%s' "$out" >&2; return 1 ;;
  esac
  adbq exec-out cat "$DV_UI_REMOTE" 2>/dev/null
}

_ui_validate() {   # $1=xml $2=package $3=marker
  local xml="$1" pkg="$2" marker="${3:-}"
  printf '%s' "$xml" | grep -q '</hierarchy>' || { err "XML 不完整（缺 </hierarchy>）"; return 1; }
  printf '%s' "$xml" | grep -q "package=\"$pkg\"" || { err "XML 里没有 package=\"$pkg\"（顶层窗口被抢？）"; return 1; }
  if [ -n "$marker" ]; then
    printf '%s' "$xml" | grep -qF -- "$marker" || { err "XML 里没有 marker：$marker"; return 1; }
  fi
  return 0
}

dv_cmd_uitree() {
  local json=$JSON_MODE marker="$MARKER" find_text="" dump_out="" xml="" attempt=0
  local tmo="$DV_TIMEOUT" restart_app=0 allow_restart_release=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --marker) marker="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --find) find_text="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --dump-out) dump_out="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --timeout) tmo="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --restart-app) restart_app=1; shift ;;
      --allow-restart-release) allow_restart_release=1; shift ;;
      -h|--help) dv_help_uitree; return "$EX_OK" ;;
      *) die "$EX_ARG" "uitree 不认识的参数：$1" ;;
    esac
  done

  dv_need_device

  # 阶段 1：最多 3 次，但有**硬截止时间**（min(timeout,10s)）——不允许再出现 68 s 这种
  local deadline=$(( $(date +%s) + ( tmo < 7 ? tmo : 7 ) ))   # 单次 dump 实测 3~4s，留出余量保证总耗时 <10s
  while [ "$attempt" -lt 3 ] && [ "$(date +%s)" -lt "$deadline" ]; do
    attempt=$((attempt+1))
    [ "$VERBOSE" = "1" ] && hint "uitree 第 $attempt 次 dump"
    if xml="$(_ui_dump_once 2>/dev/null)" && _ui_validate "$xml" "$PKG" "$marker" 2>/dev/null; then
      break
    fi
    # P0：`could not get idle state` 说明页面在持续动画/忙碌，重试只会再空转 ~11 s → 立即判失败
    case "$(_ui_last_error)" in
      *"could not get idle state"*)
        [ "$json" = "1" ] && printf '{"ok":false,"code":4,"phase":"uitree","reason":"idle_timeout","attempts":%s,"hint":%s}\n' \
          "$attempt" "$(jstr "页面持续动画/忙碌：用 dv wait-until --text/--focus 等条件等待，或 dv cdp eval（debug 包）")"
        err "dump 报 could not get idle state（页面在动画/忙碌）——立即判失败，不再空转重试"
        hint "改用有条件的等待：dv wait-until --text '<文本>' --timeout $tmo"
        hint "或先 dv wait-until --focus $PKG 确认窗口就绪，再 dv uitree"
        return "$EX_DATA" ;;
    esac
    xml=""
    [ "$attempt" -lt 3 ] && {
      local w; w="$(dv_t_retry "$tmo")"
      # 睡眠不能把总耗时推过截止时间
      if [ $(( $(date +%s) + w )) -lt "$deadline" ]; then
        warn "第 $attempt 次失败，sleep ${w}s 后重试"; sleep "$w"
      else
        break
      fi
    }
  done

  # 阶段 2（**只在显式 --restart-app 时**）：重启 App 再轮询，总耗时不超过 10 s。
  # 默认行为：任何失败都立即 exit 4，绝不重启用户正在用的 App（release 只读红线）。
  if [ -z "$xml" ] && [ "$restart_app" = "1" ]; then
    dv_require_pkg
    case "$PKG" in
      *.debug) ;;
      *)
        if [ "$allow_restart_release" != "1" ]; then
          err "拒绝重启 release 包 $PKG —— 这会打断正在使用 App 的用户"
          hint "确认要重启时加 --allow-restart-release；或者走只读路径：dv wait-until --focus $PKG"
          [ "$json" = "1" ] && printf '{"ok":false,"code":6,"phase":"uitree","reason":"release_restart_refused"}\n'
          return "$EX_VERIFY"
        fi ;;
    esac
    warn "按 --restart-app 重启 $PKG 后轮询（总预算 ≤10 s）"
    dv_restart_app >/dev/null
    local deadline=$(( $(date +%s) + 10 ))
    local round=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      round=$((round+1))
      dv_sleep "$(dv_t_poll "$tmo")"
      if xml="$(_ui_dump_once 2>/dev/null)" && _ui_validate "$xml" "$PKG" "$marker" 2>/dev/null; then
        [ "$VERBOSE" = "1" ] && hint "第 $round 轮拿到"
        break
      fi
      xml=""
    done
  fi

  # B17：dump 成功但缺 marker —— 与「取不到树」分开报，别让人去查设备
  if [ -z "$xml" ] && [ -n "$marker" ]; then
    local last_xml last_nodes
    last_xml="$(_ui_dump_once 2>/dev/null || true)"
    if [ -n "$last_xml" ] && _ui_validate "$last_xml" "${PKG:-}" "" 2>/dev/null; then
      last_nodes="$(printf '%s' "$last_xml" | grep -c '<node' || true)"
      [ "$json" = "1" ] && printf '{"ok":false,"code":4,"phase":"uitree","reason":"marker_missing","marker":%s,"nodes":%s,"hint":%s}\n' \
        "$(jstr "$marker")" "$(jnum "$last_nodes")" "$(jstr "树能取到（$last_nodes 个节点）但没有 marker '$marker'：确认页面确实渲染了这个标记，或换 --find 按文本找")"
      err "UI 树能取到（${last_nodes} 个节点），但里面没有 marker '$marker'"
      hint "这不是 dump 失败：检查页面是否已渲染该标记，或用 --find '<文本>' 按内容找"
      return "$EX_DATA"
    fi
  fi

  if [ -z "$xml" ]; then
    # R-07：失败 JSON 与成功同一套字段（{ok,code,phase,hint}）
    [ "$json" = "1" ] && printf '{"ok":false,"code":4,"phase":"uitree","attempts":%s,"hint":%s}\n' \
      "$attempt" "$(jstr "UI 树取不到：先 dv wait-until --focus ${PKG:-<包名>} 等窗口就绪；确需重启 App 请显式加 --restart-app")"
    err "仍然拿不到有效的 UI 树"
    return "$EX_DATA"
  fi

  # 统计与查询
  local stats
  stats="$(printf '%s' "$xml" | python3 -c '
import sys, json, xml.etree.ElementTree as ET
x = sys.stdin.read()
try: r = ET.fromstring(x)
except Exception as e:
    print(json.dumps({"ok": False, "error": str(e)})); raise SystemExit
n = list(r.iter("node"))
texts = [t for t in (k.get("text") or "" for k in n) if t]
print(json.dumps({"ok": True, "nodes": len(n), "texts": len(texts),
                  "max_text": max((len(t) for t in texts), default=0),
                  "pkgs": sorted({k.get("package") for k in n if k.get("package")})}))
' 2>/dev/null)"

  local found=""
  if [ -n "$find_text" ]; then
    found="$(printf '%s' "$xml" | FIND="$find_text" python3 -c '
import sys, os, json, xml.etree.ElementTree as ET
want = os.environ["FIND"]
r = ET.fromstring(sys.stdin.read())
hits = []
for k in r.iter("node"):
    t = (k.get("text") or ""); d = (k.get("content-desc") or "")
    if want in t or want in d:
        hits.append({"text": t[:120], "desc": d[:120], "cls": (k.get("class") or "").split(".")[-1], "bounds": k.get("bounds")})
print(json.dumps(hits[:20], ensure_ascii=False))
' 2>/dev/null)"
  fi

  [ -n "$dump_out" ] && printf '%s' "$xml" > "$dump_out"

  if [ "$json" = "1" ]; then
    printf '{"ok":true,"serial":%s,"pkg":%s,"attempts":%s,"stats":%s,"matches":%s}\n' \
      "$(jstr "$SERIAL")" "$(jstr "$PKG")" "$(jnum "$attempt")" "${stats:-null}" "${found:-[]}"
    return "$EX_OK"
  fi

  ok "UI 树已取得（第 $attempt 次尝试）"
  printf '%s' "$stats" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(f"  节点 {d.get(\"nodes\")} · 文本节点 {d.get(\"texts\")} · 最长文本 {d.get(\"max_text\")}")' 2>/dev/null || true
  if [ -n "$find_text" ]; then
    printf '%s' "$found" | python3 -c 'import json,sys
h=json.load(sys.stdin)
print(f"  命中 {len(h)} 个：")
for x in h: print(f"    [{x[\"cls\"]}] {x[\"bounds\"]} {x[\"text\"] or x[\"desc\"]}")' 2>/dev/null || true
  fi
  return "$EX_OK"
}
