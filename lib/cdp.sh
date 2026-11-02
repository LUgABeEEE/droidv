#!/usr/bin/env bash
# lib/cdp.sh —— WebView CDP：自动 forward + Android-Package 校验 + 任何退出路径都回收 forward
#
# 实测教训：
#   · socket 有两种命名：webview_devtools_remote_<pid> / browser_webview_devtools_remote_<pid>，都要试
#   · 不能靠 package 猜，必须用 /json/version 的 Android-Package 认领
#   · forward 到不存在的 socket 时 curl 只会给 52 —— 那是「名字不对」，不是「CDP 不可用」

CDP_PORT=""
CDP_SOCKET=""
CDP_PID=""

dv_help_cdp() { cat <<EOF
dv cdp <action> [--json]
  version             GET /json/version（含 Android-Package 校验）
  list                GET /json/list
  eval '<js>'         Runtime.evaluate，返回回值
  report [--json]     version + list + 一条事实（innerWidth/DOM/UA）汇总
选项：--port N（默认 $FORWARD_PORT）  --match SUBSTR（选哪个 target）
退出码：0 成功 · 3 无设备 · 5 通道不可用（无 socket/forward/HTTP） · 6 package 校验失败
说明：无论成功失败，forward 一定回收（trap EXIT / INT / TERM）。
EOF
}

