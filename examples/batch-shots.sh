#!/usr/bin/env bash
# batch-shots.sh —— 批量截图归档：一台或多台设备，按 <serial>/<时间戳> 分目录，写一份 jsonl 索引
#
# 用法:
#   examples/batch-shots.sh <serial> [<serial> ...] [-n N] [-o DIR]
#   examples/batch-shots.sh --all                       # 用 adb devices 里所有在线设备
#   examples/batch-shots.sh 192.0.2.10:5555 -n 3 -o /tmp/shots
#
# 产物: <DIR>/<serial 安全化>-<ts>/shot-*.png + <DIR>/index.jsonl（一行一台）
# 退出码: 0 全部成功 · 1 有设备失败 · 3 一台设备都没有 · 2 参数错误
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DV="${DV:-$HERE/../dv}"

N=1; OUT="${DV_OUT:-$PWD/dv-out}/batch-shots"; ALL=0; SERIALS=()

die() { printf '✘ %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="${2:-1}"; shift 2 ;;
    -o) OUT="${2:-}"; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "不认识的参数：$1（-h 看用法）" ;;
    *) SERIALS+=("$1"); shift ;;
  esac
done
case "$N" in ''|*[!0-9]*) die "-n 需要正整数" ;; esac

mkdir -p "$OUT" || die "建不了目录：$OUT"
IDX="$OUT/index.jsonl"; : > "$IDX"

# --all：从 dv check 之外的轻量路径拿设备列表（避免依赖 dv 内部实现）
if [ "$ALL" = "1" ]; then
  ADB="${DV_ADB:-${ANDROID_HOME:+$ANDROID_HOME/platform-tools/adb}}"; ADB="${ADB:-adb}"
  while IFS= read -r s; do [ -n "$s" ] && SERIALS+=("$s"); done < <("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
fi

[ "${#SERIALS[@]}" -gt 0 ] || { printf '✘ 没有设备（给 serial，或用 --all）\n' >&2; exit 3; }

safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }   # 冒号等字符不能进目录名

fail=0
printf '%-24s %-6s %s\n' SERIAL OK DIR
for s in "${SERIALS[@]}"; do
  dir="$OUT/$(safe "$s")-$(date +%Y%m%d-%H%M%S)"
  json="$( "$DV" --serial "$s" shot --json -n "$N" -o "$dir" 2>/dev/null )"
  rc=$?
  if [ "$rc" = "0" ]; then
    ok=true
    printf '%-24s %-6s %s\n' "$s" "✔" "$dir"
  else
    ok=false; fail=$((fail+1))
    printf '%-24s %-6s %s\n' "$s" "✘($rc)" "-"
    json="$(printf '{"ok":false,"serial":%s,"exit":%s}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$s")" "$rc")"
  fi
  printf '%s\n' "$json" >> "$IDX"
done

echo
echo "索引：$IDX"
if [ "$fail" != "0" ]; then
  printf '✘ %d/%d 台失败（退出码 3=无设备 4=取数失败）\n' "$fail" "${#SERIALS[@]}" >&2
  exit 1
fi
printf '✔ %d 台全部归档\n' "${#SERIALS[@]}"
