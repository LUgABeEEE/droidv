#!/usr/bin/env bash
# lib/check.sh —— 连接检查
dv_help_check() { cat <<EOF
dv check [--json]
  devices -l + 关键 getprop（型号/Android/SDK/HyperOS/WebView 提供者）+ mCurrentFocus
退出码：0 正常 · 3 无设备
EOF
}

dv_cmd_check() {
  local json=$JSON_MODE
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) dv_help_check; return "$EX_OK" ;;
      *) die "$EX_ARG" "check 不认识的参数：$1" ;;
    esac
  done

  local rc=0
  dv_resolve_serial >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    2) [ "$json" = "1" ] && printf '{"ok":false,"code":2,"phase":"connect","hint":"有多台设备在线，请用 --serial 指定"}\n'
       err "有多台设备在线，请用 --serial 指定"; return "$EX_ARG" ;;
    *) [ "$json" = "1" ] && printf '{"ok":false,"code":3,"phase":"connect","hint":"没有可用设备"}\n'
       err "没有可用设备"; return "$EX_NODEV" ;;
  esac

  local devices model android sdk hyper webview focus
  devices="$(adbr devices -l | tail -n +2)"
  model="$(dv_device_model)"
  android="$(adbq shell getprop ro.build.version.release | tr -d '\r')"
  sdk="$(adbq shell getprop ro.build.version.sdk | tr -d '\r')"
  hyper="$(adbq shell getprop ro.mi.os.version.name | tr -d '\r')"
  webview="$(adbq shell dumpsys webviewupdate 2>/dev/null | sed -n 's/.*Current WebView package (name, version): (\(.*\)).*/\1/p' | head -1)"
  focus="$(dv_focus_line)"

  if [ "$json" = "1" ]; then
    printf '{"online":true,"serial":%s,"model":%s,"android":%s,"sdk":%s,"hyperos":%s,"webview":%s,"focus":%s,"devices":%s,"screen":%s}\n' \
      "$(jstr "$SERIAL")" "$(jstr "$model")" "$(jstr "$android")" "$(jstr "$sdk")" \
      "$(jstr "$hyper")" "$(jstr "$webview")" "$(jstr "$focus")" "$(jstr "$devices")" "$(_dv_screen_json)"
    return "$EX_OK"
  fi

  ok "设备在线   $SERIAL"
  printf '%s\n' "$devices" | sed 's/^/             /'
  say "  model     $model"
  say "  Android   $android (SDK $sdk)   HyperOS $hyper"
  say "  WebView   ${webview:-?}"
  case "$focus" in
    *"$PKG"*) ok "焦点   $focus" ;;
    *) warn "焦点   ${focus:-?}" ;;
  esac
  return "$EX_OK"
}
