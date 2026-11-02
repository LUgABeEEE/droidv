#!/usr/bin/env bash
# lib/input.sh —— 输入注入（从 UI 树算坐标 / 文本 / 按键）
#
# 实测教训：
#   · IME 弹出会把 composer 顶上去（ADJUST_RESIZE，实测 −843 px）→ 坐标必须**从树现算**，不能硬编码
#   · `input text` 遇非 ASCII 会静默变成输入法联想（我们踩过 abc→俺不吃）→ 必须显式拒绝并给绕开方式
#   · 中文 IME 下小写字母会被拼音组合吞掉 → 非 ASCII/小写场景优先建议禁 IME 或 ADBKeyboard

# shellcheck source=uitree.sh
. "$DV_BIN/lib/uitree.sh"

dv_help_input() { cat <<EOF
dv input tap  (--text T | --desc D | --xy X,Y) [--index N] [--json]
dv input text <字符串> [--json]
dv input key  <KEYCODE|名称> [--json]

  tap --text T   在 UI 树里找 text 含 T 的第一个可点节点，点它的中心
  tap --desc D   同上，按 content-desc 匹配
  tap --xy X,Y   直接点坐标（不查树）
  --index N      匹配到多个时取第 N 个（默认 0）
  text           只接受**纯 ASCII**；含非 ASCII 会明确报错并给三种绕开方式
  key            例：key 4（返回）、key KEYCODE_HOME

退出码：0 成功 · 2 参数错误/非 ASCII · 3 无设备 · 4 取数失败（找不到节点） · 6 校验失败
EOF
}

_input_dump() { _ui_dump_once 2>/dev/null; }

dv_cmd_input() {
  local action="${1:-}"; shift || true
  local json=$JSON_MODE mode="" text="" desc="" xy="" index=0
  local payload="" from="" to="" ms=300
  case "$action" in
    ''|help|-h|--help) dv_help_input; return "$EX_OK" ;;
    tap|text|key|swipe) ;;
    *) die "$EX_ARG" "input 不认识的动作：$action（tap|text|key）" ;;
  esac

  if [ "$action" = "tap" ] || [ "$action" = "swipe" ]; then
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        --from) from="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
        --to) to="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
        --ms) ms="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
        --text) text="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; mode=text; shift 2 ;;
        --desc) desc="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; mode=desc; shift 2 ;;
        --xy) xy="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; mode=xy; shift 2 ;;
        --index) index="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
        -h|--help) dv_help_input; return "$EX_OK" ;;
        -*) die "$EX_ARG" "input tap 不认识的选项：$1" ;;
        *) die "$EX_ARG" "input tap 不接受位置参数：$1" ;;
      esac
    done
  else
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json=1; shift ;;
        -h|--help) dv_help_input; return "$EX_OK" ;;
        -*) die "$EX_ARG" "input $action 不认识的选项：$1" ;;
        *) payload="$1"; shift ;;
      esac
    done
    [ -n "$payload" ] || die "$EX_ARG" "input $action 需要参数"
  fi

  # 载荷/参数校验先于任何设备/环境操作：中文输入是命令内容问题，应立刻 exit 2
  if [ "$action" = "text" ]; then
    if printf '%s' "$payload" | LC_ALL=C grep -q '[^ -~]'; then
      err "input text 只接受纯 ASCII；这段里含非 ASCII 字符"
      hint "绕开方式①：临时禁用全部 IME 再输入（先 dv ime snapshot，完事 dv ime restore）"
      hint "绕开方式②：装 ADBKeyboard 并用 am broadcast -a ADB_INPUT_B64 --es msg <base64>"
      hint "绕开方式③：debug 包可用 CDP dv cdp eval 'document.execCommand(...)' 或 Input.insertText"
      [ "$json" = "1" ] && printf '{"ok":false,"code":2,"phase":"input","reason":"non_ascii"}\n'
      return "$EX_ARG"
    fi
  fi

  dv_need_device

  case "$action" in
    swipe)
      case "$from" in *,*) ;; *) die "$EX_ARG" "swipe 需要 --from X1,Y1 --to X2,Y2" ;; esac
      case "$to"   in *,*) ;; *) die "$EX_ARG" "swipe 需要 --from X1,Y1 --to X2,Y2" ;; esac
      case "${from%%,*}${from##*,}${to%%,*}${to##*,}" in *[!0-9]*) die "$EX_ARG" "swipe 坐标必须是数字" ;; esac
      adbq shell "input swipe ${from%%,*} ${from##*,} ${to%%,*} ${to##*,} $ms" >/dev/null 2>&1 \
        || die "$EX_DATA" "input swipe 执行失败"
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"action":"swipe","from":%s,"to":%s,"ms":%s}\n' "$(jstr "$from")" "$(jstr "$to")" "$ms"
      else
        ok "已滑动 $from → $to（${ms}ms）"
      fi
      return "$EX_OK" ;;

    tap)
      [ -n "$mode" ] || die "$EX_ARG" "input tap 需要 --text/--desc/--xy 之一"
      local X Y label
      if [ "$mode" = "xy" ]; then
        case "$xy" in
          *,*) X="${xy%%,*}"; Y="${xy##*,}" ;;
          *) die "$EX_ARG" "--xy 需要 X,Y 形式" ;;
        esac
        case "$X$Y" in *[!0-9]*) die "$EX_ARG" "--xy 必须是数字坐标" ;; esac
        label="xy"
      else
        local xml
        xml="$(_input_dump)" || die "$EX_DATA" "拿不到 UI 树（先 dv uitree 看看）"
        local coords
        coords="$(printf '%s' "$xml" | MODE="$mode" NEEDLE="$text$desc" IDX="$index" python3 -c '
