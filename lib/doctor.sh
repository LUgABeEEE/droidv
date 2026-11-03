#!/usr/bin/env bash
# lib/doctor.sh —— 环境自检
# shellcheck source=ime.sh
. "$DV_BIN/lib/ime.sh"
dv_help_doctor() { cat <<EOF
dv doctor [--json] [--print-config]
  一次说清：adb 是否可用 / 设备是否在线 / Android+HyperOS 版本 / 被测包是否安装 /
  主机配对配额 deviceCount / 是否有悬挂 forward / 当前焦点
  --print-config  只打印每个生效配置值 + 来源（cli/env/conf/auto），不碰设备
退出码：0 正常 · 3 无设备 · 7 adb 缺失
EOF
}

dv_cmd_doctor() {
  local json=$JSON_MODE print_config=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --print-config) print_config=1; shift ;;
      -h|--help) dv_help_doctor; return "$EX_OK" ;;
      *) die "$EX_ARG" "doctor 不认识的参数：$1" ;;
    esac
  done

  # --print-config：逐项打印生效值 + 来源（cli/env/conf/auto），不碰设备
  if [ "$print_config" = "1" ]; then
    local retry boot poll
    retry="$(dv_t_retry "$DV_TIMEOUT")"; boot="$(dv_t_boot "$DV_TIMEOUT")"; poll="$(dv_t_poll "$DV_TIMEOUT")"
    if [ "$json" = "1" ]; then
      printf '{"ok":true,"config":{'
      printf '"serial":{"value":%s,"source":%s},' "$(jstr "$SERIAL")" "$(jstr "$SERIAL_SRC")"
      printf '"pkg":{"value":%s,"source":%s},' "$(jstr "$PKG")" "$(jstr "$PKG_SRC")"
      printf '"adb":{"value":%s,"source":%s},' "$(jstr "$ADB")" "$(jstr "$ADB_SRC")"
      printf '"out":{"value":%s,"source":%s},' "$(jstr "$OUT_BASE")" "$(jstr "$OUT_SRC")"
      printf '"gateway":{"value":%s,"source":%s},' "$(jstr "$GATEWAY")" "$(jstr "$([ -n "$GATEWAY" ] && printf 'env/conf' || printf 'unset')")"
      printf '"marker":{"value":%s,"source":%s},' "$(jstr "$MARKER")" "$(jstr "$([ -n "$MARKER" ] && printf 'env/conf' || printf 'unset')")"
      printf '"timeout":{"value":%s,"source":%s},' "$(jnum "$DV_TIMEOUT")" "$(jstr "$([ -n "${DV_TIMEOUT_SET:-}" ] && printf 'env/cli' || printf 'default')")"
      printf '"adb_timeout":{"value":%s,"source":%s},' "$(jnum "$DV_ADB_TIMEOUT")" "$(jstr "$([ -n "${DV_ADB_TIMEOUT_SET:-}" ] && printf 'env' || printf 'default')")"
      printf '"derived":{"retry_s":%s,"boot_s":%s,"poll_s":%s}' "$retry" "$boot" "$poll"
      printf '}}\n'
    else
      say "${C_B}dv doctor --print-config${C_0}（生效值 / 来源）"
      printf '  %-14s %-42s %s\n' "SERIAL"       "${SERIAL:-<未设置>}"  "$SERIAL_SRC"
      printf '  %-14s %-42s %s\n' "PKG"          "${PKG:-<未设置>}"     "$PKG_SRC"
      printf '  %-14s %-42s %s\n' "ADB"          "${ADB:-<未找到>}"     "$ADB_SRC"
      printf '  %-14s %-42s %s\n' "OUT"          "$OUT_BASE"           "$OUT_SRC"
      printf '  %-14s %-42s %s\n' "GATEWAY"      "${GATEWAY:-<未设置>}" "unset/env/conf"
      printf '  %-14s %-42s %s\n' "MARKER"       "${MARKER:-<未设置>}"  "unset/env/conf"
      printf '  %-14s %-42s %s\n' "DV_TIMEOUT"   "$DV_TIMEOUT"         "default/env/cli"
      printf '  %-14s %-42s %s\n' "ADB_TIMEOUT"  "$DV_ADB_TIMEOUT"     "default/env"
      printf '  %-14s retry=%ss boot=%ss poll=%ss（由 DV_TIMEOUT 派生）\n' "derived" "$retry" "$boot" "$poll"
    fi
    return "$EX_OK"
  fi

  local adb_ok=1 adb_ver="" online=0 rc=0 model="" android="" sdk="" hyper="" pkg_rel=0 pkg_dbg=0
  local quota="" fwd="" focus="" serial="$SERIAL"
  local ime_list="" ime_default="" show_hw="" ime_count=0 ime_ok=1 ime_blocked=0

  dv_resolve_adb 2>/dev/null || true   # B1：惰性解析（doctor 也要能在没设 DV_ADB 时用）
  adb_ver="$(timeout "$DV_ADB_TIMEOUT" "$ADB" version 2>/dev/null | head -1 | sed 's/Android Debug Bridge version //')"
  [ -n "$adb_ver" ] || adb_ok=0
  if [ "$adb_ok" != "1" ]; then
    err "找不到可执行的 adb：${ADB:-<未找到>}"
    hint "用 --adb PATH、环境变量 DV_ADB 或 dv.conf 的 CONF_ADB 指定"
    [ "$json" = "1" ] && printf '{"ok":false,"code":7,"phase":"doctor","hint":%s}\n' "$(jstr "找不到可执行的 adb")"
    return "$EX_ENV"
  fi

  if [ "$adb_ok" = "1" ]; then
    local rc2=0
    dv_resolve_serial >/dev/null 2>&1 || rc2=$?
    if [ "$rc2" = "7" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"code":7,"phase":"doctor","hint":%s}\n' "$(jstr "找不到可执行的 adb")"
      return "$EX_ENV"
    fi
    if [ "$rc2" = "2" ]; then
      err "有多台设备在线，请用 --serial 指定（dv devices 可看列表）"
      [ "$json" = "1" ] && printf '{"ok":false,"code":2,"phase":"doctor","hint":%s}\n' "$(jstr "有多台设备在线，请用 --serial 指定")"
      return "$EX_ARG"
    fi
    serial="$SERIAL"
    if [ -n "$serial" ] && dv_online "$serial"; then
      online=1
      model="$(dv_device_model)"
      android="$(adbq shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
      sdk="$(adbq shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
      hyper="$(adbq shell getprop ro.mi.os.version.name 2>/dev/null | tr -d '\r')"
      if [ -n "$PKG" ]; then
        dv_pkg_installed "$PKG" && pkg_rel=1
        dv_pkg_installed "$PKG.debug" && pkg_dbg=1
      fi
      focus="$(dv_focus_line)"
      fwd="$(adbq forward --list 2>/dev/null)"
      # IME 基线（只告警，绝不擅自改）
      local ime_raw
      ime_raw="$(adbq shell 'ime list -s' 2>&1 | tr -d '\r')"
      case "$ime_raw" in
        *SecurityException*|*WRITE_SECURE_SETTINGS*|*"Permission denial"*)
          ime_blocked=1; ime_list="" ;;   # ROM 限制：不是 dv 的失败，别当异常报
        *) ime_list="$(printf '%s\n' "$ime_raw" | grep -v '^$')" ;;
      esac
      ime_default="$(adbq shell 'settings get secure default_input_method' 2>/dev/null | tr -d '\r')"
      show_hw="$(adbq shell 'settings get secure show_ime_with_hard_keyboard' 2>/dev/null | tr -d '\r')"
      ime_count="$(printf '%s\n' "$ime_list" | grep -c . || true)"
      if [ "$ime_blocked" = "1" ]; then
        ime_ok=1      # 查不到就不下判断（MIUI 12.5 明确拒绝 ime list）
      else
        [ "${ime_count:-0}" -lt 2 ] && ime_ok=0
        printf '%s\n' "$ime_list" | grep -qxF "$ime_default" || ime_ok=0
      fi
    fi
  fi

  # 主机侧配对配额：**只有配置了 DV_GATEWAY/CONF_GATEWAY 才检查**（不属于 dv 的必知项）
  quota=""
  if [ -n "${GATEWAY:-}" ]; then
  quota="$(curl -s --max-time 3 "${GATEWAY%/}/api/mobile-access/lan/status" 2>/dev/null \
           | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("deviceCount",""))
