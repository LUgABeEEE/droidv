#!/usr/bin/env bash
# lib/logcat.sh —— logcat 取数（按包名/pid/标签/级别过滤，支持 --json / --crash / --follow）
#
# 实测依据：WebView 的 console 默认**不进** logcat，只有 chromium native 日志进；
# 所以「按 tag 抓 WebView 日志」时要抓 `chromium` 而不是 `console`。

dv_help_logcat() { cat <<EOF
dv logcat [--pkg P] [--pid N] [--tag T] [--level V|D|I|W|E] [-n N] [--since T] [--crash] [--json] [--follow [秒]]
  --pkg P     按进程名过滤（内部用 pidof 取 pid；取不到就退回不过滤并给提示）
  --pid N     直接指定 pid（优先于 --pkg）
  --tag T     只保留该 tag（等价 logcat -s T:*）
  --all-pids  不按进程过滤（默认按包名 pid 过滤；WebView 子进程的同 tag 日志会被排除）
  --level L   最低级别（V/D/I/W/E），默认 V
  -n N        取最后 N 行（默认 200）
  --since T   透传给 logcat 的 -T（如 '10:00:00.000' 或 '2026-11-02 10:00:00.000'）
  --crash     只读崩溃缓冲（logcat -b crash）
  --json      每行一个对象 {ts,level,tag,pid,msg}
  --follow N  持续输出（最多 N 秒，默认 30；Ctrl-C 可中断）
退出码：0 成功 · 2 参数错误 · 3 无设备 · 4 取数失败
EOF
}

_logcat_pid() {
  local p="$1"
  [ -z "$p" ] && { printf ''; return; }
  adbq shell "pidof $p" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}

# 把 threadtime 行解析成 JSON：MM-DD HH:MM:SS.mmm PID TID LVL TAG: msg
_logcat_to_json() {
  python3 -c '
import re, sys, json
pat = re.compile(r"^(\d\d-\d\d)\s+(\d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.*?)\s*:\s(.*)$")
for line in sys.stdin:
    line = line.rstrip("\n")
    m = pat.match(line)
    if not m:
        continue
    d, t, pid, tid, lvl, tag, msg = m.groups()
    print(json.dumps({"ts": f"{d} {t}", "level": lvl, "tag": tag.strip(),
                      "pid": int(pid), "tid": int(tid), "msg": msg}, ensure_ascii=False))
'
}

