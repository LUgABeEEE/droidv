#!/usr/bin/env bash
# lib/common.sh —— 配置解析 / 颜色 / 退出码 / adb 封装 / 设备发现 / JSON 工具
# 只被 dv（入口）source；子命令脚本通过 dv 调用，不单独 source 其它 lib。

# ---------- 退出码（与 README 一致） ----------
EX_OK=0        # 成功
EX_ARG=2       # 参数错误
EX_NODEV=3     # 无设备
EX_DATA=4      # 取数失败（重试后仍失败）
EX_CHAN=5      # 通道不可用（CDP / forward / HTTP）
EX_VERIFY=6    # 校验失败（package / marker / install 被拒）
EX_ENV=7       # 环境缺失（adb / SDK / node / JDK）
EX_BUILD=8     # 构建失败（Gradle 返回非 0）—— 仅 dv build

DV_VERSION="0.1.3"
DV_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- 颜色 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s✘%s %s\n' "$C_R" "$C_0" "$*" >&2; }
hint() { printf '%s  ↳ %s%s\n' "$C_D" "$*" "$C_0" >&2; }

# 统一失败出口：人类模式打错误 + 可选提示；--json 模式额外输出 {ok:false,code,phase,hint}
# 用法：die <code> <消息> [<hint>]
die() {
  local code="$1"; shift
  local msg="${1:-}"; shift || true
  local hintmsg="${1:-}"
  err "$msg"
  [ -n "$hintmsg" ] && printf '  ↳ %s\n' "$hintmsg" >&2
  if [ "${JSON_MODE:-0}" = "1" ]; then
    printf '{"ok":false,"code":%s,"phase":%s,"hint":%s}\n' \
      "$code" "$(jstr "${DV_PHASE:-cli}")" "$(jstr "$hintmsg")"
  fi
  exit "$code"
}

# ---------- 配置：conf < 环境变量 < 命令行 ----------
DV_CONF="${DV_CONF:-$DV_HOME/dv.conf}"
CONF_SERIAL=''; CONF_PKG=''; CONF_ADB=''; CONF_OUT=''; CONF_ACTIVITY=''; CONF_FORWARD_PORT=''; CONF_NPU_APK=''
if [ -f "$DV_CONF" ]; then
  # shellcheck disable=SC1090
  . "$DV_CONF"
fi

