#!/usr/bin/env bash
# lib/wait-until.sh —— 有判定条件的等待（替代固定 sleep 猜）
#
# 设计依据（t24 调研）：成熟工具（Espresso IdlingResource / uiautomator2 implicitly_wait）
# 都是「可判定的条件 + 单一超时预算」。这里把条件做成谓词，超时后给出三件套：
#   等了多久 / 最后一次观察到的状态（结构化 last_state，--json 可取）/ 排查建议

# shellcheck source=uitree.sh
. "$DV_BIN/lib/uitree.sh"
# shellcheck source=cdp.sh
. "$DV_BIN/lib/cdp.sh"

dv_help_wait_until() { cat <<EOF
dv wait-until <谓词> [--timeout N] [--interval S] [--json]
谓词（五选一，任选其一）：
  --text <字符串>     页面上出现该文本（UI 树 text/content-desc 命中）
  --focus <包名>      mCurrentFocus 属于该包
  --expr '<js>'       CDP Runtime.evaluate 返回真值
  --shell '<cmd>'     设备上命令退出码 0（adb shell <cmd>）
  --pkg-visible <包>  UI 树里出现该包名（窗口已就绪）
超时 → exit 4，并输出：等了多久 / 最后一次观察到的状态 / 建议排查项（--json 里是 last_state）
退出码：0 命中 · 2 参数错误 · 3 无设备 · 4 超时 · 5 通道不可用（--expr 时 CDP 不可用）
EOF
}

# 结构化「最后观察到的状态」，按谓词类型填不同字段
_wu_state_json() {  # $1=kind $2..=内容
  local kind="$1"; shift
  case "$kind" in
    text)    printf '{"kind":"text","expect":%s,"found":%s,"nodes":%s,"dump_ok":%s,"dump_error":%s}' \
               "$(jstr "${1:-}")" "$(jbool "${2:-0}")" "$(jnum "${3:-}")" "$(jbool "${4:-0}")" "$(jstr "${5:-}")" ;;
    focus)   printf '{"kind":"focus","expect":%s,"actual":%s}' "$(jstr "${1:-}")" "$(jstr "${2:-}")" ;;
    expr)    printf '{"kind":"expr","expr":%s,"last_value":%s,"last_error":%s}' \
               "$(jstr "${1:-}")" "$(jstr "${2:-}")" "$(jstr "${3:-}")" ;;
    shell)   printf '{"kind":"shell","cmd":%s,"last_rc":%s,"last_output":%s}' \
               "$(jstr "${1:-}")" "$(jnum "${2:-}")" "$(jstr "${3:-}")" ;;
    pkg)     printf '{"kind":"pkg_visible","expect":%s,"found":%s,"nodes":%s,"dump_ok":%s,"dump_error":%s}' \
               "$(jstr "${1:-}")" "$(jbool "${2:-0}")" "$(jnum "${3:-}")" "$(jbool "${4:-0}")" "$(jstr "${5:-}")" ;;
  esac
}

_wu_hints() {  # $1=kind
  case "$1" in
    text|pkg) printf '%s|%s|%s' \
      "页面可能还没渲染完：先 dv uitree --json 看节点数，或 dv wait-until --focus <pkg>" \
      "若 dump 报 could not get idle state，说明页面在持续动画：改用 dv cdp eval 或重试" \
      "文本可能在 WebView 里没进 a11y 树：试试 --expr（需 debug 包）或 --shell" ;;
    focus) printf '%s|%s' \
      "焦点可能被安装弹窗/系统界面抢走：dv adb -- shell dumpsys window | grep mCurrentFocus" \
      "确认 App 已启动：dv cycle 或 dv adb -- shell am start -W -n <pkg>/<activity>" ;;
    expr) printf '%s|%s' \
      "CDP 不可用常见原因：release 包没有 devtools socket（需 debug 包或 App 侧开启）" \
      "先跑 dv cdp version 看是「无 socket」还是「package 不匹配」" ;;
    shell) printf '%s|%s' \
      "看命令实际输出：dv adb -- shell '<cmd>'（dv 会给退出码与原始输出）" \
      "注意 shell 里的引号会被解析两层，必要时用单引号包整条命令" ;;
  esac
}

