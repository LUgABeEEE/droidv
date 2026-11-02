#!/usr/bin/env bash
# lib/install.sh —— 安装 debug 包（自动点 HyperOS「继续安装」弹窗）
#
# 实测（HyperOS / MIUI 上的行为，别的 ROM 可能不同）：
#   · `adb install` 会拉起 com.miui.securitycenter/.permcenter.install.AdbInstallActivity
#   · 弹窗是「继续安装 / 拒绝(10)」，**10 秒倒计时，超时即拒绝** → INSTALL_FAILED_USER_RESTRICTED
#   · 弹窗存活期 uiautomator dump 返回 0 字节 → 只能按坐标点
#   · 2272×3408 竖屏下按钮在 (846, 2002)

# 安装弹窗的「继续安装」按钮坐标。
# 默认 846,2002 来自 **小米平板 9 Pro Max（2272×3408 @400dpi）** 实测；
# 其它分辨率（例如手机 1200×2608）请设 DV_INSTALL_TAP="x,y" / CONF_INSTALL_TAP。
# 传 none 表示不自动点（有些定制 ROM 弹窗不同，直接等超时并提示用户手点）。
# B19：默认**不自动点**。按钮位置随分辨率/ROM 版本变化（平板 2272×3408 上 846,2002 实测点不中），
# 自动点击已不再可靠；需要时显式设 DV_INSTALL_TAP="x,y"。
DV_INSTALL_TAP="${DV_INSTALL_TAP:-${CONF_INSTALL_TAP:-none}}"
DV_INSTALL_TAP_X="${DV_INSTALL_TAP_X:-846}"
DV_INSTALL_TAP_Y="${DV_INSTALL_TAP_Y:-2002}"
if [ -n "$DV_INSTALL_TAP" ]; then
  case "$DV_INSTALL_TAP" in
    none|off|NONE|OFF) DV_INSTALL_TAP_X="" ; DV_INSTALL_TAP_Y="" ;;
    *,*) DV_INSTALL_TAP_X="${DV_INSTALL_TAP%%,*}"; DV_INSTALL_TAP_Y="${DV_INSTALL_TAP##*,}" ;;
  esac
fi

# 校验：只查「越界」，不猜语义（846,2002 在 1200×2608 上不越界但落点不对，属于用户要自己设的事）
_dv_install_tap_check() {
  [ -z "$DV_INSTALL_TAP_X" ] && return 0        # none 模式
  case "${DV_INSTALL_TAP_X}${DV_INSTALL_TAP_Y}" in
    *[!0-9]*) die "$EX_ARG" "DV_INSTALL_TAP 格式应为 x,y（收到：${DV_INSTALL_TAP:-$DV_INSTALL_TAP_X,$DV_INSTALL_TAP_Y}）" ;;
  esac
  local sz w h
  sz="$(adbq shell 'wm size' 2>/dev/null | sed -n 's/.*: \([0-9]*x[0-9]*\).*/\1/p' | tail -1)"
  [ -n "$sz" ] || return 0                       # 拿不到屏幕尺寸就不拦
  w="${sz%x*}"; h="${sz#*x}"
  if [ "$DV_INSTALL_TAP_X" -gt "$w" ] || [ "$DV_INSTALL_TAP_Y" -gt "$h" ]; then
    die "$EX_ARG" "DV_INSTALL_TAP=${DV_INSTALL_TAP_X},${DV_INSTALL_TAP_Y} 超出屏幕范围（wm size = ${w}x${h}）" \
        "按实际分辨率设置坐标，或设 DV_INSTALL_TAP=none 改为手动点"
  fi
  return 0
}

dv_help_install() { cat <<EOF
dv install [--apk PATH]
  安装 debug APK，自动点掉 HyperOS 安装确认弹窗（10 s 倒计时）。
  APK 查找顺序：--apk > \$DV_APK > dv.conf 的 CONF_APK > ./app-debug.apk > 常见构建输出
弹窗坐标：**默认不自动点**（DV_INSTALL_TAP 缺省 = none）——按钮位置随分辨率/ROM 版本变化，
  历史上 2272×3408 的 846,2002 在横屏平板上已点不中（会落到「拒绝」）。
  需要自动点就显式设 DV_INSTALL_TAP="x,y"（dv.conf 里是 CONF_INSTALL_TAP），例如手机 1200×2608
  实测可用 600,1800 一带；不确定就用默认的 none，弹窗出现后手点「继续安装」。
  越界（x>宽 或 y>高，按 wm size）会 exit 2 并报出实际屏幕尺寸。
退出码：0 成功 · 2 参数错误/找不到 APK · 3 无设备 · 6 安装被拒（USER_RESTRICTED 等）
EOF
}

_find_apk() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then [ -f "$explicit" ] && { printf '%s' "$explicit"; return 0; }; return 1; fi
  local c
  for c in "${DV_APK:-}" "${CONF_APK:-}" "./app-debug.apk" \
           "./env-build/android-src/app/build/outputs/apk/debug/app-debug.apk"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}


# B18：从 APK 里取包名（aapt2 → apkanalyzer → 安装前后 pm list 差集），绝不拿 DV_PKG 冒充
_apk_package() {
  local apk="$1" name=""
  if command -v aapt2 >/dev/null 2>&1; then
    name="$(aapt2 dump badging "$apk" 2>/dev/null | sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" | head -1)"
  elif command -v aapt >/dev/null 2>&1; then
    name="$(aapt dump badging "$apk" 2>/dev/null | sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" | head -1)"
  elif command -v apkanalyzer >/dev/null 2>&1; then
    name="$(apkanalyzer manifest application-id "$apk" 2>/dev/null | head -1)"
  fi
  printf '%s' "$name"
}