PKG="${DV_PKG:-${CONF_PKG:-}}"                 # 不再写死任何具体 App；需要时用 --pkg / DV_PKG / dv.conf
MARKER="${DV_MARKER:-${CONF_MARKER:-}}"        # uitree 的默认 marker（C 通道用），缺省为空=不校验
GATEWAY="${DV_GATEWAY:-${CONF_GATEWAY:-}}"     # 可选：主机侧网关地址，配了才做配对配额检查
ACTIVITY="${DV_ACTIVITY:-${CONF_ACTIVITY:-}}"     # 空=自动解析
_dv_default_adb() {
  # 顺序：显式(DV_ADB/CONF_ADB) → PATH → 常见安装路径（后者只是候选，不是唯一）
  command -v adb 2>/dev/null && return
  local c
  for c in \
           "$HOME/Android/Sdk/platform-tools/adb" \
           "$HOME/Library/Android/sdk/platform-tools/adb" \
           /usr/lib/android-sdk/platform-tools/adb /opt/android-sdk/platform-tools/adb; do
    [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  command -v adb 2>/dev/null || printf ''
}
# 惰性解析：先只看显式配置；真正要用 adb 时才去 PATH/常见路径里找（help/selftest 不该需要 adb）
ADB="${DV_ADB:-${CONF_ADB:-}}"
OUT_BASE="${DV_OUT:-${CONF_OUT:-$PWD/dv-out}}"
SERIAL="${DV_SERIAL:-${CONF_SERIAL:-}}"
FORWARD_PORT="${DV_FORWARD_PORT:-${CONF_FORWARD_PORT:-9333}}"
NPU_APK="${DV_NPU_APK:-${CONF_NPU_APK:-}}"

# 生效值来源：cli / env / conf / auto（供 dv doctor --print-config）
SERIAL_SRC="${SERIAL_SRC:-}"; PKG_SRC="${PKG_SRC:-}"; ADB_SRC="${ADB_SRC:-}"; OUT_SRC="${OUT_SRC:-}"
[ -n "$SERIAL_SRC" ] || { [ -n "${DV_SERIAL:-}" ] && SERIAL_SRC=env || { [ -n "${CONF_SERIAL:-}" ] && SERIAL_SRC=conf || SERIAL_SRC=auto; }; }
[ -n "$PKG_SRC" ]    || { [ -n "${DV_PKG:-}" ]    && PKG_SRC=env    || { [ -n "${CONF_PKG:-}" ]    && PKG_SRC=conf    || PKG_SRC=unset; }; }
[ -n "$ADB_SRC" ]    || { [ -n "${DV_ADB:-}" ]    && ADB_SRC=env    || { [ -n "${CONF_ADB:-}" ]    && ADB_SRC=conf    || ADB_SRC=auto; }; }
[ -n "$OUT_SRC" ]    || { [ -n "${DV_OUT:-}" ]    && OUT_SRC=env    || { [ -n "${CONF_OUT:-}" ]    && OUT_SRC=conf    || OUT_SRC=auto; }; }

JSON_MODE=0
VERBOSE="${DV_VERBOSE:-0}"

# ---------- adb（惰性） ----------
dv_resolve_adb() {
  if [ -n "$ADB" ] && [ -x "$ADB" ]; then return 0; fi
  [ -z "$ADB" ] && ADB="$(_dv_default_adb)"
  if [ -z "$ADB" ] || [ ! -x "$ADB" ]; then
    err "找不到可执行的 adb：${ADB:-<未找到>}"
    hint "用 --adb PATH、环境变量 DV_ADB 或 dv.conf 的 CONF_ADB 指定"
    hint "已尝试：DV_ADB / CONF_ADB / PATH 里的 adb / \$HOME/Android/Sdk / /usr/lib/android-sdk / /opt/android-sdk"
    hint "只是看文档不需要 adb：dv help <子命令>；无设备自测：dv selftest"
    exit "$EX_ENV"
  fi
}
dv_require_adb() { dv_resolve_adb; }

# 需要包名但没配置时，给出清晰报错（exit 2），而不是默默回落到某个具体项目
dv_require_pkg() {
  if [ -z "$PKG" ]; then
    err "没有指定被测包名"
    hint "用 --pkg <包名>、环境变量 DV_PKG 或 dv.conf 的 CONF_PKG；也可以先 dv packages 看看装了哪些"
    exit "$EX_ARG"
  fi
}

# 所有 adb 调用都带超时：设备卡死时 CLI 必须能返回，而不是一起挂住（实测踩过）
DV_ADB_TIMEOUT="${DV_ADB_TIMEOUT:-30}"

# 统一超时预算与派生值。DV_FAST=1 只影响 selftest（缩短 fake 延时），
# **不改变真机路径的派生值**（见 selftest 的断言）。
DV_TIMEOUT="${DV_TIMEOUT:-30}"
# 只给 selftest 用：DV_SELFTEST_FAST=1 时跳过等待（真机路径不读这个变量）
dv_sleep() { [ "${DV_SELFTEST_FAST:-0}" = "1" ] && return 0; sleep "${1:-0}"; }

dv_t_retry() { local t="${1:-$DV_TIMEOUT}"; local v=$((t / 15)); [ "$v" -lt 1 ] && v=1; printf '%s' "$v"; }  # 30→2
dv_t_boot()  { local t="${1:-$DV_TIMEOUT}"; local v=$(( (t + 3) / 4 )); [ "$v" -lt 2 ] && v=2; printf '%s' "$v"; }  # 30→8（向上取整，与历史行为一致）
dv_t_poll()  { local t="${1:-$DV_TIMEOUT}"; local v=$((t / 10)); [ "$v" -lt 1 ] && v=1; printf '%s' "$v"; }  # 30→3
adbr() { dv_resolve_adb; [ "${VERBOSE:-0}" = "1" ] && printf '%s\n' "  $ $ADB $*" >&2; timeout "$DV_ADB_TIMEOUT" "$ADB" "$@"; }                      # 不带 -s（devices / mdns / connect）
adbq() { dv_resolve_adb; [ "${VERBOSE:-0}" = "1" ] && printf '%s\n' "  $ $ADB ${SERIAL:+-s "$SERIAL "}$*" >&2; timeout "$DV_ADB_TIMEOUT" "$ADB" ${SERIAL:+-s "$SERIAL"} "$@"; }

# ---------- 设备发现 ----------
# 顺序：显式指定 → adb devices 唯一在线 → adb mdns（_adb-tls-connect）→ 失败
dv_resolve_serial() {
  # 到这里说明参数已经校验通过、确实要找设备：先确保 adb 可用（否则会被误判成"没有设备"）
  dv_resolve_adb
  local explicit="${1:-$SERIAL}"

  if [ -n "$explicit" ]; then
    if dv_online "$explicit"; then SERIAL="$explicit"; return 0; fi
    # 显式指定但离线：尝试重连一次
    warn "设备 $explicit 当前不在线，尝试 adb connect …"
    adbr connect "$explicit" >/dev/null 2>&1
    sleep 1
    if dv_online "$explicit"; then SERIAL="$explicit"; return 0; fi
    err "无法连上 $explicit"
    hint "先 adb connect <ip:port>；无线调试端口每次可能变化"
    return "$EX_NODEV"
  fi

  # adb devices 唯一在线
  local line devs
  devs="$(adbr devices | awk 'NR>1 && $2=="device" {print $1}')"
  if [ "$(printf '%s\n' "$devs" | grep -c .)" = "1" ]; then
    SERIAL="$devs"; return 0
  fi
  if [ "$(printf '%s\n' "$devs" | grep -c .)" -gt 1 ]; then
    err "有多台在线设备，请用 --serial 指定："
    printf '  %s\n' $devs >&2
    return "$EX_ARG"
  fi

  # mdns 自动发现（_adb-tls-connect）
  local m
  m="$(adbr mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $3}' | head -1)"
  if [ -n "$m" ]; then
    warn "adb devices 为空，尝试 mdns 发现：$m"
    adbr connect "$m" >/dev/null 2>&1
    sleep 2
    if dv_online "$m"; then SERIAL="$m"; return 0; fi
  fi

  err "没有可用设备"
  hint "USB：确认线缆与调试授权；无线：手机端开发者选项→无线调试，然后 adb connect <ip:port>"
  return "$EX_NODEV"
}

# F-07：多设备未指定 → 2（不是 3）；无设备 → 3
dv_need_device() {
  local rc=0
  dv_resolve_serial >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    7) die "$EX_ENV" "找不到可执行的 adb" "用 --adb PATH / DV_ADB / dv.conf 的 CONF_ADB 指定；装 platform-tools 后把 adb 放进 PATH" ;;
    2) die "$EX_ARG" "有多台设备在线，请用 --serial 指定（dv devices 可看列表）" ;;
    *) die "$EX_NODEV" "没有可用设备" "USB：检查线缆与调试授权；无线：开发者选项→无线调试，然后 adb connect <ip:port>" ;;
  esac
}

