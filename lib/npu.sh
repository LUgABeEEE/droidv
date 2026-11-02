#!/usr/bin/env bash
# lib/npu.sh —— NNAPI 设备枚举（只读）/ demo 运行（会装 App）
#
# 依据：很多设备 /dev 里没有可用的 NPU 计算节点，NNAPI 设备信息只能从 HAL 清单
# 与 dumpsys 里读；容器/虚拟化 guest 里通常也看不到 NPU。check 用来复核这个结论。
# run 复用 install 的弹窗配方
# shellcheck source=install.sh
. "$DV_BIN/lib/install.sh"

dv_help_npu() { cat <<EOF
dv npu check [--json]     只读枚举：NNAPI HAL / vendor 清单 / /dev 节点 / 相关属性
dv npu run [--apk PATH]   装并运行 NNAPI demo（默认找 \$DV_NPU_APK / \$CONF_NPU_APK）
退出码：0 成功 · 2 参数错误/找不到 APK · 3 无设备 · 6 运行/安装失败
注意：run 会安装 App（唯一有副作用的 npu 子动作）；check 完全只读。
EOF
}

dv_cmd_npu() {
  local action="${1:-check}"; shift || true
  local json=$JSON_MODE apk=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --apk) apk="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      -h|--help) dv_help_npu; return "$EX_OK" ;;
      *) die "$EX_ARG" "npu 不认识的参数：$1" ;;
    esac
  done

  case "$action" in
    check)
      dv_need_device
      # F-02：四路各取一次（bash 变量不能存 NUL，别再用 `read -d ''` 花样）
      local hal vendor devs prop
      hal="$(adbq shell 'dumpsys android.hardware.neuralnetworks 2>/dev/null | head -20; dumpsys neuralnetworks 2>/dev/null | head -20' | tr -d '\r')"
      vendor="$(adbq shell 'ls /vendor/etc/nnapi/ 2>/dev/null; for f in /vendor/etc/nnapi/*.xml; do echo "== $f"; head -30 "$f" 2>/dev/null; done' | tr -d '\r')"
      devs="$(adbq shell 'ls -l /dev 2>/dev/null | grep -iE "npu|nsp|dsp|vpu|nne"' | tr -d '\r')"
      prop="$(adbq shell 'getprop | grep -iE "nnapi|npu|nsp"' | tr -d '\r')"
      local hal_count
      hal_count="$(printf '%s' "$hal" | grep -ci 'device\|hal' || true)"
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"serial":%s,"hal_lines":%s,"dev_nodes":%s,"vendor_config":%s,"props":%s}\n' \
          "$(jstr "$SERIAL")" "$(jnum "${hal_count:-0}")" "$(jstr "$devs")" "$(jstr "$vendor")" "$(jstr "$prop")"
        return "$EX_OK"
      fi
      ok "NNAPI / NPU 只读枚举（$SERIAL）"
      say "── /dev 里的加速器节点 ──"
      if [ -n "$devs" ]; then printf '%s\n' "$devs" | sed 's/^/  /'; else say "  （无 npu/nsp/dsp/vpu/nne 节点）"; fi
      say "── 相关属性 ──"
      if [ -n "$prop" ]; then printf '%s\n' "$prop" | sed 's/^/  /'; else say "  （无 nnapi/npu 属性）"; fi
      say "── HAL / dumpsys ──"
      if [ -n "$hal" ]; then printf '%s\n' "$hal" | head -12 | sed 's/^/  /'; else say "  （dumpsys 无 neuralnetworks 服务）"; fi
      say "── vendor NNAPI 清单 ──"
      if [ -n "$vendor" ]; then printf '%s\n' "$vendor" | head -20 | sed 's/^/  /'; else say "  （/vendor/etc/nnapi 不存在）"; fi
      return "$EX_OK" ;;
    run)
      dv_need_device
      local p=""
      if [ -n "$apk" ] && [ -f "$apk" ]; then
        p="$apk"
      elif [ -n "${NPU_APK:-}" ] && [ -f "${NPU_APK}" ]; then
        p="$NPU_APK"
      else
        local c
        for c in "$DV_NPU_APK" "$DV_BIN/../npu-demo.apk" "$HOME/npu-demo.apk"; do
          [ -f "$c" ] && { p="$c"; break; }
        done
      fi
      [ -z "$p" ] && p="$(_find_apk "")"
      [ -n "$p" ] || { err "找不到 NNAPI demo APK"; hint "用 --apk 指定，或设 DV_NPU_APK / dv.conf 的 CONF_NPU_APK"; return "$EX_ARG"; }
      say "安装 demo：$p"
      dv_cmd_install --apk "$p" >/dev/null 2>&1 || { err "安装失败"; return "$EX_VERIFY"; }
      local demo_pkg="${DV_NPU_PKG:-com.example.npuprobe}"   # 换成你自己的 NNAPI demo 包名
      local act; act="$(adbq shell "cmd package resolve-activity --brief $demo_pkg" 2>/dev/null | tail -1)"
      [ -n "$act" ] || { err "解析不到 $demo_pkg 的入口 Activity"; return "$EX_VERIFY"; }
      adbq logcat -c >/dev/null 2>&1
      adbq shell "am start -W -n $act" >/dev/null 2>&1
      sleep 8
      local log; log="$(adbq logcat -d 2>/dev/null | grep -iE "nnapi|neuralnet|${demo_pkg##*.}" | tail -30)"
      if [ "$json" = "1" ]; then
        printf '{"ok":true,"apk":%s,"activity":%s,"log":%s}\n' "$(jstr "$p")" "$(jstr "$act")" "$(jstr "$log")"
      else
        ok "demo 已启动：$act"
        [ -n "$log" ] && printf '%s\n' "$log" | sed 's/^/  /' || warn "logcat 里没抓到 demo/nnapi 行"
      fi
      return "$EX_OK" ;;
    *) die "$EX_ARG" "npu 不认识的动作：$action（check|run）" ;;
  esac
}
