#!/usr/bin/env bash
# lib/build.sh —— 从任意 Gradle 安卓工程出 APK（可选装到设备）
#
# 实测踩过的坑：
#   · Gradle 分发包从 services.gradle.org 下载可能读超时 → 只**提示**可用镜像/--offline，不写死任何镜像
#   · distributionUrl=file: 指向含中文/空格的路径 → URI 解析失败，报错要点名
#   · ~/.android 不可写 → AGP 补不了 SDK/写不了缓存 → 用 ANDROID_USER_HOME 指到可写目录
#   · 首次构建会下 AGP/Kotlin 依赖，几分钟很正常 → 打印阶段与耗时，别让人以为卡死

# shellcheck source=install.sh
. "$DV_BIN/lib/install.sh"

DV_BUILD_TIMEOUT="${DV_BUILD_TIMEOUT:-1800}"

dv_help_build() { cat <<EOF
dv build [--project DIR] [--variant debug|release] [--install] [--json] [--offline] [--flavor NAME]
  --project DIR   工程目录（默认当前目录；会自动向上找 gradlew 所在目录）
  --variant V     debug（默认）| release
  --flavor NAME   多 flavor 工程：构建 assemble<Flavor><Variant>，并在产物里按名字过滤
  --install       构建完直接装到设备（复用 dv install，含澎湃安装弹窗处理）
  --offline       ./gradlew --offline
  --json          {ok,apk,bytes,durationMs,variant,project}
环境解析优先级：
  JDK：DV_JAVA → JAVA_HOME → 常见路径（\$HOME/.jdks、/usr/lib/jvm、<repo>/env/jdk）
  SDK：DV_SDK → ANDROID_SDK_ROOT / ANDROID_HOME → 常见路径（\$HOME/Android/Sdk、/opt/android-sdk、<repo>/env/sdk）
  ANDROID_USER_HOME：DV_ANDROID_USER_HOME（默认 ~/.cache/dv/android，保证可写）
退出码：0 成功 · 2 参数错误 · 3 无设备（仅 --install） · 6 找不到 APK / release 缺 signingConfig
        · 7 环境缺失（JDK/SDK/gradlew） · 8 **构建失败**
EOF
}