dv_online() { [ "$(timeout "$DV_ADB_TIMEOUT" "$ADB" -s "$1" get-state 2>/dev/null | head -1)" = "device" ]; }

# 焦点里的包名
dv_focus_pkg() {
  adbq shell 'dumpsys window | grep -m1 mCurrentFocus' 2>/dev/null \
    | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^ /}]*\).*/\1/p'
}
dv_focus_line() {
  local l
  l="$(adbq shell "dumpsys window | grep -E 'mCurrentFocus=|mCurrentFocusedWindow'" 2>/dev/null | grep 'mCurrentFocus=' | head -1)"
  [ -z "$l" ] && l="$(adbq shell 'dumpsys window | grep -m1 mCurrentFocusedWindow' 2>/dev/null)"
  printf '%s' "$l" | sed 's/^ *//'
}

dv_activity() {
  if [ -n "$ACTIVITY" ]; then printf '%s' "$ACTIVITY"; return; fi
  adbq shell "cmd package resolve-activity --brief $PKG" 2>/dev/null | tail -1
}

dv_pkg_installed() { adbq shell "pm list packages $1" 2>/dev/null | grep -q "^package:$1$"; }

dv_restart_app() {
  local act; act="$(dv_activity)"
  adbq shell "am force-stop $PKG" >/dev/null 2>&1
  dv_sleep 1
  local t0 t1
  t0=$(date +%s%N)
  adbq shell "am start -W -n $act" >/dev/null 2>&1
  t1=$(date +%s%N)
  printf '%s' $(( (t1 - t0) / 1000000 ))
}