import os, re, sys, xml.etree.ElementTree as ET
mode, needle, idx = os.environ["MODE"], os.environ["NEEDLE"], int(os.environ["IDX"])
try:
    root = ET.fromstring(sys.stdin.read())
except Exception as e:
    print("ERR parse " + str(e)); raise SystemExit
hits = []
for n in root.iter("node"):
    v = (n.get("text") or "") if mode == "text" else (n.get("content-desc") or "")
    if needle and needle in v:
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds") or "")
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        hits.append(((x1 + x2) // 2, (y1 + y2) // 2, v[:40]))
if idx >= len(hits):
    print("ERR notfound " + str(len(hits)))
else:
    x, y, v = hits[idx]
    print(f"OK {x} {y} {len(hits)} {v}")
')" || true
        case "$coords" in
          OK\ *) X="$(printf '%s' "$coords" | awk '{print $2}')"; Y="$(printf '%s' "$coords" | awk '{print $3}')"; label="$(printf '%s' "$coords" | cut -d' ' -f5-)" ;;
          *)
            # 定位失败 → 列出树里的候选文本，别只说"没找到"
            local cand
            cand="$(printf '%s' "$xml" | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    raise SystemExit
seen = []
for n in root.iter("node"):
    v = (n.get("text") or "").strip() or (n.get("content-desc") or "").strip()
    if v and v not in seen:
        seen.append(v[:40])
for v in seen[:8]:
    print(v)
