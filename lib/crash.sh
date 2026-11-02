#!/usr/bin/env bash
# lib/crash.sh —— 崩溃取证：crash 缓冲 + ANR 摘要 + tombstone 列表
dv_help_crash() { cat <<EOF
dv crash [-n N] [--json]
  logcat -b crash 最后 N 行（默认 100）+ dumpsys activity 里的 ANR 摘要 + /data/tombstones 列表
  tombstone 目录通常只有 root 可读；读不到会如实说明（不是失败）。
退出码：0 成功 · 3 无设备 · 4 取数失败
EOF
}

dv_cmd_crash() {
  local json=$JSON_MODE n=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -n) n="${2:-100}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_crash; return "$EX_OK" ;;
      *) die "$EX_ARG" "crash 不认识的参数：$1" ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "$EX_ARG" "-n 需要正整数" ;; esac

  dv_need_device

  local crashlog anr tombs
  crashlog="$(adbq logcat -b crash -d -v threadtime 2>/dev/null | tail -n "$n")"
  anr="$(adbq shell 'dumpsys activity 2>/dev/null | grep -iE "ANR in |anr=" | head -20' | tr -d '\r')"
  tombs="$(adbq shell 'ls -la /data/tombstones 2>&1 | head -20' | tr -d '\r')"

  local tomb_ok=1
  printf '%s' "$tombs" | grep -qiE 'Permission denied|No such file' && tomb_ok=0

  if [ "$json" = "1" ]; then
    printf '{"ok":true,"serial":%s,"crash_lines":%s,"crash":%s,"anr":%s,"tombstones_readable":%s,"tombstones":%s}\n' \
      "$(jstr "$SERIAL")" "$(printf '%s\n' "$crashlog" | grep -c . || true)" \
      "$(jstr "$crashlog")" "$(jstr "$anr")" "$(jbool "$tomb_ok")" "$(jstr "$tombs")"
    return "$EX_OK"
  fi

  say "${C_B}dv crash${C_0}  ($SERIAL)"
  say "── logcat -b crash（最后 $n 行） ──"
  if [ -n "$crashlog" ]; then printf '%s\n' "$crashlog" | tail -n 30 | sed 's/^/  /'
  else say "  （空：本次开机以来没有崩溃记录）"; fi
  say "── ANR 摘要 ──"
  if [ -n "$anr" ]; then printf '%s\n' "$anr" | sed 's/^/  /'; else say "  （dumpsys activity 里没有 ANR 记录）"; fi
  say "── /data/tombstones ──"
  if [ "$tomb_ok" = "1" ]; then printf '%s\n' "$tombs" | sed 's/^/  /'
  else warn "  读不到（需要 root）—— 这不是失败，只是权限限制"; printf '%s\n' "$tombs" | head -3 | sed 's/^/  /'; fi
  return "$EX_OK"
}