# ---------- JSON ----------
# JSON 转义：纯 bash 实现（不起 python3 子进程——每条 JSON 都要转义，spawn 成本很可观）
jesc() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
jstr() { printf '"%s"' "$(jesc "${1-}")"; }
jnum() {   # 允许小数（dpr 之类）；非法给 null
  case "$1" in
    ''|*[!0-9.-]*) printf 'null' ;;
    *.*.*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}
jbool() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

# ---------- 帮助页统一脚注 ----------
dv_help_footer() {
  cat <<'EOF'

全局选项（必须写在子命令之前）：
  --serial <S>  --pkg <P>  --adb <PATH>  --out <DIR>  --json  --verbose  --no-color
  写在子命令之后会被当成子命令的未知选项 → exit 2（例：dv shot --serial X ✘ → dv --serial X shot ✔）
EOF
}


# D：屏幕几何（跨设备诊断第一眼要看的东西）
_dv_screen_json() {   # 打印 {"wm_size":"1200x2608","wm_density":"480","dpr":3.0,"css_viewport":"400x869"}
  local sz dens w h dpr css_w css_h
  sz="$(adbq shell 'wm size' 2>/dev/null | sed -n 's/.*: \([0-9]*x[0-9]*\).*/\1/p' | tail -1)"
  dens="$(adbq shell 'wm density' 2>/dev/null | sed -n 's/.*: \([0-9]*\).*/\1/p' | tail -1)"
  [ -n "$dens" ] || dens=160
  w="${sz%x*}"; h="${sz#*x}"
  dpr="$(python3 -c "print(round($dens/160, 2))" 2>/dev/null || echo 1)"
  if [ -n "$sz" ]; then
    css_w="$(python3 -c "print(int(round($w/($dens/160))))" 2>/dev/null || echo "")"
    css_h="$(python3 -c "print(int(round($h/($dens/160))))" 2>/dev/null || echo "")"
  fi
  printf '{"wm_size":%s,"wm_density":%s,"dpr":%s,"css_viewport":%s}' \
    "$(jstr "$sz")" "$(jstr "$dens")" "$(jnum "$dpr")" "$(jstr "${css_w}x${css_h}")"
}

# ---------- 杂项 ----------
need() { command -v "$1" >/dev/null 2>&1 || die "$EX_ENV" "缺少依赖：$1"; }

# F-04：cdp-eval.mjs 用的是 Node 22 的全局 WebSocket（Node 18/20 没有）
dv_need_node_ws() {
  need node
  if ! node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; then
    die "$EX_ENV" "当前 node 不支持全局 WebSocket（需要 Node >= 22，实测 $(node -v 2>/dev/null)）" \
        "升级 Node 到 22+，或改用不依赖 CDP 的通道（dv uitree / dv adb / dv wait-until --text）"
  fi
}

# F-05：python3 缺失会让所有 JSON 字段静默变空、uitree --find 静默 0 命中
dv_need_python() {
  command -v python3 >/dev/null 2>&1 || \
    die "$EX_ENV" "缺少 python3（dv 用它做 JSON 转义与 UI 树解析）" \
        "装 python3（apt install python3 / brew install python3），或把 python3 加进 PATH"
}

dv_ts() { date +%Y%m%d-%H%M%S; }
dv_mkout() { [ -d "$1" ] || mkdir -p "$1"; }

dv_free_port() {
  local p="${1:-9333}" i=0
  while [ $i -lt 50 ]; do
    if ! (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":$p ") ; then printf '%s' "$p"; return 0; fi
    p=$((p+1)); i=$((i+1))
  done
  printf '%s' "$p"
}

# 任何 forward 都回收（cdp 用 trap 调这个）
dv_forward_cleanup() {
  local port="${1:-}"
  if [ -n "$port" ]; then adm_forward_remove "$port"; else adbq forward --remove-all >/dev/null 2>&1; fi
}
adm_forward_remove() { adbq forward --remove "tcp:$1" >/dev/null 2>&1; }
