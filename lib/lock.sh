#!/usr/bin/env bash
# lib/lock.sh —— 设备锁（跨进程/跨会话），防止两个自动化互相污染
#
# 设计：文件 + TTL（跨调用持久） + flock（读写原子）
#   · 纯 flock 不够：dv 进程一退锁就没了，起不到「会话间互斥」的作用
#   · 纯文件不够：并发 acquire 有竞态 → 用 flock 保护读-改-写临界区

DV_LOCK_TTL_DEFAULT=900

_dv_lock_path() {
  if [ -n "${DV_LOCK_FILE:-}" ]; then
    # 覆盖路径也按设备分文件：xxx → xxx-<serial>（与默认行为一致，便于测试隔离又保持语义）
    local ser0="${SERIAL:-${DV_SERIAL:-default}}"; ser0="${ser0//:/_}"
    printf '%s-%s' "$DV_LOCK_FILE" "$ser0"; return
  fi
  local d="${XDG_CACHE_HOME:-$HOME/.cache}/dv"
  # 每台设备一把锁：lock-<serial>；无线序列号带 ':'（如 192.0.2.10:40211）→ 换成 '_'
  local ser="${SERIAL:-${DV_SERIAL:-default}}"; ser="${ser//:/_}"
  if { mkdir -p "$d" && : > "$d/.w"; } >/dev/null 2>&1; then rm -f "$d/.w"; printf '%s/lock-%s' "$d" "$ser"; return; fi
  dv_mkout "$OUT_BASE" 2>/dev/null || true
  printf '%s/lock-%s' "$OUT_BASE" "$ser"
}

dv_help_lock() { cat <<EOF
dv lock acquire <持有者名字> [TTL秒=900] [--json]
dv lock release <持有者名字> [--json]
dv lock status [--json]
  跨进程的设备锁：持有者名字任意（例：assets-scout-t27）；TTL 到期自动失效，避免会话崩掉把设备锁死。
  锁文件：\${DV_LOCK_FILE:-~/.cache/dv/device.lock}（不可写时退化到 \$DV_OUT/device.lock）
退出码：0 成功 · 2 参数错误 · 3 **锁被别人持有**（会打印持有者/过期时间）
EOF
}

_dv_lock_read() {  # 打印 JSON（可能为空）
  local f; f="$(_dv_lock_path)"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

_dv_lock_field() {  # $1=字段名  $2=json
  printf '%s' "$2" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get(sys.argv[1],""))
except Exception:
    print("")' "$1" 2>/dev/null
}

