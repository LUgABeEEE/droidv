#!/usr/bin/env bash
# lib/shot.sh —— 截图归档
dv_help_shot() { cat <<EOF
dv shot [-n N] [-o DIR] [--json]
  -n N   连拍 N 张（默认 1），逐张记录耗时
  -o DIR 输出目录（默认 \$DV_OUT/shots，会创建）
退出码：0 成功 · 2 参数错误 · 3 无设备 · 4 取数失败
EOF
}

dv_cmd_shot() {
  local json=$JSON_MODE n=1 dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -n) n="${2:-1}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -o) dir="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_shot; return "$EX_OK" ;;
      *) die "$EX_ARG" "shot 不认识的参数：$1" ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "$EX_ARG" "-n 需要正整数" ;; esac

  dv_need_device
  [ -n "$dir" ] || dir="$OUT_BASE/shots"
  dv_mkout "$dir" || die "$EX_DATA" "无法创建目录 $dir"

  local stamp; stamp="$(dv_ts)"
  local files=() times=()
  local i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    local f="$dir/shot-${stamp}-$i.png"
    local t0 t1
    t0=$(date +%s%N)
    if ! adbq exec-out screencap -p > "$f" 2>/dev/null; then
      err "截图失败（第 $i 张）"; return "$EX_DATA"
    fi
    t1=$(date +%s%N)
    local ms=$(( (t1 - t0) / 1000000 ))
    local size; size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$size" -lt 1000 ] && { err "截图文件异常（${size}B）：$f"; return "$EX_DATA"; }
    files+=("$f"); times+=("$ms")
    [ "$VERBOSE" = "1" ] && hint "第 $i 张 ${ms}ms ${size}B"
  done

  if [ "$json" = "1" ]; then
    local arr="" i2=0
    while [ "$i2" -lt "${#files[@]}" ]; do
      arr+="$([ "$i2" -gt 0 ] && printf ','){\"file\":$(jstr "${files[$i2]}"),\"ms\":$(jnum "${times[$i2]}"),\"bytes\":$(stat -c %s "${files[$i2]}")}"
      i2=$((i2+1))
    done
    printf '{"ok":true,"dir":%s,"count":%s,"shots":[%s]}\n' "$(jstr "$dir")" "${#files[@]}" "$arr"
    return "$EX_OK"
  fi
  ok "截图 ${#files[@]} 张 → $dir"
  hint "只要界面内容（文本/可点元素）用 dv peek：约 0.6k token，截图读图要 1.5k+ 且靠人看"
  local i3=0
  while [ "$i3" -lt "${#files[@]}" ]; do
    printf '  %s  %sms  %sB\n' "${files[$i3]}" "${times[$i3]}" "$(stat -c %s "${files[$i3]}")"
    i3=$((i3+1))
  done
  return "$EX_OK"
}