# ---------- 工程定位 ----------
_build_find_project() {
  local d="${1:-$PWD}"
  d="$(cd "$d" 2>/dev/null && pwd)" || return 1
  local i=0
  while [ "$i" -lt 8 ]; do
    [ -x "$d/gradlew" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"; i=$((i+1))
  done
  return 1
}

# ---------- 环境解析 ----------
_build_java_home() {
  local c
  if [ -n "${DV_JAVA:-}" ]; then printf '%s' "$DV_JAVA"; return; fi
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then printf '%s' "$JAVA_HOME"; return; fi
  for c in "$HOME/.jdks"/* /usr/lib/jvm/* "$DV_BIN/../env/jdk" "$HOME/Android/jdk"; do
    [ -x "$c/bin/java" ] && { printf '%s' "$c"; return; }
  done
  printf ''
}

_build_sdk() {
  local c
  if [ -n "${DV_SDK:-}" ]; then printf '%s' "$DV_SDK"; return; fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "$ANDROID_SDK_ROOT" ]; then printf '%s' "$ANDROID_SDK_ROOT"; return; fi
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ]; then printf '%s' "$ANDROID_HOME"; return; fi
  for c in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" \
           "$DV_BIN/../env/sdk" \
           /usr/lib/android-sdk /opt/android-sdk; do
    [ -d "$c/platforms" ] && { printf '%s' "$c"; return; }
  done
  printf ''
}

# ---------- 产物 ----------
_build_find_apk() {   # $1=project $2=variant $3=flavor
  local proj="$1" variant="$2" flavor="${3:-}"
  local dirs
  dirs="$(find "$proj" -type d -path '*/build/outputs/apk/*' -maxdepth 8 2>/dev/null)"
  local best="" best_t=0 f t
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.apk) ;; *) continue ;; esac
    case "$(basename "$f")" in *unsigned*) continue ;; esac
    if [ -n "$flavor" ]; then
      case "$f" in *"$flavor"*) ;; *) continue ;; esac
    fi
    case "$variant" in
      release) case "$f" in *debug*) continue ;; esac ;;
      *) case "$f" in *release*) continue ;; esac ;;
    esac
    t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$t" -gt "$best_t" ] && { best="$f"; best_t="$t"; }
  done <<< "$(find "$proj" -type f -name '*.apk' -path '*/build/outputs/apk/*' 2>/dev/null)"
  [ -n "$best" ] && printf '%s' "$best"
}

dv_cmd_build() {
  local json=$JSON_MODE proj="" variant="debug" install_after=0 offline=0 flavor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --project) proj="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --variant) variant="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --flavor) flavor="${2:-}"; [ "$#" -ge 2 ] || die "$EX_ARG" "$1 需要值"; shift 2 ;;
      --install) install_after=1; shift ;;
      --offline) offline=1; shift ;;
      -h|--help) dv_help_build; return "$EX_OK" ;;
      *) die "$EX_ARG" "build 不认识的参数：$1" ;;
    esac
  done
  case "$variant" in debug|release) ;; *) die "$EX_ARG" "--variant 只能是 debug 或 release（收到：$variant）" ;; esac

  # 1) 工程
  local root
  root="$(_build_find_project "$proj")" || {
    err "找不到 gradlew（从 ${proj:-$PWD} 向上找了 8 层）"
    hint "用 --project 指向工程目录（含 gradlew 的那层）"
    return "$EX_ENV"
  }

  # 2) JDK / SDK
  local java_home sdk user_home
  java_home="$(_build_java_home)"
  [ -n "$java_home" ] && [ -x "$java_home/bin/java" ] || {
    err "找不到 JDK（需要 JDK 17+）"
    hint "用 DV_JAVA=/path/to/jdk、或设置 JAVA_HOME；也可以先装一个 Temurin 17"
    return "$EX_ENV"
  }
  sdk="$(_build_sdk)"
  [ -n "$sdk" ] && [ -d "$sdk" ] || {
    err "找不到 Android SDK：${sdk:-<未找到>}"
    hint "用 DV_SDK=/path/to/sdk、或设置 ANDROID_SDK_ROOT / ANDROID_HOME"
    hint "常见位置：\$HOME/Android/Sdk、/opt/android-sdk；也可以用 sdkmanager 装 cmdline-tools + platform-tools"
    return "$EX_ENV"
  }
  # ANDROID_USER_HOME 必须真的**能写**（AGP 会在这里放 debug.keystore.lock）；只 mkdir 成功不够
  user_home="${DV_ANDROID_USER_HOME:-$HOME/.cache/dv/android}"
  if ! { mkdir -p "$user_home" && : > "$user_home/.dv-w"; } >/dev/null 2>&1; then
    user_home="${TMPDIR:-/tmp}/dv-android-home"
    { mkdir -p "$user_home" && : > "$user_home/.dv-w"; } >/dev/null 2>&1 || true
    warn "ANDROID_USER_HOME 不可写（${DV_ANDROID_USER_HOME:-$HOME/.cache/dv/android}），退化到 $user_home"
  fi
  rm -f "$user_home/.dv-w" 2>/dev/null || true

  # Gradle 用户目录也必须可写（沙箱/容器里 ~/.gradle 常常写不进去 → wrapper 报 "Could not create parent directory for lock file"）
  local gradle_home="${DV_GRADLE_USER_HOME:-${GRADLE_USER_HOME:-$HOME/.gradle}}"
  if ! { mkdir -p "$gradle_home" && : > "$gradle_home/.dv-w"; } >/dev/null 2>&1; then
    gradle_home="${TMPDIR:-/tmp}/dv-gradle-home"
    mkdir -p "$gradle_home" 2>/dev/null || true
    warn "GRADLE_USER_HOME 不可写（${DV_GRADLE_USER_HOME:-${GRADLE_USER_HOME:-$HOME/.gradle}}），退化到 $gradle_home"
    hint "依赖会重新下载，会比较慢；用 DV_GRADLE_USER_HOME 指向已有缓存的目录可复用"
  fi
  rm -f "$gradle_home/.dv-w" 2>/dev/null || true

  # 3) release 签名检查（早报错，别让 Gradle 抛一堆）
  if [ "$variant" = "release" ]; then
    local signed=0
    for f in "$root/app/build.gradle" "$root/app/build.gradle.kts" "$root/build.gradle" "$root/build.gradle.kts"; do
      [ -f "$f" ] && grep -q 'signingConfig' "$f" && { signed=1; break; }
    done
    if [ "$signed" != "1" ] && [ -z "${DV_ANDROID_KEYSTORE_FILE:-}" ]; then
      err "release 变体需要 signingConfig（工程里没找到，环境里也没有 DV_ANDROID_KEYSTORE_FILE）"
      hint "在 app/build.gradle(.kts) 里配 signingConfigs，或改用 --variant debug"
      return "$EX_VERIFY"
    fi
  fi

  # 4) 构建
  local task="assemble$(printf '%s' "${variant:0:1}" | tr '[:lower:]' '[:upper:]')${variant:1}"
  [ -n "$flavor" ] && task="assemble$(printf '%s' "${flavor:0:1}" | tr '[:lower:]' '[:upper:]')${flavor:1}$(printf '%s' "${variant:0:1}" | tr '[:lower:]' '[:upper:]')${variant:1}"
  local -a gargs=(--no-daemon --console=plain "$task")
  [ "$offline" = "1" ] && gargs=(--offline "${gargs[@]}")

  local log; log="$(mktemp -t dv-build-XXXXXX.log)"
  say "${C_D}build: $root → $task（JDK $(basename "$java_home") / SDK $sdk）${C_0}"
  local t0 t1 ms rc
  t0=$(date +%s%N)
  (
    cd "$root" || exit 1
    JAVA_HOME="$java_home" ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk" \
      ANDROID_USER_HOME="$user_home" GRADLE_USER_HOME="$gradle_home" \
      timeout "$DV_BUILD_TIMEOUT" ./gradlew "${gargs[@]}"
  ) > "$log" 2>&1
  rc=$?
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))

  if [ "$rc" != "0" ]; then
    err "构建失败（exit $rc，${ms} ms）—— 原始输出：$log"
    # 首错：Gradle 的 "What went wrong" 段，或最后 20 行
    if grep -q 'What went wrong' "$log"; then
      sed -n '/What went wrong/,/^\* Try:/p' "$log" | head -20 | sed 's/^/  /' >&2
    else
      tail -20 "$log" | sed 's/^/  /' >&2
    fi
    # 已知坑的定向提示
    grep -qi 'Read timed out\|Could not download\|Connection timed out' "$log" && \
      hint "像分发包/依赖下载超时：可重试、或用 --offline（依赖已缓存时）、或给 Gradle 配镜像（dv 不写死镜像）"
    grep -qi 'Illegal character in path\|URISyntaxException' "$log" && \
      hint "distributionUrl 指向的路径含中文/空格：把 gradle 分发包放到纯 ASCII 路径（如 /tmp）"
    grep -qi 'Permission denied.*\.android\|analytics.settings' "$log" && \
      hint "~/.android 不可写：已默认用 ANDROID_USER_HOME=$user_home，可再用 DV_ANDROID_USER_HOME 指定"
    if [ "$json" = "1" ]; then
      printf '{"ok":false,"phase":"build","rc":%s,"durationMs":%s,"log":%s,"project":%s,"variant":%s}\n' \
        "$rc" "$ms" "$(jstr "$log")" "$(jstr "$root")" "$(jstr "$variant")"
    fi
    return 8
  fi

  # 5) 产物
  local apk; apk="$(_build_find_apk "$root" "$variant" "$flavor")"
  if [ -z "$apk" ]; then
    local unsigned
    unsigned="$(find "$root" -type f -name '*unsigned*.apk' -path '*/build/outputs/apk/*' -newermt '-10 minutes' 2>/dev/null | head -3)"
    if [ -n "$unsigned" ]; then
      err "只找到**未签名**产物（装不上）：$(printf '%s' "$unsigned" | head -1)"
      hint "release 需要 signingConfig（或 DV_ANDROID_KEYSTORE_FILE 等环境变量），否则改用 --variant debug"
      [ "$json" = "1" ] && printf '{"ok":false,"phase":"unsigned","unsigned":%s,"durationMs":%s,"log":%s}\n' \
        "$(jstr "$unsigned")" "$ms" "$(jstr "$log")"
      return "$EX_VERIFY"
    fi
    err "构建成功但没找到 APK（找 */build/outputs/apk/*/*.apk，variant=$variant${flavor:+, flavor=$flavor}）"
    hint "多 flavor 工程请用 --flavor；也可以看 $log 里的输出路径"
    [ "$json" = "1" ] && printf '{"ok":false,"phase":"find_apk","durationMs":%s,"log":%s}\n' "$ms" "$(jstr "$log")"
    return "$EX_VERIFY"
  fi
  local bytes; bytes=$(stat -c %s "$apk")
  ok "构建成功 ${ms} ms → $apk（${bytes} B）"
  [ "$VERBOSE" = "1" ] && hint "日志：$log"

  # 6) 可选安装
  if [ "$install_after" = "1" ]; then
    local irc=0
    dv_cmd_install --apk "$apk" >/dev/null 2>&1 || irc=$?
    [ "$irc" = "0" ] && ok "已安装到设备" || { err "安装失败（exit $irc）"; [ "$json" = "1" ] && printf '{"ok":false,"phase":"install","apk":%s,"rc":%s}\n' "$(jstr "$apk")" "$irc"; return "$irc"; }
  fi

  if [ "$json" = "1" ]; then
    printf '{"ok":true,"apk":%s,"bytes":%s,"durationMs":%s,"variant":%s,"project":%s,"task":%s}\n' \
      "$(jstr "$apk")" "$bytes" "$ms" "$(jstr "$variant")" "$(jstr "$root")" "$(jstr "$task")"
  fi
  return "$EX_OK"
}