dv_cmd_install() {
  local json=$JSON_MODE apk=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --apk) apk="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_install; return "$EX_OK" ;;
      *) die "$EX_ARG" "install 不认识的参数：$1" ;;
    esac
  done

  dv_need_device
  local apk_path; apk_path="$(_find_apk "$apk")" || { err "找不到 APK"; hint "用 --apk 指定，或设 DV_APK"; return "$EX_ARG"; }

  local focus_before; focus_before="$(dv_focus_line)"
  # F-03：--json 时人类行改到 stderr（stdout 只留一行 JSON）
  _inst_info() { if [ "$json" = "1" ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
  _inst_info "${C_D}install: $(basename "$apk_path") ($(stat -c %s "$apk_path") bytes)${C_0}"
  case "$focus_before" in
    *"$PKG"*) [ "$json" = "1" ] && printf '✔ 安装前焦点：%s\n' "$focus_before" >&2 || ok "安装前焦点：$focus_before" ;;
    *) warn "安装前焦点：${focus_before:-?}" ;;
  esac

  _dv_install_tap_check

  local out t0 t1 rc pm_before=""
  t0=$(date +%s%N)
  pm_before="$(adbq shell 'pm list packages' 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)"
  # 后台跑 install
  timeout "${DV_INSTALL_TIMEOUT:-180}" "$ADB" -s "$SERIAL" install -r -t "$apk_path" > /tmp/dv-install.$$ 2>&1 &
  local ipid=$!
  sleep 1.2
  if [ -n "$DV_INSTALL_TAP_X" ]; then
    adbq shell "input tap $DV_INSTALL_TAP_X $DV_INSTALL_TAP_Y" >/dev/null 2>&1
  else
    warn "DV_INSTALL_TAP=none：不自动点弹窗，等它在 10 s 后超时（请手动点「继续安装」）"
  fi
  wait $ipid; rc=$?
  t1=$(date +%s%N)
  out="$(cat /tmp/dv-install.$$ 2>/dev/null)"; rm -f /tmp/dv-install.$$

  local ms=$(( (t1 - t0) / 1000000 ))
  local code="$EX_OK" status="ok"
  case "$out" in
    *Success*) status="ok"; code=$EX_OK ;;
    *USER_RESTRICTED*)
      status="user_restricted"; code=$EX_VERIFY
      err "安装被拒：USER_RESTRICTED（弹窗 10 s 内没点上，或设备策略限制）"
      hint "确认屏幕亮着且在前台；重试前先 adb shell input keyevent 4 关掉残留弹窗" ;;
    *"INSTALL_FAILED"*|*Failure*)
      status="failed"; code=$EX_VERIFY; err "安装失败：$(printf '%s' "$out" | tail -1)" ;;
    *) status="unknown"; code=$EX_VERIFY; warn "未识别的安装输出"; printf '%s\n' "$out" ;;
  esac

  sleep 1
  local focus_after; focus_after="$(dv_focus_line)"
  # B18：先看「这个 APK 的包名」是否在设备上，而不是拿 DV_PKG 冒充
  local apk_pkg pkg_source pm_after new_pkg
  apk_pkg="$(_apk_package "$apk_path")"
  pkg_source="apk"
  pm_after="$(adbq shell 'pm list packages' 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)"
  if [ -z "$apk_pkg" ] && [ -n "${pm_before:-}" ]; then
    new_pkg="$(comm -13 <(printf '%s\n' "$pm_before") <(printf '%s\n' "$pm_after") | head -1)"
    [ -n "$new_pkg" ] && { apk_pkg="$new_pkg"; pkg_source="pm-diff"; }
  fi
  [ -n "$apk_pkg" ] && pkg_source="${pkg_source:-apk}" || pkg_source="unknown"
  local installed=0
  if [ -n "$apk_pkg" ]; then
    printf '%s\n' "$pm_after" | grep -qxF "$apk_pkg" && installed=1
  else
    # 完全拿不到包名时，只能看安装输出本身（并在 JSON 里标注 unverified）
    case "$out" in *Success*) installed=1 ;; esac
    pkg_source="unverified"
  fi

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"status":%s,"apk":%s,"ms":%s,"installed":%s,"apk_package":%s,"pkg_source":%s,"focus_before":%s,"focus_after":%s,"raw":%s}\n' \
      "$([ "$code" = "0" ] && printf true || printf false)" "$(jstr "$status")" "$(jstr "$apk_path")" "$ms" \
      "$(jbool "$installed")" "$(jstr "$apk_pkg")" "$(jstr "$pkg_source")" "$(jstr "$focus_before")" "$(jstr "$focus_after")" "$(jstr "$out")"
    return "$code"
  fi

  _inst_info "  ${C_D}${ms} ms${C_0}"
  case "$focus_after" in
    *"$PKG"*) [ "$json" = "1" ] && printf '✔ 安装后焦点：%s\n' "$focus_after" >&2 || ok "安装后焦点已回到被测 App：$focus_after" ;;
    *) warn "安装后焦点不在被测 App：${focus_after:-?}（可能被安装器/桌面挡住）" ;;
  esac
  [ "$installed" = "1" ] && [ "$json" != "1" ] && ok "包已安装：${apk_pkg:-?}（来源 $pkg_source）"
  [ "$installed" != "1" ] && [ "$json" != "1" ] && warn "这个 APK 的包（${apk_pkg:-未知}）不在设备上——安装没成功"
  return "$code"
}
