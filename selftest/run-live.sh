#!/usr/bin/env bash
# selftest/run-live.sh —— 真机逐个子命令实跑，日志落到 selftest/live-*.log（已被 .gitignore 排除）
#
# 用法:
#   bash selftest/run-live.sh [serial]
#     serial 省略时走 dv 自己的自动发现（adb devices → mdns）
#
# 可选环境变量:
#   DV_PKG           被测包名（不设则跳过需要包名的步骤：check/uitree/cycle/cdp/logcat/perf）
#   DV_LIVE_APK      install 用的 APK（不设则跳过 install）
#   DV_LIVE_PKG      该 APK 的包名（默认 com.example.app，仅用于装完卸载）
#   DV_BUILD_PROJ    dv build 要构建的 Gradle 工程目录（不设则跳过 build）
#   DV_LIVE_BROWSER_PKG  CDP 阳对照用的系统浏览器包名（默认 com.android.browser）
#   DV_ADB           adb 路径（默认 $ANDROID_HOME/platform-tools/adb，再找 PATH）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DV="$HERE/../dv"
OUT="$HERE/live-out"
export NO_COLOR=1
[ -n "${1:-}" ] && export DV_SERIAL="$1"
export DV_OUT="$OUT"

PKG="${DV_PKG:-}"
G=(--json)
[ -n "${DV_SERIAL:-}" ] && G+=(--serial "$DV_SERIAL")
[ -n "$PKG" ] && G+=(--pkg "$PKG")

# 裸 adb（只给脚本自己的收尾动作）：优先 DV_ADB，其次 $ANDROID_HOME，最后 PATH
ADB="${DV_ADB:-${ANDROID_HOME:+$ANDROID_HOME/platform-tools/adb}}"
ADB="${ADB:-adb}"
ADB_ARGS=(); [ -n "${DV_SERIAL:-}" ] && ADB_ARGS=(-s "$DV_SERIAL")

log() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
run() {  # run <名字> <dv 参数...>
  local name="$1"; shift
  local f="$HERE/live-$name.log"
  { printf '$ dv %s\n' "$*"; "$DV" "$@" 2>&1; printf '\n[exit=%s]\n' "$?"; } | tee "$f"
}
skip() { printf '\033[2m跳过 %s：%s\033[0m\n' "$1" "$2"; }

log "0) doctor"
"$DV" doctor | tee "$HERE/live-doctor.log"; echo "[exit=${PIPESTATUS[0]}]" | tee -a "$HERE/live-doctor.log"
if ! "$DV" devices >/dev/null 2>&1; then
  echo "设备不可用，终止。先 adb connect <device-ip>:<port>，或让用户打开无线调试。"
  exit 3
fi

if [ -n "$PKG" ]; then
  log "1) check"
  run check check
else
  skip check "未设置 DV_PKG"
fi

log "2) shot（3 张）"
run shot shot -n 3

if [ -n "$PKG" ]; then
  log "3) uitree（带文本查询）"
  run uitree uitree --json --find "设置"

  log "4) cycle（全链路，含 CDP 尝试）"
  run cycle cycle --json
else
  skip "uitree / cycle" "未设置 DV_PKG"
fi

log "5) npu check（只读）"
run npu-check npu check

if [ -n "${DV_LIVE_APK:-}" ] && [ -f "${DV_LIVE_APK}" ]; then
  log "6) install（装完即卸）"
  INSTALL_PKG="${DV_LIVE_PKG:-com.example.app}"
  run install install --apk "$DV_LIVE_APK"
  "$ADB" "${ADB_ARGS[@]}" uninstall "$INSTALL_PKG" 2>&1 | tee -a "$HERE/live-install.log"
else
  skip install "未设置 DV_LIVE_APK（或文件不存在）"
fi

log "7) cdp：release 包（应判 5）+ 浏览器阳对照（应 0）"
if [ -n "$PKG" ]; then
  run cdp-release cdp version
else
  skip cdp "未设置 DV_PKG"
fi
BR_PKG="${DV_LIVE_BROWSER_PKG:-com.android.browser}"
BR_PID="$("$ADB" "${ADB_ARGS[@]}" shell pidof "$BR_PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
if [ -z "$BR_PID" ]; then
  "$ADB" "${ADB_ARGS[@]}" shell am start -a android.intent.action.VIEW -d https://example.com >/dev/null 2>&1
  sleep 4
  BR_PID="$("$ADB" "${ADB_ARGS[@]}" shell pidof "$BR_PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
fi
if [ -n "$BR_PID" ]; then
  run cdp-browser --pkg "$BR_PKG" cdp report
  run cdp-browser-eval --pkg "$BR_PKG" cdp eval 'document.title'
else
  skip "浏览器阳对照" "$BR_PKG 未运行"
fi

if [ -n "$PKG" ]; then
  log "8) logcat（按包名 + JSON）"
  run logcat logcat --pkg "$PKG" -n 20 --json

  log "10) perf --gfxinfo"
  run perf perf --gfxinfo "$PKG" --json
else
  skip "logcat / perf" "未设置 DV_PKG"
fi

log "9) adb 透传（安全命令）"
run adb-passthrough adb -- shell echo ok

log "11) crash"
run crash crash --json

log "12) dv build（真构建，不 --install）"
if [ -n "${DV_BUILD_PROJ:-}" ] && [ -d "${DV_BUILD_PROJ}" ]; then
  run build build --project "$DV_BUILD_PROJ" --variant debug --json
else
  skip build "未设置 DV_BUILD_PROJ（或目录不存在）"
fi

log "完成。日志：$HERE/live-*.log；产物：$OUT"
