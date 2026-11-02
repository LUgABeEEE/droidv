#!/usr/bin/env bash
# lib/ime.sh —— IME 快照 / 恢复 / 现状（防「关掉输入法后忘了恢复」复发）
#
# 背景（t9/t12 实测）：为了把大小写混合的配对密钥原样输进去，曾临时禁用全部 4 个 IME；
# 恢复时只 `ime enable` 了默认那个，另外 3 个就留在了禁用状态，直到用户发现「键盘不见了」。
# 规则：**任何要 ime disable 的流程，必须先 dv ime snapshot**。

DV_IME_SNAPSHOT="${DV_IME_SNAPSHOT:-}"

_ime_snapshot_path() {
  if [ -n "$DV_IME_SNAPSHOT" ]; then
    # 覆盖路径也按设备分文件：xxx.json → xxx-<serial>.json（避免跨设备串用）
    local ser2="${SERIAL:-${DV_SERIAL:-default}}"; ser2="${ser2//:/_}"
    case "$DV_IME_SNAPSHOT" in
      *.json) printf '%s' "${DV_IME_SNAPSHOT%.json}-${ser2}.json" ;;
      */)     printf '%s/ime-snapshot-%s.json' "${DV_IME_SNAPSHOT%/}" "$ser2" ;;
      *)      printf '%s-%s.json' "$DV_IME_SNAPSHOT" "$ser2" ;;
    esac
    return
  fi
  # B3：快照按设备隔离（无线序列号里的 ':' 换成 '_'）
  local ser="${SERIAL:-${DV_SERIAL:-default}}"; ser="${ser//:/_}"
  printf '%s/dv/ime-snapshot-%s.json' "${XDG_CACHE_HOME:-$HOME/.cache}" "$ser"
}

_ime_enabled() {   # 每行一个 IME id
  adbq shell 'ime list -s' 2>/dev/null | tr -d '\r' | grep -v '^$'
}
_ime_default() { adbq shell 'settings get secure default_input_method' 2>/dev/null | tr -d '\r'; }
_ime_show_hw() { adbq shell 'settings get secure show_ime_with_hard_keyboard' 2>/dev/null | tr -d '\r'; }

_ime_json_array() {  # stdin: 每行一个 → ["a","b"]
  python3 -c 'import json,sys; a=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(a))'
}

dv_help_ime() { cat <<EOF
dv ime snapshot [--json]   把当前「启用的 IME 列表 + 默认 IME + show_ime_with_hard_keyboard」存快照
dv ime restore  [--json]   按快照逐个 ime enable + ime set 默认，然后回读校验（不一致 → exit 6）
dv ime status   [--json]   只打印现状 + 快照是否存在/是否一致

快照路径：\${DV_IME_SNAPSHOT:-~/.cache/dv/ime-snapshot.json}（写不进去会退化到 \$DV_OUT/ime-snapshot.json）
规则：任何要 ime disable 的流程，先 dv ime snapshot；恢复一律按快照，不要只 enable 默认那个。
退出码：0 成功且一致 · 3 无设备 · 6 恢复后校验不一致 · 7 环境缺失
EOF
}

dv_cmd_ime() {
  local action="${1:-status}"; shift || true
  local json=$JSON_MODE
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) dv_help_ime; return "$EX_OK" ;;
      *) die "$EX_ARG" "ime 不认识的参数：$1" ;;
    esac
  done

  dv_need_device
  local snap; snap="$(_ime_snapshot_path)"

  case "$action" in
    snapshot)
      local enabled def showhw dir
      enabled="$(_ime_enabled)"; def="$(_ime_default)"; showhw="$(_ime_show_hw)"
      [ -n "$enabled" ] || { err "读不到已启用的 IME 列表"; return "$EX_DATA"; }

      dir="$(dirname "$snap")"
      if ! mkdir -p "$dir" 2>/dev/null || ! : > "$dir/.dv-write-test" 2>/dev/null; then
        # 退化到 DV_OUT（只读环境/容器里 ~/.cache 可能不可写）
        snap="$OUT_BASE/ime-snapshot-${SERIAL//:/_}.json"
        dir="$(dirname "$snap")"; mkdir -p "$dir" 2>/dev/null || true
        warn "快照默认路径不可写，退化到：$snap"
      fi
      rm -f "$dir/.dv-write-test" 2>/dev/null

      ENABLED="$enabled" DEF="$def" SHOWHW="$showhw" SER="$SERIAL" python3 - "$snap" <<'PY'