' 2>/dev/null)"
            err "UI 树里找不到匹配节点（$mode=$([ "$mode" = text ] && printf %s "$text" || printf %s "$desc")）"
            if [ -n "$cand" ]; then
              say "  树里前 8 个文本（可用来核对用词）："
              printf '%s\n' "$cand" | sed 's/^/    - /'
            fi
            hint "先 dv uitree --find '<你想要的文本>' 看看到底是什么；或改用 --desc / --xy"
            return "$EX_DATA" ;;
        esac
      fi

      # 焦点前后 + DPR（物理 px ↔ CSS px）
      local f_before f_after dpr dens
      f_before="$(dv_focus_line)"
      dens="$(adbq shell 'wm density' 2>/dev/null | sed -n 's/.*: \([0-9]*\).*/\1/p' | head -1)"
      [ -n "$dens" ] || dens=160
      dpr="$(python3 -c "print(round($dens/160, 2))" 2>/dev/null || echo 1)"

      adbq shell "input tap $X $Y" >/dev/null 2>&1 || die "$EX_DATA" "input tap 执行失败"
      dv_sleep 0.3
      f_after="$(dv_focus_line)"

      local focus_ok=1
      case "$f_after" in *"$PKG"*) ;; *) focus_ok=0 ;; esac

      if [ "$json" = "1" ]; then
        printf '{"ok":true,"action":"tap","x":%s,"y":%s,"css_x":%s,"css_y":%s,"dpr":%s,"matched":%s,"index":%s,"focus_before":%s,"focus_after":%s,"focus_is_target":%s}\n' \
          "$X" "$Y" "$(python3 -c "print(round($X/$dpr, 1))" 2>/dev/null || echo 0)" \
          "$(python3 -c "print(round($Y/$dpr, 1))" 2>/dev/null || echo 0)" "$dpr" \
          "$(jstr "$label")" "$index" "$(jstr "$f_before")" "$(jstr "$f_after")" "$(jbool "$focus_ok")"
      else
        ok "已点击 ($X, $Y) px = ($(python3 -c "print(round($X/$dpr,1))" 2>/dev/null || echo ?), $(python3 -c "print(round($Y/$dpr,1))" 2>/dev/null || echo ?)) css  [dpr=$dpr]  ←  $label"
        say "  焦点前：${f_before:-?}"
        say "  焦点后：${f_after:-?}"
      fi
      [ "$focus_ok" = "1" ] || warn "点击后焦点不在 $PKG（$f_after）——可能点空了，或被弹窗/系统界面挡住"
      return "$EX_OK" ;;

    text)
      # B20：先确认真的有输入框（聚焦的 EditText），否则「已输入 N 字符」是假成功
      local focused
      focused="$(adbq shell 'dumpsys input_method 2>/dev/null | grep -m1 -E "mServedView|mCurFocusedWindow|mInputShown"' 2>/dev/null | tr -d '\r')"
      if [ -z "$focused" ]; then
        err "没有可输入的输入框（dumpsys input_method 读不到焦点视图）"
        hint "先在 App 里点一下输入框，或用 dv input tap --text '<输入框提示>' 定位后再输入"
        [ "$json" = "1" ] && printf '{"ok":false,"code":6,"phase":"input","reason":"no_input_box"}\n'
        return "$EX_VERIFY"
      fi
      local esc="${payload// /%s}"
      adbq shell "input text '$esc'" >/dev/null 2>&1 || die "$EX_DATA" "input text 执行失败"
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"action":"text","chars":%s}\n' "${#payload}"
      else
        ok "已输入 ${#payload} 个字符（纯 ASCII）"
      fi
      return "$EX_OK" ;;

    key)
      case "$(printf '%s' "$payload" | tr '[:lower:]' '[:upper:]')" in
        BACK) payload=4 ;; HOME) payload=3 ;; ENTER) payload=66 ;; TAB) payload=61 ;;
        DEL|DELETE) payload=67 ;; MENU) payload=82 ;; APP_SWITCH) payload=187 ;;
        SPACE) payload=62 ;; ESC|ESCAPE) payload=111 ;; WAKEUP) payload=224 ;;
        POWER) payload=26 ;; VOLUME_UP) payload=24 ;; VOLUME_DOWN) payload=25 ;;
      esac
      adbq shell "input keyevent $payload" >/dev/null 2>&1 || die "$EX_DATA" "input keyevent 执行失败"
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"action":"key","key":%s}\n' "$(jstr "$payload")"
      else
        ok "已发送按键 $payload"
      fi
      return "$EX_OK" ;;
  esac
}
