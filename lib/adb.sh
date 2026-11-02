#!/usr/bin/env bash
# lib/adb.sh —— adb 透传（强制超时 + 危险命令默认拒绝）
#
# 危险清单来自实测与红线（见 docs/redlines.md）：
#   reboot / root / remount / kill-server / reconnect / tcpip / uninstall / settings put
#   —— 前 5 个都真实伤过人或伤过环境（reconnect 让整台平板掉线，kill-server 让沙箱里的 USB 再也打不开）。

DV_DANGER_WORDS="reboot root remount kill-server reconnect tcpip uninstall"

dv_help_adb() { cat <<EOF
dv adb [--timeout N] [--allow-danger] -- <adb 子命令...>
  透传任意 adb 子命令（自动带上 -s <serial>），**强制超时**（默认 20 s）。
  默认拒绝危险子命令：reboot / root / remount / kill-server / reconnect / tcpip / uninstall / settings put
  需要时加 --allow-danger（会先打印一行警告）。
例子：
  dv adb -- shell echo ok
  dv adb -- shell getprop ro.product.model
  dv adb --allow-danger -- uninstall com.example.app
退出码：0 成功 · 2 参数错误/命中危险清单 · 3 无设备 · 4 超时或 adb 返回非 0
EOF
}

_adb_is_danger() {   # $* = 要透传的 adb 参数
  local w a
  for w in $DV_DANGER_WORDS; do
    for a in "$@"; do
      [ "$a" = "$w" ] && { printf '%s' "$w"; return 0; }
    done
  done
  # settings put 是两段式
  case "$*" in
    *"settings put"*|*"settings  put"*) printf 'settings put'; return 0 ;;
  esac
  return 1
}

dv_cmd_adb() {
  local tmo=20 allow=0 json=$JSON_MODE
  local -a argv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) tmo="${2:-20}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --allow-danger) allow=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) dv_help_adb; return "$EX_OK" ;;
      --) shift; argv=("$@"); break ;;
      -*) die "$EX_ARG" "adb 不认识的参数：$1（透传内容请写在 -- 之后）" ;;
      *) argv=("$@"); break ;;
    esac
  done
  [ "${#argv[@]}" -gt 0 ] || die "$EX_ARG" "用法：dv adb -- <adb 子命令...>"

  local danger
  if danger="$(_adb_is_danger "${argv[@]}")"; then
    if [ "$allow" != "1" ]; then
      err "拒绝执行危险命令：$danger"
      hint "这类命令会改设备状态或断开连接（reboot/kill-server/reconnect/tcpip 都真实伤过环境）"
      hint "确实需要时加 --allow-danger，并想好怎么恢复"
      [ "$json" = "1" ] && printf '{"ok":false,"refused":true,"danger":%s}\n' "$(jstr "$danger")"
      return "$EX_ARG"
    fi
    warn "允许危险命令：$danger（--allow-danger 已生效）"
  fi

  dv_need_device

  local out rc t0 t1 ms
  t0=$(date +%s%N)
  out="$(timeout "$tmo" "$ADB" ${SERIAL:+-s "$SERIAL"} "${argv[@]}" 2>&1)"; rc=$?
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))

  if [ "$rc" = "124" ]; then
    err "adb 超时（${tmo}s）：${argv[*]}"
    [ "$json" = "1" ] && printf '{"ok":false,"timeout":true,"ms":%s,"cmd":%s}\n' "$ms" "$(jstr "${argv[*]}")"
    return "$EX_DATA"
  fi

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"rc":%s,"ms":%s,"cmd":%s,"out":%s}\n' \
      "$([ "$rc" = "0" ] && printf true || printf false)" "$rc" "$ms" "$(jstr "${argv[*]}")" "$(jstr "$out")"
  else
    printf '%s\n' "$out"
    [ "$VERBOSE" = "1" ] && hint "rc=$rc ${ms}ms"
  fi
  [ "$rc" = "0" ] && return "$EX_OK" || return "$EX_DATA"
}
