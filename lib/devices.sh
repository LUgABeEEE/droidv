#!/usr/bin/env bash
# lib/devices.sh —— 设备列表（只读）
dv_help_devices() { cat <<EOF
dv devices [--json]
  列出全部设备：序列号 / 状态 / 型号 / product:device / transport / 有线(usb)或无线(tcp)
退出码：0 成功 · 3 无设备 · 7 环境缺失
EOF
}

dv_cmd_devices() {
  local json=$JSON_MODE
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) dv_help_devices; return "$EX_OK" ;;
      -*) die "$EX_ARG" "devices 不认识的参数：$1" ;;
      *) die "$EX_ARG" "devices 不接受位置参数：$1" ;;
    esac
  done

  # 必须在主 shell 里先解析 adb：`$(adbr …)` 里的 die 只会杀掉子 shell，
  # 主 shell 会拿着空结果误报「没有在线设备（exit 3）」，掩盖真正原因「缺 adb（exit 7）」。
  dv_require_adb
  local raw; raw="$(timeout "$DV_ADB_TIMEOUT" "$ADB" devices -l 2>/dev/null | tail -n +2 | grep -v '^$' || true)"
  local count; count="$(printf '%s\n' "$raw" | grep -c . || true)"

  if [ "$json" = "1" ]; then
    printf '%s\n' "$raw" | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split()
    serial, state = parts[0], (parts[1] if len(parts) > 1 else "?")
    kv = {}
    for p in parts[2:]:
        if ":" in p:
            k, v = p.split(":", 1)
            kv[k] = v
    rows.append({
        "serial": serial,
        "state": state,
        "model": kv.get("model", ""),
        "product": kv.get("product", ""),
        "device": kv.get("device", ""),
        "transport_id": kv.get("transport_id", ""),
        "transport": "wifi" if ":" in serial else "usb",
        "usb_port": kv.get("usb", ""),
    })
print(json.dumps({"ok": True, "count": len(rows), "devices": rows}, ensure_ascii=False))
'
    return "$EX_OK"
  fi

  if [ "$count" = "0" ]; then
    err "没有在线设备"
    hint "USB：检查线缆与调试授权；无线：开发者选项→无线调试，然后 adb connect <ip:port>"
    [ "$json" = "1" ] && printf '{"ok":false,"code":3,"phase":"devices","count":0,"hint":"没有在线设备"}\n'
    return "$EX_NODEV"
  fi
  ok "在线设备 ${count} 台"
  printf '%s\n' "$raw" | awk '{
      serial=$1; state=$2; model=""; prod=""; dev=""; tid="";
      for (i=3;i<=NF;i++){ split($i,kv,":"); if(kv[1]=="model")model=kv[2]; else if(kv[1]=="product")prod=kv[2]; else if(kv[1]=="device")dev=kv[2]; else if(kv[1]=="transport_id")tid=kv[2]; }
      link=(serial ~ /:/) ? "wifi" : "usb";
      printf "  %-24s %-8s %-9s %-22s %s/%s  transport=%s\n", serial, state, link, model, prod, dev, tid;
    }'
  return "$EX_OK"
}