dv_cmd_lock() {
  local action="${1:-status}"; shift || true
  local json=$JSON_MODE holder="" ttl="$DV_LOCK_TTL_DEFAULT"
  case "$action" in
    acquire|release)
      # 支持 `lock acquire <name> --ttl 900` 与 `lock acquire <name> 900`
      local -a rest=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --ttl) ttl="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "--ttl 需要值"; shift 2 ;;
          --json) json=1; shift ;;
          -*) die "$EX_ARG" "lock $action 不认识的选项：$1" ;;
          *) rest+=("$1"); shift ;;
        esac
      done
      holder="${rest[0]:-}"
      [ -n "$holder" ] || die "$EX_ARG" "lock $action 需要 <持有者名字>"
      [ "${#rest[@]}" -ge 2 ] && ttl="${rest[1]}"
      case "$ttl" in ''|*[!0-9]*) die "$EX_ARG" "TTL 需要正整数秒" ;; esac ;;
    status) ;;
    ''|help|-h|--help) dv_help_lock; return "$EX_OK" ;;
    *) die "$EX_ARG" "lock 不认识的动作：$action（acquire|release|status）" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) dv_help_lock; return "$EX_OK" ;;
      *) die "$EX_ARG" "lock 不认识的参数：$1" ;;
    esac
  done

  local f guard now left cur_holder cur_pid cur_exp live=0
  f="$(_dv_lock_path)"; guard="$f.guard"
  dv_mkout "$(dirname "$f")" 2>/dev/null || true
  now="$(date +%s)"

  # B14：`exec` 的重定向不是函数作用域，带 2>/dev/null 会把整个 shell 的 fd2 永久指向 /dev/null
  _lock_guard() { exec 9>"$guard" || return 1; flock -w 5 9 2>/dev/null || return 1; }
  _lock_unguard() { { exec 9>&-; } 2>/dev/null || true; }   # 同上：不能在 exec 上直接挂 2>/dev/null

  case "$action" in
    acquire)
      _lock_guard || die "$EX_DATA" "锁文件的 flock 超时（$guard）"
      local raw; raw="$(_dv_lock_read)"
      cur_holder="$(_dv_lock_field holder "$raw")"
      cur_exp="$(_dv_lock_field expiresAt "$raw")"
      [ -n "$cur_exp" ] && [ "$cur_exp" -gt "$now" ] 2>/dev/null && live=1
      if [ "$live" = "1" ] && [ "$cur_holder" != "$holder" ]; then
        left=$(( cur_exp - now ))
        _lock_unguard
        if [ "$json" = "1" ]; then
          printf '{"ok":false,"code":3,"phase":"lock","held_by":%s,"expires_in_s":%s,"lock":%s}\n' \
            "$(jstr "$cur_holder")" "$left" "$(jstr "$f")"
        fi
        local cur_pid cur_at
        cur_pid="$(_dv_lock_field pid "$raw")"; cur_at="$(_dv_lock_field acquiredAt "$raw")"
        err "设备锁被占用：$cur_holder（pid $cur_pid，acquired $(date -d "@$cur_at" '+%H:%M:%S' 2>/dev/null || echo "$cur_at")，剩余 ${left}s）"
        hint "等它释放，或换个 TTL 更短的时隙；确认没人用时可 dv lock release $cur_holder"
        return "$EX_NODEV"
      fi
      printf '{"holder":"%s","pid":%s,"acquiredAt":%s,"expiresAt":%s}\n' \
        "$holder" "$$" "$now" "$(( now + ttl ))" > "$f"
      _lock_unguard
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"holder":%s,"ttl":%s,"lock":%s}\n' "$(jstr "$holder")" "$ttl" "$(jstr "$f")"
      else
        ok "已获得设备锁：$holder（${ttl}s，$f）"
      fi
      return "$EX_OK" ;;

    release)
      _lock_guard || die "$EX_DATA" "锁文件的 flock 超时"
      local raw2; raw2="$(_dv_lock_read)"
      cur_holder="$(_dv_lock_field holder "$raw2")"
      if [ -z "$cur_holder" ]; then _lock_unguard; warn "本来就没有锁"; [ "$json" = "1" ] && printf '{"ok":true,"released":false}\n'; return "$EX_OK"; fi
      if [ "$cur_holder" != "$holder" ]; then
        _lock_unguard
        err "锁在 $cur_holder 手上，你不能释放"
        [ "$json" = "1" ] && printf '{"ok":false,"code":3,"phase":"lock","held_by":%s}\n' "$(jstr "$cur_holder")"
        return "$EX_NODEV"
      fi
      rm -f "$f"; _lock_unguard
      [ "$json" = "1" ] && printf '{"ok":true,"released":true,"holder":%s}\n' "$(jstr "$holder")" || ok "已释放设备锁：$holder"
      return "$EX_OK" ;;

    status)
      local raw3; raw3="$(_dv_lock_read)"
      cur_holder="$(_dv_lock_field holder "$raw3")"
      cur_exp="$(_dv_lock_field expiresAt "$raw3")"
      [ -n "$cur_exp" ] && [ "$cur_exp" -gt "$now" ] 2>/dev/null && live=1 || live=0
      left=0; [ "$live" = "1" ] && left=$(( cur_exp - now ))
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"held":%s,"holder":%s,"expires_in_s":%s,"lock":%s}\n' \
          "$(jbool "$live")" "$(jstr "$cur_holder")" "$left" "$(jstr "$f")"
      else
        if [ "$live" = "1" ]; then warn "设备锁：$cur_holder（剩余 ${left}s，$f）"
        else ok "设备锁：空闲（$f）"; fi
      fi
      return "$EX_OK" ;;
  esac
}