dv_cmd_wait_until() {
  local json=$JSON_MODE kind="" text="" focus_pkg="" expr="" shellcmd="" pkgvis=""
  local timeout="$DV_TIMEOUT" interval=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --text) text="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; kind=text; shift 2 ;;
      --focus) focus_pkg="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; kind=focus; shift 2 ;;
      --expr) expr="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; kind=expr; shift 2 ;;
      --shell) shellcmd="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; kind=shell; shift 2 ;;
      --pkg-visible) pkgvis="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; kind=pkg; shift 2 ;;
      --timeout) timeout="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --interval) interval="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_wait_until; return "$EX_OK" ;;
      -*) die "$EX_ARG" "wait-until 不认识的选项：$1" ;;
      *) die "$EX_ARG" "wait-until 不接受位置参数：$1（谓词请用 --text/--focus/--expr/--shell）" ;;
    esac
  done
  [ -n "$kind" ] || die "$EX_ARG" "需要一个谓词：--text/--focus/--expr/--shell/--pkg-visible"
  case "$timeout" in ''|*[!0-9]*) die "$EX_ARG" "--timeout 需要正整数（秒）" ;; esac
  [ -n "$interval" ] || interval="$(dv_t_retry "$timeout")"
  [ "$interval" -lt 1 ] && interval=1

  dv_need_device
  if [ "$kind" = "expr" ]; then
    dv_need_node_ws; need curl
    dv_require_pkg
    _cdp_setup   # 建 forward + trap 回收；失败直接 exit 5
  fi

  local t0 now elapsed last_json="" hit=0 last_err=""
  t0=$(date +%s%N)

  while :; do
    now=$(date +%s%N); elapsed=$(( (now - t0) / 1000000 ))
    case "$kind" in
      text|pkg)
        local want nodes=0 found=0 dump_ok=0 err="" xml
        [ "$kind" = "text" ] && want="$text" || want="$pkgvis"
        if xml="$(_ui_dump_once 2>/dev/null)"; then
          dump_ok=1
          nodes=$(printf '%s' "$xml" | grep -c '<node' || true)
          if [ "$kind" = "text" ]; then
            printf '%s' "$xml" | grep -qF -- "$want" && found=1
          else
            printf '%s' "$xml" | grep -q "package=\"$want\"" && found=1
          fi
        else
          err="$(_ui_last_error)"
        fi
        last_json="$(_wu_state_json "$kind" "$want" "$found" "$nodes" "$dump_ok" "$err")"
        [ "$found" = "1" ] && { hit=1; break; } ;;
      focus)
        local cur; cur="$(dv_focus_line)"
        last_json="$(_wu_state_json focus "$focus_pkg" "$cur")"
        case "$cur" in *"$focus_pkg"*) hit=1; break ;; esac ;;
      expr)
        local out2 ok2 val2
        out2="$(timeout 25 node "$DV_BIN/lib/cdp-eval.mjs" --port "$CDP_PORT" --expr "$expr" 2>&1)" || true
        val2="$(printf '%s' "$out2" | tail -1 | cut -c1-200)"
        ok2="$(printf '%s' "$out2" | tail -1 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get("value")
    print("1" if d.get("ok") and v not in (False, None, "", 0, "false") else "0")
except Exception:
    print("0")' 2>/dev/null)"
        last_json="$(_wu_state_json expr "$expr" "$val2" "")"
        [ "$ok2" = "1" ] && { hit=1; break; } ;;
      shell)
        local rc2 out2
        out2="$(adbq shell "$shellcmd" 2>&1)"; rc2=$?
        last_json="$(_wu_state_json shell "$shellcmd" "$rc2" "$(printf '%s' "$out2" | tail -c 300)")"
        [ "$rc2" = "0" ] && { hit=1; break; } ;;
    esac

    if [ "$elapsed" -ge $(( timeout * 1000 )) ]; then break; fi
    sleep "$interval"
  done

  now=$(date +%s%N); elapsed=$(( (now - t0) / 1000000 ))
  local hints; hints="$(_wu_hints "$kind")"

  if [ "$hit" = "1" ]; then
    if [ "$json" = "1" ]; then
      printf '{"ok":true,"predicate":%s,"elapsedMs":%s,"last_state":%s}\n' "$(jstr "$kind")" "$elapsed" "$last_json"
    else
      ok "命中（${kind}，等了 ${elapsed} ms）"
      printf '%s\n' "$last_json" | sed 's/^/  /'
    fi
    return "$EX_OK"
  fi

  # 超时：三件套（等了多久 / 最后状态 / 排查建议）
  if [ "$json" = "1" ]; then
    printf '{"ok":false,"code":4,"phase":"wait-until","predicate":%s,"elapsedMs":%s,"timeoutSec":%s,"last_state":%s,"hint":%s}\n' \
      "$(jstr "$kind")" "$elapsed" "$timeout" "$last_json" "$(jstr "${hints//|/ ；}")"
  else
    err "等待超时：${kind}（等了 $(( elapsed / 1000 )) s，超时上限 ${timeout}s）"
    say "  最后状态：$last_json"
    say "  建议排查："
    printf '%s' "$hints" | tr '|' '\n' | sed 's/^/    - /'
  fi
  return "$EX_DATA"
}
