#!/usr/bin/env bash
# lib/packages.sh —— 列出设备上的包（只读）
dv_help_packages() { cat <<EOF
dv packages [--filter SUBSTR] [--third-party] [--json]
  列出已安装包名；--filter 按子串过滤；--third-party 只看第三方（pm list packages -3）
退出码：0 成功 · 3 无设备
EOF
}

dv_cmd_packages() {
  local json=$JSON_MODE filter="" third=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --filter) filter="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --third-party) third=1; shift ;;
      -h|--help) dv_help_packages; return "$EX_OK" ;;
      -*) die "$EX_ARG" "packages 不认识的参数：$1" ;;
      *) die "$EX_ARG" "packages 不接受位置参数：$1" ;;
    esac
  done

  dv_need_device
  local args="pm list packages"
  [ "$third" = "1" ] && args="pm list packages -3"
  local raw
  raw="$(adbq shell "$args" 2>/dev/null | tr -d '\r' | sed 's/^package://' | grep -v '^$' | sort)"
  [ -n "$filter" ] && raw="$(printf '%s\n' "$raw" | grep -F -- "$filter" || true)"

  local count; count="$(printf '%s\n' "$raw" | grep -c . || true)"
  if [ "$json" = "1" ]; then
    printf '{"ok":true,"serial":%s,"count":%s,"packages":%s}\n' \
      "$(jstr "$SERIAL")" "$(jnum "$count")" "$(printf '%s' "$raw" | python3 -c 'import json,sys;print(json.dumps([l for l in sys.stdin.read().splitlines() if l.strip()]))')"
    return "$EX_OK"
  fi
  printf '%s\n' "$raw"
  warn "共 $count 个包${filter:+（filter=$filter）}"
  return "$EX_OK"
}