except Exception: print("")' 2>/dev/null)"
  fi

  if [ "$json" = "1" ]; then
    printf '{"adb":%s,"adb_path":%s,"adb_version":%s,"serial":%s,"online":%s,' \
      "$(jbool "$adb_ok")" "$(jstr "$ADB")" "$(jstr "$adb_ver")" "$(jstr "$serial")" "$(jbool "$online")"
    printf '"model":%s,"android":%s,"sdk":%s,"hyperos":%s,' \
      "$(jstr "$model")" "$(jstr "$android")" "$(jstr "$sdk")" "$(jstr "$hyper")"
    printf '"pkg":%s,"pkg_installed":%s,"pkg_debug_installed":%s,' \
      "$(jstr "$PKG")" "$(jbool "$pkg_rel")" "$(jbool "$pkg_dbg")"
    printf '"pair_device_count":%s,"forwards":%s,"focus":%s,' \
      "$(jnum "${quota:-}")" "$(jstr "$fwd")" "$(jstr "$focus")"
    printf '"screen":%s,' "$(_dv_screen_json)"
    printf '"ime_count":%s,"ime_default":%s,"ime_list":%s,"ime_ok":%s,"ime_query_blocked":%s,"show_ime_with_hard_keyboard":%s}\n' \
      "$(jnum "${ime_count:-0}")" "$(jstr "$ime_default")" \
      "$(printf '%s' "$ime_list" | _ime_json_array 2>/dev/null || printf '[]')" \
      "$(jbool "$ime_ok")" "$(jbool "$ime_blocked")" "$(jstr "$show_hw")"
    [ "$online" = "1" ] && return "$EX_OK" || return "$EX_NODEV"
  fi

  say "${C_B}dv doctor${C_0}  (v$DV_VERSION)"
  say "────────────────────────────────────────────"
  if [ "$adb_ok" = "1" ]; then ok "adb        $ADB  (v$adb_ver)"
  else err "adb        $ADB 不可用"; fi

  if [ "$online" = "1" ]; then
    ok "设备       $serial"
    say "             model=$model  Android $android (SDK $sdk)  HyperOS ${hyper:-?}"
    if [ -z "$PKG" ]; then
      say "             包未指定（用 --pkg / DV_PKG / dv.conf 指定后才检查安装状态）"
    else
      [ "$pkg_rel" = "1" ] && ok "包         $PKG 已安装" || warn "包         $PKG 未安装"
    fi
    [ "$pkg_dbg" = "1" ] && say "             $PKG.debug 也在（调试变体）"
    if [ -z "${GATEWAY:-}" ]; then
      say "             配对配额未检查（未配置 DV_GATEWAY）"
    elif [ -n "$quota" ]; then
      if [ "$quota" -ge 32 ] 2>/dev/null; then warn "配对配额   deviceCount=$quota（已达上限 32，装调试包前要先清理）"
      else ok "配对配额   deviceCount=$quota"; fi
    else warn "配对配额   未配置（可选：设 DV_GATEWAY 指向网关，才有 deviceCount 可读）"; fi
    if [ -n "$fwd" ]; then warn "悬挂 forward："; printf '%s\n' "$fwd" | sed 's/^/             /'
    else ok "悬挂 forward 无"; fi
    case "$focus" in
      *"$PKG"*) ok "焦点       $focus" ;;
      *) warn "焦点       ${focus:-?}（不是 $PKG）" ;;
    esac
    local scr; scr="$(_dv_screen_json)"
    printf '  %-14s %s → dpr=%s → css %s\n' "屏幕" \
      "$(printf '%s' "$scr" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["wm_size"]+" @ "+d["wm_density"]+"dpi")' 2>/dev/null)" \
      "$(printf '%s' "$scr" | python3 -c 'import json,sys;print(json.load(sys.stdin)["dpr"])' 2>/dev/null)" \
      "$(printf '%s' "$scr" | python3 -c 'import json,sys;print(json.load(sys.stdin)["css_viewport"])' 2>/dev/null)"
    if [ "$ime_blocked" = "1" ]; then
      warn "IME        ROM 拒绝查询（SecurityException: WRITE_SECURE_SETTINGS）——跳过判断，不是 dv 的问题"
    elif [ "$ime_ok" = "1" ]; then
      ok "IME        $ime_count 个启用，默认 $ime_default"
    elif [ "$ime_count" -ge 1 ] 2>/dev/null && printf '%s\n' "$ime_list" | grep -qxF "$ime_default"; then
      # 只有 1 个 IME 是合法基线（很多用户就只留一个），不算异常
      ok "IME        $ime_count 个启用，默认 $ime_default（只装了一个输入法，属正常）"
    else
      warn "IME        $ime_count 个启用，默认 ${ime_default:-?}（默认 IME 不在启用列表里）"
      hint "默认 IME 不在启用列表里，或启用数 < 2 —— 修复：ime enable $ime_default（dv 不会自动改）"
      hint "做任何 ime disable 之前先 dv ime snapshot；恢复用 dv ime restore（按快照全量）"
    fi
    case "$show_hw" in
      0) warn "软键盘     show_ime_with_hard_keyboard=0（接了实体键盘时软键盘可能不弹）"
         hint "如需恢复：settings put secure show_ime_with_hard_keyboard 1（dv 不会自动改）" ;;
      *) say "              show_ime_with_hard_keyboard=$show_hw" ;;
    esac
  else
    err "设备       不在线"
    hint "USB：检查线缆/授权；无线：开发者选项→无线调试，然后 adb connect <ip:port>（端口会变）"
    hint "红线：不要用 adb reconnect（会摘掉 transport，设备可能再也连不回来）；也不要 kill-server"
    hint "已掉线时先确认平板亮屏、Wi-Fi 在线、无线调试开着"
  fi
  [ "$online" = "1" ] && return "$EX_OK" || return "$EX_NODEV"
}