import json, os, sys, datetime
enabled = [l.strip() for l in os.environ.get("ENABLED", "").splitlines() if l.strip()]
snap = {
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "serial": os.environ.get("SER", ""),
    "default_ime": os.environ.get("DEF", ""),
    "enabled": enabled,
    "show_ime_with_hard_keyboard": os.environ.get("SHOWHW", ""),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(snap, f, ensure_ascii=False, indent=2)
print(json.dumps(snap, ensure_ascii=False), file=sys.stderr)   # F-09：人类提示走 stderr，stdout 只留一行 JSON
PY
      local rc=$?
      if [ "$json" = "1" ]; then
        printf '{"ok":%s,"snapshot":%s}\n' "$([ $rc = 0 ] && printf true || printf false)" "$(jstr "$snap")"
      else
        [ $rc = 0 ] && ok "IME 快照已保存：$snap" || { err "写快照失败：$snap"; return "$EX_DATA"; }
        say "  enabled  $(_ime_enabled | tr '\n' ' ')"
        say "  default  $def"
        say "  show_ime_with_hard_keyboard=$showhw"
      fi
      return $rc ;;

    restore)
      [ -f "$snap" ] || { err "没有快照：$snap"; hint "先 dv ime snapshot（要在 disable 之前做）"; return "$EX_DATA"; }
      # B3：快照必须是本机的，否则会把另一台设备的 IME 集合套上来
      local snap_ser
      snap_ser="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("serial",""))' "$snap" 2>/dev/null)"
      if [ -n "$snap_ser" ] && [ "$snap_ser" != "$SERIAL" ]; then
        err "这份快照属于另一台设备（快照 serial=$snap_ser，当前=$SERIAL）——拒绝恢复"
        hint "在**当前设备**上重新 dv ime snapshot；跨设备套用 IME 集合会把键盘布局搞乱"
        [ "$json" = "1" ] && printf '{"ok":false,"code":2,"phase":"ime","reason":"serial_mismatch","snapshot_serial":%s,"current":%s}\n' \
          "$(jstr "$snap_ser")" "$(jstr "$SERIAL")"
        return "$EX_ARG"
      fi
      local want_json; want_json="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("default_ime",""))' "$snap" 2>/dev/null)"
      local want_list; want_list="$(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).get("enabled",[])))' "$snap" 2>/dev/null)"
      [ -n "$want_list" ] || { err "快照里没有 enabled 列表"; return "$EX_DATA"; }

      local id
      while IFS= read -r id; do
        [ -z "$id" ] && continue
        adbq shell "ime enable $id" >/dev/null 2>&1
      done <<< "$want_list"

      # F-15：快照里没有、但当前启用的 IME 要 disable 掉（否则 restore 永远 exit 6）
      local cur_id
      while IFS= read -r cur_id; do
        [ -z "$cur_id" ] && continue
        printf '%s\n' "$want_list" | grep -qxF "$cur_id" && continue
        adbq shell "ime disable $cur_id" >/dev/null 2>&1
      done <<< "$(_ime_enabled)"
      [ -n "$want_json" ] && adbq shell "ime set $want_json" >/dev/null 2>&1
      sleep 1

      # 回读校验
      local now_list now_def missing extra
      now_list="$(_ime_enabled)"; now_def="$(_ime_default)"
      missing="$(comm -23 <(printf '%s\n' "$want_list" | sort) <(printf '%s\n' "$now_list" | sort) | tr '\n' ' ')"
      extra="$(comm -13 <(printf '%s\n' "$want_list" | sort) <(printf '%s\n' "$now_list" | sort) | tr '\n' ' ')"
      local ok_flag=0
      [ -z "$missing" ] && [ -z "$extra" ] && [ "$now_def" = "$want_json" ] && ok_flag=1

      if [ "$json" = "1" ]; then
        printf '{"ok":%s,"snapshot":%s,"want_default":%s,"now_default":%s,"missing":%s,"extra":%s,"enabled_now":%s}\n' \
          "$(jbool "$ok_flag")" "$(jstr "$snap")" "$(jstr "$want_json")" "$(jstr "$now_def")" \
          "$(jstr "$missing")" "$(jstr "$extra")" "$(printf '%s' "$now_list" | _ime_json_array)"
      else
        if [ "$ok_flag" = "1" ]; then
          ok "IME 已按快照恢复（$(printf '%s\n' "$now_list" | grep -c .) 个启用，默认 $now_def）"
        else
          err "恢复后与快照不一致"
          [ -n "$missing" ] && say "  仍缺：$missing"
          [ -n "$extra" ] && say "  多出：$extra"
          [ "$now_def" != "$want_json" ] && say "  默认 IME：期望 $want_json，实际 $now_def"
        fi
      fi
      [ "$ok_flag" = "1" ] && return "$EX_OK" || return "$EX_VERIFY" ;;

    status)
      local enabled def showhw have=0 match=-1
      enabled="$(_ime_enabled)"; def="$(_ime_default)"; showhw="$(_ime_show_hw)"
      [ -f "$snap" ] && have=1
      if [ "$have" = "1" ]; then
        local want_list want_def
        want_list="$(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1])).get("enabled",[])))' "$snap" 2>/dev/null)"
        want_def="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("default_ime",""))' "$snap" 2>/dev/null)"
        if [ "$want_list" = "$enabled" ] && [ "$want_def" = "$def" ]; then match=1; else match=0; fi
      fi
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"enabled":%s,"default_ime":%s,"show_ime_with_hard_keyboard":%s,"snapshot":%s,"has_snapshot":%s,"matches":%s}\n' \
          "$(printf '%s' "$enabled" | _ime_json_array)" "$(jstr "$def")" "$(jstr "$showhw")" "$(jstr "$snap")" \
          "$(jbool "$have")" "$([ "$match" = "1" ] && printf true || printf false)"
      else
        ok "IME 现状（$SERIAL）"
        say "  enabled  $(printf '%s\n' "$enabled" | tr '\n' ' ')"
        say "  default  $def"
        say "  show_ime_with_hard_keyboard=$showhw"
        if [ "$have" = "1" ]; then
          case "$match" in
            1) ok "与快照一致：$snap" ;;
            0) warn "与快照不一致：$snap（可 dv ime restore）" ;;
          esac
        else
          warn "没有快照（$snap）——做任何 ime disable 之前先 dv ime snapshot"
        fi
      fi
      return "$EX_OK" ;;
    *) die "$EX_ARG" "ime 不认识的动作：$action（snapshot|restore|status）" ;;
  esac
}
