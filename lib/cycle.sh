#!/usr/bin/env bash
# lib/cycle.sh —— 全链路：重启 → CDP → 截图 → UI 树 → 归档
# 依赖 cdp/shot/uitree 三个子模块（dv 只 source 当前子命令的 lib，这里显式补齐）
# shellcheck source=cdp.sh
. "$DV_BIN/lib/cdp.sh"
# shellcheck source=shot.sh
. "$DV_BIN/lib/shot.sh"
# shellcheck source=uitree.sh
. "$DV_BIN/lib/uitree.sh"
dv_help_cycle() { cat <<EOF
dv cycle [--json] [--no-cdp]
  重启被测 App → 等页面就绪 → CDP report（可选）→ 截图 → UI 树 → 全部归档到 <out>/cycle-<ts>/
  前后都会打印「焦点是否回到被测 App」。
退出码：0 全成功 · 3 无设备 · 4 UI 树/截图失败 · 5 CDP 不可用（--no-cdp 时不计）
EOF
}

dv_cmd_cycle() {
  local json=$JSON_MODE no_cdp=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --no-cdp) no_cdp=1; shift ;;
      -h|--help) dv_help_cycle; return "$EX_OK" ;;
      *) die "$EX_ARG" "cycle 不认识的参数：$1" ;;
    esac
  done

  dv_need_device
  dv_require_pkg
  local stamp dir; stamp="$(dv_ts)"; dir="$OUT_BASE/cycle-$stamp"
  dv_mkout "$dir" || die "$EX_DATA" "无法创建 $dir"

  local focus0; focus0="$(dv_focus_line)"
  local ms; ms="$(dv_restart_app)"
  sleep 3
  local focus1; focus1="$(dv_focus_line)"

  local cdp_json="null" cdp_rc=0
  if [ "$no_cdp" = "0" ]; then
    cdp_json="$(dv_cmd_cdp report --json 2>/dev/null)"; cdp_rc=$?
    [ "$cdp_rc" != "0" ] && cdp_json="null"
  fi

  local shot_json shot_rc=0
  shot_json="$(dv_cmd_shot --json -n 1 -o "$dir" 2>/dev/null)"; shot_rc=$?

  local ui_json ui_rc=0
  ui_json="$(dv_cmd_uitree --json --dump-out "$dir/ui.xml" 2>/dev/null)"; ui_rc=$?

  printf '%s\n' "$cdp_json"   > "$dir/cdp.json"   2>/dev/null
  printf '%s\n' "$shot_json"  > "$dir/shot.json"  2>/dev/null
  printf '%s\n' "$ui_json"    > "$dir/uitree.json" 2>/dev/null

  local overall=0
  [ "$shot_rc" != "0" ] && overall=4
  [ "$ui_rc" != "0" ] && overall=4
  [ "$no_cdp" = "0" ] && [ "$cdp_rc" != "0" ] && [ "$overall" = "0" ] && overall=5

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"dir":%s,"restart_ms":%s,"focus_before":%s,"focus_after":%s,"cdp":%s,"shot":%s,"uitree":%s}\n' \
      "$([ "$overall" = "0" ] && printf true || printf false)" "$(jstr "$dir")" "$(jnum "$ms")" \
      "$(jstr "$focus0")" "$(jstr "$focus1")" "${cdp_json:-null}" "${shot_json:-null}" "${ui_json:-null}"
    return "$overall"
  fi

  say "${C_B}dv cycle${C_0}  → $dir"
  ok "重启 ${ms} ms"
  case "$focus1" in *"$PKG"*) ok "焦点回到被测 App：$focus1" ;; *) warn "焦点：${focus1:-?}" ;; esac
  [ "$no_cdp" = "0" ] && { [ "$cdp_rc" = "0" ] && ok "CDP 可用" || warn "CDP 不可用（退出码 $cdp_rc，常见原因：release 包无 socket）"; }
  [ "$shot_rc" = "0" ] && ok "截图完成" || err "截图失败"
  [ "$ui_rc" = "0" ] && ok "UI 树完成" || err "UI 树失败"
  say "  ${C_D}产物：cdp.json / shot.json / uitree.json / ui.xml / *.png${C_0}"
  return "$overall"
}