dv_cmd_logcat() {
  local json=$JSON_MODE pkg="" pid="" tag="" level="V" n=200 since="" crash=0 follow=0 follow_secs=30 all_pids=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --pkg) pkg="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --pid) pid="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --tag) tag="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --level) level="${2:-V}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -n) n="${2:-200}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --since) since="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --all-pids) all_pids=1; shift ;;
      --crash) crash=1; shift ;;
      --follow) follow=1
        case "${2:-}" in ''|--*) shift ;; *) follow_secs="$2"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;; esac ;;
      -h|--help) dv_help_logcat; return "$EX_OK" ;;
      *) die "$EX_ARG" "logcat 不认识的参数：$1" ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "$EX_ARG" "-n 需要正整数" ;; esac
  # B16：与其它子命令一致，--pkg 缺省走 DV_PKG / dv.conf
  [ -z "$pkg" ] && pkg="$PKG"
  case "$level" in V|D|I|W|E) ;; *) die "$EX_ARG" "--level 只能是 V/D/I/W/E" ;; esac

  dv_need_device

  [ -n "$pid" ] || pid="$(_logcat_pid "$pkg")"
  if [ -n "$pkg" ] && [ -z "$pid" ]; then
    warn "pidof $pkg 没拿到 pid（进程没在跑？）—— 退化为不按进程过滤"
  fi

  local -a args=(logcat -d -v threadtime)
  [ "$crash" = "1" ] && args=(-b crash -d -v threadtime)
  [ -n "$tag" ] && args+=(-s "$tag:$level")
  [ -z "$tag" ] && [ "$level" != "V" ] && args+=("*:$level")
  [ -n "$since" ] && args+=(-T "$since")

  local raw="" pid_server=""   # 必须初始化为空：set -u 下 raw+= 对未定义变量会直接崩
  # 服务端按 pid 裁窗口：忙设备上目标进程的行会被全局 -t 窗口挤出（PR #1 实测：客户端过滤后 0 行仍报 ok）
  [ -n "$pid" ] && [ "$all_pids" != "1" ] && [ "$follow" != "1" ] && pid_server="$pid"
  if [ -n "$pid_server" ]; then
    local p one
    for p in $pid_server; do
      one="$(adbq "${args[@]}" --pid="$p" -t "$((n * 3 + 50))" 2>/dev/null)"
      [ -n "$one" ] && raw+="$one"$'\n'
    done
    if [ -z "$raw" ]; then
      # 老设备 / 老 logcat 不认 --pid：退回全局取窗 + 客户端过滤
      pid_server=""
      raw="$(adbq "${args[@]}" -t "$((n * 6 + 200))" 2>/dev/null)"
    elif [ "$(printf '%s' "$pid_server" | wc -w)" -gt 1 ]; then
      raw="$(printf '%s\n' "$raw" | sort -s -k1,1 -k2,2)"   # 多个 pid 拼接后按时间归并
    fi
  elif [ "$follow" != "1" ]; then
    raw="$(adbq "${args[@]}" -t "$((n * 6 + 200))" 2>/dev/null)"
  fi

  if [ "$follow" = "1" ]; then
    # 持续模式：先给已有的 -n 行，再跟流（限时）
    raw="$(timeout "$follow_secs" "$ADB" ${SERIAL:+-s "$SERIAL"} logcat -v threadtime \
            ${tag:+-s "$tag:$level"} ${tag:+} 2>/dev/null | head -n "$((n * 50))")"
  fi
  # 注意：非 follow 路径的 raw 已在上面按 pid 取好，别再无条件重取一次
  # （0.1.4 的坑：这里覆盖回全局取窗，--pid 白做，183k 行全拉回本地过滤）
  [ -n "$raw" ] || { warn "logcat 没有返回内容（缓冲区空或没有匹配）"; [ "$json" = "1" ] && printf '{"ok":true,"lines":0,"items":[]}\n'; return "$EX_OK"; }

  # 客户端过滤（pid）+ 截断
  local filtered pid_filter=0
  [ "$all_pids" = "1" ] && pid=""
  [ -n "$pid" ] && pid_filter=1
  filtered="$(printf '%s\n' "$raw" | awk -v pids="$pid" -v n="$n" '
    BEGIN { split(pids, pset, " ") }
    {
      keep = 1
      if (pids != "") {
        keep = 0
        for (k in pset) if (pset[k] != "" && $3 == pset[k]) { keep = 1; break }
      }
      if (keep) buf[++c] = $0
    }
    END {
      start = (c - n > 0) ? c - n + 1 : 1
      for (i = start; i <= c; i++) print buf[i]
    }')"
  # 只在「退回客户端过滤」时才可能真的丢行；服务端 --pid 已经裁过窗口，不需要告警
  if [ "$pid_filter" = "1" ] && [ -z "$pid_server" ]; then
    local total kept
    total=$(printf '%s\n' "$raw" | grep -cE '^[0-9][0-9]-[0-9][0-9] ' || true)
    kept=$(printf '%s\n' "$filtered" | grep -cE '^[0-9][0-9]-[0-9][0-9] ' || true)
    if [ "$total" -gt "$kept" ]; then
      warn "按进程（$pid）过滤掉 $((total - kept)) 行，可能来自 WebView 子进程等；加 --all-pids 可全部保留"
    fi
  fi

  if [ "$json" = "1" ]; then
    printf '%s\n' "$filtered" | _logcat_to_json | python3 -c '
import sys, json
items = [json.loads(l) for l in sys.stdin if l.strip()]
print(json.dumps({"ok": True, "lines": len(items), "pkg": sys.argv[1] if len(sys.argv) > 1 else "",
                  "crash": sys.argv[2] == "1", "items": items}, ensure_ascii=False))
' "$pkg" "$crash"
    return "$EX_OK"
  fi

  printf '%s\n' "$filtered" | tail -n "$n"
  return "$EX_OK"
}
