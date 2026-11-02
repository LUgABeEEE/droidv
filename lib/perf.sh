#!/usr/bin/env bash
# lib/perf.sh —— 性能取数：gfxinfo 摘要 / 限时录屏
dv_help_perf() { cat <<EOF
dv perf --gfxinfo <pkg> [--json]     帧统计摘要（总帧数 / 掉帧数 / p50 / p90 / p95）
dv perf --record <秒> [-o DIR] [--json]   限时录屏并拉回（默认 \$DV_OUT/rec）
退出码：0 成功 · 2 参数错误 · 3 无设备 · 4 取数/拉回失败
EOF
}

dv_cmd_perf() {
  local json=$JSON_MODE mode="" pkg="" secs="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --gfxinfo) mode=gfx; pkg="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --record) mode=rec; secs="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -o) dir="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_perf; return "$EX_OK" ;;
      *) die "$EX_ARG" "perf 不认识的参数：$1" ;;
    esac
  done

  case "$mode" in
    gfx)
      [ -n "$pkg" ] || pkg="$PKG"
      [ -n "$pkg" ] || die "$EX_ARG" "用法：dv perf --gfxinfo <pkg>（或设 DV_PKG）"
      dv_need_device
      local raw
      raw="$(adbq shell "dumpsys gfxinfo $pkg" 2>/dev/null)"
      [ -n "$raw" ] || die "$EX_DATA" "dumpsys gfxinfo 没有输出（包名对吗？）"
      local parsed
      parsed="$(printf '%s\n' "$raw" | PKG_NAME="$pkg" python3 -c '
import os, re, sys, json
txt = sys.stdin.read()
def grab(pat, cast=float):
    m = re.search(pat, txt)
    if not m: return None
    try: return cast(m.group(1))
    except Exception: return None
d = {
  "ok": True,
  "pkg": os.environ.get("PKG_NAME", ""),
  "total_frames": grab(r"Total frames rendered:\s*(\d+)", int),
  "janky_frames": grab(r"Janky frames:\s*(\d+)", int),
  "janky_percent": grab(r"Janky frames:\s*\d+\s*\(([\d.]+)%\)"),
  "p50_ms": grab(r"50th percentile:\s*(\d+)ms", int),
  "p90_ms": grab(r"90th percentile:\s*(\d+)ms", int),
  "p95_ms": grab(r"95th percentile:\s*(\d+)ms", int),
  "p99_ms": grab(r"99th percentile:\s*(\d+)ms", int),
  "raw_head": "\n".join(txt.splitlines()[:6]),
}
print(json.dumps(d, ensure_ascii=False))
' 2>/dev/null)"
      [ -n "$parsed" ] || die "$EX_DATA" "gfxinfo 解析失败"
      # B15：包没在跑时 dumpsys 仍返回 200，但所有指标是 null —— 不能当成功
      local tf
      tf="$(printf '%s' "$parsed" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("total_frames") or "")' 2>/dev/null)"
      if [ -z "$tf" ] || [ "$tf" = "0" ]; then
        err "gfxinfo 没有帧数据（total_frames=${tf:-空}）——App 可能没在运行/还没渲染"
        hint "先启动它：dv adb -- shell am start -W -n <pkg>/<activity>，或 dv cycle；再重跑"
        [ "$json" = "1" ] && printf '{"ok":false,"code":6,"phase":"perf","reason":"no_frames","pkg":%s,"hint":%s}\n' \
          "$(jstr "$pkg")" "$(jstr "先启动 App 再取 gfxinfo")"
        return "$EX_VERIFY"
      fi
      if [ "$json" = "1" ]; then printf '%s\n' "$parsed"; return "$EX_OK"; fi
      ok "gfxinfo $pkg"
      printf '%s' "$parsed" | python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in ("total_frames","janky_frames","janky_percent","p50_ms","p90_ms","p95_ms","p99_ms"):
    print(f"  {k:<14} {d.get(k)}")'
      return "$EX_OK" ;;

    rec)
      case "$secs" in ''|*[!0-9]*) die "$EX_ARG" "--record 需要秒数（整数）" ;; esac
      dv_need_device
      [ -n "$dir" ] || dir="$OUT_BASE/rec"
      dv_mkout "$dir" || die "$EX_DATA" "无法创建 $dir"
      local remote=/data/local/tmp/dv-rec.mp4 local="$dir/rec-$(dv_ts).mp4"
      adbq shell "screenrecord --time-limit $secs $remote" >/dev/null 2>&1
      if ! adbq exec-out cat "$remote" > "$local" 2>/dev/null; then
        err "拉回录屏失败"; return "$EX_DATA"
      fi
      local size; size=$(stat -c %s "$local" 2>/dev/null || echo 0)
      [ "$size" -gt 1000 ] || { err "录屏文件异常（${size}B）"; return "$EX_DATA"; }
      adbq shell "rm -f $remote" >/dev/null 2>&1
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"file":%s,"bytes":%s,"seconds":%s}\n' "$(jstr "$local")" "$size" "$secs"
      else
        ok "录屏 ${secs}s → $local（${size}B）"
      fi
      return "$EX_OK" ;;
    *) die "$EX_ARG" "用法：dv perf --gfxinfo <pkg> | dv perf --record <秒>" ;;
  esac
}