_cdp_pid() {
  adbq shell "pidof $PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

# 找到属于目标进程的 devtools socket（两种前缀都试）
_cdp_socket() {
  local pid="$1" unix_all s
  unix_all="$(adbq shell 'cat /proc/net/unix' 2>/dev/null | tr -d '\r')"
  # 1) pid 精确匹配（webview_devtools_remote_<pid> 或 browser_webview_devtools_remote_<pid>）
  s="$(printf '%s\n' "$unix_all" \
        | grep -oE '@[A-Za-z0-9_]*webview_devtools_remote_[0-9]+' \
        | sed 's/^@//' | awk -v p="$pid" -F_ '$NF==p' | head -1)"
  [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  # 2) 退化：任意一个（靠后面的 Android-Package 校验认领）
  s="$(printf '%s\n' "$unix_all" | grep -oE '@[A-Za-z0-9_]*webview_devtools_remote_[0-9]+' \
        | sed 's/^@//' | grep -v '^browser_' | head -1)"
  [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  return 1
}

_cdp_cleanup() {
  [ -n "$CDP_PORT" ] && adbq forward --remove "tcp:$CDP_PORT" >/dev/null 2>&1
}
_cdp_trap() { trap '_cdp_cleanup' EXIT; trap '_cdp_cleanup; exit 130' INT TERM; }

_cdp_setup() {   # $1=port  $2=1 表示允许没有包名（list/version 列全部 target）
  need curl          # F-16：cdp 依赖 curl 取 /json/*
  [ "${2:-0}" = "1" ] || dv_require_pkg
  dv_need_device
  CDP_PID="$(_cdp_pid)"
  if [ -z "$CDP_PID" ]; then
    if [ "${2:-0}" = "1" ]; then
      # 没给包名：挑一个存在的 devtools socket（先 App 的，再浏览器的）
      CDP_SOCKET="$(_cdp_socket "" 2>/dev/null || true)"
      [ -n "$CDP_SOCKET" ] || die "$EX_CHAN" "没有找到任何 devtools socket"
      CDP_PID="$(printf '%s' "$CDP_SOCKET" | sed 's/.*_//')"
    else
      die "$EX_CHAN" "$PKG 不在运行（先 dv cycle 或 am start）"
    fi
  fi
  CDP_SOCKET="$(_cdp_socket "$CDP_PID")" \
    || { err "找不到 devtools socket（pid=$CDP_PID）"; hint "release 包默认不建 socket；需 debug 包或 App 侧开启 setWebContentsDebuggingEnabled"
    hint "注意：.debug 包装上但**尚未与电脑配对成功**时也不会创建 WebView，/proc/net/unix 里 devtools 数为 0"; exit "$EX_CHAN"; }
  CDP_PORT="$(dv_free_port "${1:-$FORWARD_PORT}")"
  _cdp_trap
  adbq forward "tcp:$CDP_PORT" "localabstract:$CDP_SOCKET" >/dev/null 2>&1 || die "$EX_CHAN" "adb forward 失败（socket=$CDP_SOCKET）"
  [ "$VERBOSE" = "1" ] && hint "forward tcp:$CDP_PORT -> $CDP_SOCKET (pid $CDP_PID)"
  # HTTP 必须真的通
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null)"
  [ "$code" = "200" ] || die "$EX_CHAN" "forward 已建立但 /json/version 返回 ${code:-无响应}（socket=$CDP_SOCKET）"
}

_cdp_http() {  # $1=path  -> 打印 body；非 200 返回 5
  local body code
  body="$(curl -s --max-time 8 -w $'\n%{http_code}' "http://127.0.0.1:$CDP_PORT$1" 2>/dev/null)"
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [ "$code" != "200" ]; then err "GET $1 -> $code"; return "$EX_CHAN"; fi
  printf '%s' "$body"
}

_cdp_pkg_ok() {  # $1=version json
  printf '%s' "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(d.get("Android-Package",""))' 2>/dev/null
}

dv_cmd_cdp() {
  local action="${1:-}"; shift || true
  local want_json=$JSON_MODE expr="" match=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) want_json=1; shift ;;
      --port) FORWARD_PORT="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --match) match="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_cdp; return "$EX_OK" ;;
      -*) die "$EX_ARG" "cdp 不认识的选项：$1" ;;
      *) expr="$1"; shift ;;
    esac
  done

  case "$action" in
    version|list|report|eval) ;;
    ''|help) dv_help_cdp; return "$EX_OK" ;;
    *) die "$EX_ARG" "cdp 不认识的动作：$action（version|list|eval|report）" ;;
  esac
  [ "$action" = "eval" ] && [ -z "$expr" ] && die "$EX_ARG" "cdp eval 需要一段 JS 表达式"
  [ "$action" = "eval" ] && dv_need_node_ws
  [ "$action" = "report" ] && dv_need_node_ws

  case "$action" in
    version|list) _cdp_setup "" 1 ;;
    *)            _cdp_setup ;;
  esac

  local ver pkg_actual rc=0
  ver="$(_cdp_http /json/version)" || rc=$?
  [ "$rc" != "0" ] && { err "取 /json/version 失败"; return "$rc"; }
  pkg_actual="$(_cdp_pkg_ok "$ver")"

  # 认领：给了包名才校验；没给包名（list/version）就列出全部 target
  local claimed=0
  [ -z "$PKG" ] && claimed=1
  case "$pkg_actual" in
    "$PKG"|"$PKG.debug") claimed=1 ;;
  esac
  if [ "$claimed" != "1" ]; then
    err "CDP 端点不属于 $PKG（Android-Package='${pkg_actual:-未知}'，socket=$CDP_SOCKET）"
    hint "别把系统浏览器（browser_webview_devtools_remote_*）的 socket 当成被测 App"
    [ "$want_json" = "1" ] && printf '{"ok":false,"phase":"claim","android_package":%s,"socket":%s}\n' \
      "$(jstr "$pkg_actual")" "$(jstr "$CDP_SOCKET")"
    return "$EX_VERIFY"
  fi

  case "$action" in
    version)
      if [ "$want_json" = "1" ]; then printf '{"ok":true,"socket":%s,"port":%s,"pid":%s,"version":%s}\n' \
        "$(jstr "$CDP_SOCKET")" "$CDP_PORT" "$CDP_PID" "$ver"
      else ok "socket $CDP_SOCKET → tcp:$CDP_PORT (pid $CDP_PID)"; printf '%s\n' "$ver"; fi ;;
    list)
      local lst; lst="$(_cdp_http /json/list)" || return $?
      if [ "$want_json" = "1" ]; then printf '{"ok":true,"port":%s,"targets":%s}\n' "$CDP_PORT" "$lst"
      else printf '%s\n' "$lst" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$lst"; fi ;;
    eval)
      local js_expr="$expr" out
      local args=(--port "$CDP_PORT" --expr "$js_expr")
      [ -n "$match" ] && args+=(--match "$match")
      out="$(timeout 25 node "$DV_BIN/lib/cdp-eval.mjs" "${args[@]}" 2>&1)"; rc=$?
      [ "$rc" = "124" ] && { err "cdp eval 超时（25 s）"; out='{"ok":false,"phase":"timeout"}'; rc=$EX_CHAN; }
      if [ "$want_json" = "1" ]; then printf '%s\n' "$out" | tail -1; else printf '%s\n' "$out"; fi
      return "$rc" ;;
    report)
      local lst fact
      lst="$(_cdp_http /json/list)" || return $?
      fact="$(timeout 25 node "$DV_BIN/lib/cdp-eval.mjs" --port "$CDP_PORT" --expr \
        'JSON.stringify({url:location.href,title:document.title,innerWidth:innerWidth,innerHeight:innerHeight,nodes:document.querySelectorAll("*").length,ua:navigator.userAgent.slice(0,60)})' 2>/dev/null | tail -1)"
      local n_targets
      n_targets="$(printf '%s' "$lst" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)' 2>/dev/null)"
      local fact_ok=1
      printf '%s' "$fact" | grep -q '"ok":true' || fact_ok=0
      if [ "$want_json" = "1" ]; then
        printf '{"ok":%s,"socket":%s,"port":%s,"pid":%s,"android_package":%s,"targets":%s,"fact":%s}\n' \
          "$(jbool "$fact_ok")" "$(jstr "$CDP_SOCKET")" "$CDP_PORT" "$CDP_PID" "$(jstr "$pkg_actual")" "$(jnum "${n_targets:-0}")" "$fact"
        [ "$fact_ok" = "0" ] && return "$EX_CHAN"
      else
        ok "CDP 可用：$pkg_actual"
        say "  socket  $CDP_SOCKET (pid $CDP_PID) → tcp:$CDP_PORT"
        say "  targets $n_targets"
        printf '%s\n' "$fact" | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.readline()); v=json.loads(d.get("value") or "{}")
    for k in ("url","title","innerWidth","innerHeight","nodes"): print(f"  {k:<10} {v.get(k)}")
except Exception: pass' 2>/dev/null || true
      fi ;;
  esac
  return "$EX_OK"
}
