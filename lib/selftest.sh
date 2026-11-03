#!/usr/bin/env bash
# lib/selftest.sh —— 无需设备：用 fake-adb + 假 devtools 端点验证各路径与退出码
dv_help_selftest() { cat <<EOF
dv selftest [--verbose]
  在无设备环境下跑：doctor / check / cdp version / cdp 认领失败 / uitree 重试 / shot / 参数错误 / 缺 adb
  断言：退出码、JSON 字段、forward 的 ADD/REMOVE 计数（证明任何路径都回收 forward）
退出码：0 全过 · 1 有失败
EOF
}


# selftest 不依赖 jq：用 python3 做 JSON 断言（python3 本来就是必需依赖）
# 用法：printf '%s' "$json" | jsonq <op> <path> <value> [<op> <path> <value> ...]
#   op: truth|eq|gt|minlen|contains|isbool（不用值的位置写 - 占位；多个断言之间是 AND）
#   path 用点号表示嵌套：config.serial.source
jsonq() {
  python3 -c '
import json, sys
args = sys.argv[1:]
if not args or len(args) % 3:
    sys.exit(2)
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for i in range(0, len(args), 3):
    op, path, val = args[i], args[i + 1], args[i + 2]
    cur = d
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            sys.exit(1)
    if op == "truth":
        ok = cur not in (None, False, "", 0, [], {})
    elif op == "eq":
        if str(val).lower() in ("true", "false"):
            ok = cur is (val.lower() == "true")
        else:
            ok = (cur == val) or (str(cur) == str(val))
            if not ok:
                try:
                    ok = float(cur) == float(val)
                except Exception:
                    ok = False
    elif op == "gt":
        ok = float(cur) > float(val)
    elif op == "minlen":
        ok = len(str(cur)) > int(val)
    elif op == "contains":
        ok = val in str(cur)
    elif op == "isbool":
        ok = isinstance(cur, bool)
    else:
        sys.exit(2)
    if not ok:
        sys.exit(1)
sys.exit(0)
' "$@"
}

dv_cmd_selftest() {
  local verbose=$VERBOSE
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) dv_help_selftest; return "$EX_OK" ;;
      --verbose) verbose=1; shift ;;
      *) die "$EX_ARG" "selftest 不认识的参数：$1" ;;
    esac
  done

  HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
  if [ "$HAVE_NODE" != "1" ]; then
    # 干净环境（PATH 被裁剪）时也尽量找到 node：CDP 用例不该因宿主 PATH 而漂移
    for _n in /usr/local/bin/node /opt/homebrew/bin/node "$HOME"/.nvm/versions/node/*/bin/node /usr/bin/node; do
      if [ -x "$_n" ]; then PATH="$(dirname "$_n"):$PATH"; export PATH; HAVE_NODE=1; break; fi
    done
    unset _n
  fi
  ST="$(mktemp -d)"
  trap 'rm -rf "${ST:-}"' EXIT
  local FAKE="$DV_BIN/selftest/fake-adb"
  [ -x "$FAKE" ] || die "$EX_ENV" "缺少 $FAKE"
  need python3                                  # node 只在 CDP 用例里需要，缺了记 SKIP
  export DV_FAKE_STATE="$ST/state"; mkdir -p "$DV_FAKE_STATE" "$ST/locks"
  export DV_FAKE_PKG="com.example.app"
  : > "$DV_FAKE_STATE/forwards"

  local pass=0 fail=0
  check() {   # check <名称> <期望退出码> <实际退出码> [额外断言命令]
    local name="$1" want="$2" got="$3" extra="${4:-}"
    if [ "$got" = "$want" ] && { [ -z "$extra" ] || eval "$extra"; }; then
      pass=$((pass+1)); printf '%sPASS%s %-42s (exit %s)\n' "$C_G" "$C_0" "$name" "$got"
    else
      fail=$((fail+1)); printf '%sFAIL%s %-42s 期望 %s 实际 %s\n' "$C_R" "$C_0" "$name" "$want" "$got"
    fi
  }
  run_dv() {  # run_dv <args...> —— 用 fake adb，禁止自动探测干扰
    DV_ADB="$FAKE" DV_LOCK_FILE="$ST/locks/device.lock" DV_SERIAL="${DV_SERIAL-FAKE123}" DV_OUT="$ST/out" DV_FORWARD_PORT=19333 DV_PKG="${DV_PKG-com.example.app}" \
      DV_IME_SNAPSHOT="$ST/ime-snapshot.json" DV_CONF=/nonexistent \
      bash "$DV_BIN/dv" "$@" 2>>"$ST/stderr.log"
  }

  say "${C_B}dv selftest${C_0}  (fake-adb, 无设备)"

  local out rc

  out="$(run_dv doctor --json)"; rc=$?
  check "doctor --json" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"online\":true"'

  out="$(run_dv check --json)"; rc=$?
  check "check --json" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"sdk\":\"37\""'

  if [ "$HAVE_NODE" = "1" ]; then
  out="$(run_dv cdp version --json)"; rc=$?
  check "cdp version --json（认领成功）" "$EX_OK" "$rc" \
    'printf "%s" "$out" | grep -q "\"Android-Package\":\"com.example.app.debug\"\|com.example.app"'
  local adds1 removes1
  adds1="$(grep -c '^ADD ' "$DV_FAKE_STATE/calls.log" 2>/dev/null || echo 0)"
  removes1="$(grep -c '^REMOVE ' "$DV_FAKE_STATE/calls.log" 2>/dev/null || echo 0)"
  check "cdp 退出后 forward 已回收（ADD=$adds1 REMOVE=$removes1）" "$EX_OK" "0" \
    '[ "$adds1" = "1" ] && [ "$removes1" = "1" ]'

  # 认领失败：端点报的是别的包
  rm -f "$DV_FAKE_STATE/dump_count"
  out="$(DV_FAKE_PKG=com.other.app run_dv cdp version --json)"; rc=$?
  check "cdp version（package 不匹配 → 6）" "$EX_VERIFY" "$rc"
  local removes2; removes2="$(grep -c '^REMOVE ' "$DV_FAKE_STATE/calls.log" 2>/dev/null || echo 0)"
  check "认领失败也回收 forward（REMOVE=$removes2）" "$EX_OK" "0" '[ "$removes2" -ge 2 ]'

  # uitree：前 2 次 idle-state 失败，第 3 次成功
  rm -f "$DV_FAKE_STATE/dump_count" "$DV_FAKE_STATE/ui.xml"
  cat > "$DV_FAKE_STATE/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" bounds="[0,0][2272,3408]"><node index="0" text="[dvmeta:4096] size=4096" resource-id="" class="android.widget.TextView" package="com.example.app" content-desc="" bounds="[0,0][100,100]"/></node></hierarchy>
XML
  out="$(DV_FAKE_DUMP_FAIL=2 run_dv uitree --json --marker '[dvmeta:')"; rc=$?
  check "uitree 重试后成功（前 2 次失败）" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"ok\":true"'

  # uitree：永远失败 → 4
  rm -f "$DV_FAKE_STATE/dump_count"
  out="$(DV_FAKE_UI_ALWAYS_FAIL=1 DV_FAKE_DUMP_FAIL=0 run_dv uitree --json)"; rc=$?
  check "uitree 始终失败 → 4" "$EX_DATA" "$rc"

  # peek：文本优先（fake UI 树 → 摘要）
  rm -f "$DV_FAKE_STATE/dump_count" "$DV_FAKE_STATE/ui.xml"
  cat > "$DV_FAKE_STATE/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" bounds="[0,0][2272,3408]"><node index="0" text="取消连接" resource-id="" class="android.widget.Button" package="com.example.app" content-desc="" clickable="true" bounds="[100,200][300,260]"/><node index="1" text="无线调试" resource-id="" class="android.widget.TextView" package="com.example.app" content-desc="" clickable="false" bounds="[0,0][400,100]"/></node></hierarchy>
XML
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv --json peek --no-cdp)"; rc=$?
  check "peek 文本摘要（--no-cdp）" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"backend\":\"uitree\"" && printf "%s" "$out" | grep -q "取消连接"'
  out="$(run_dv peek --limit abc)"; rc=$?
  check "peek --limit 非数字 → 2" "$EX_ARG" "$rc"
  out="$(DV_FAKE_UI_ALWAYS_FAIL=1 DV_FAKE_DUMP_FAIL=0 run_dv peek --no-cdp --json)"; rc=$?
  check "peek 取不到 UI 树 → 4" "$EX_DATA" "$rc"

  # shot
  out="$(run_dv shot --json -n 2 -o "$ST/out/shots")"; rc=$?
  check "shot --json -n 2" "$EX_OK" "$rc" \
    '[ "$(ls "$ST/out/shots"/*.png 2>/dev/null | wc -l)" = "2" ]'

  fi
  # cdp eval（走 node 原生 WebSocket + 假端点）
  if [ "$HAVE_NODE" = "1" ]; then
  out="$(run_dv cdp eval '1+1')"; rc=$?
  check "cdp eval（WebSocket 求值）" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "fake-ok"'

  fi

  # 配置优先级：--pkg 覆盖环境变量
  out="$(DV_PKG=env.pkg.local run_dv --pkg com.example.app cdp version --json)"; rc=$?
  check "参数 > 环境变量（--pkg）" "$EX_OK" "$rc"

  # install（fake adb 返 Success）
  echo dummy > "$ST/fake.apk"
  out="$(run_dv install --apk "$ST/fake.apk" --json)"; rc=$?
  check "install --json（fake Success）" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"installed\":true"'

  # cycle（fake 下 CDP 也可用）
  rm -f "$DV_FAKE_STATE/dump_count"
  out="$(run_dv cycle --json $([ "$HAVE_NODE" = "1" ] || printf -- '--no-cdp'))"; rc=$?
  check "cycle --json（全链路）" "$EX_OK" "$rc" \
    '[ -f "$(printf "%s" "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"dir\"])")/uitree.json" ]'

  # npu check（只读）
  out="$(run_dv npu check --json)"; rc=$?
  check "npu check --json" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"ok\":true"'

  # ── logcat（JSON 解析 + pid 过滤）──
  out="$(run_dv logcat --pkg com.example.app -n 5 --json)"; rc=$?
  check "logcat --pkg --json（按 pid 过滤）" "$EX_OK" "$rc" \
    'printf "%s" "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d[\"lines\"]>=1;assert all(x[\"pid\"]==12345 for x in d[\"items\"])"'
  out="$(run_dv logcat --tag chromium -n 5 --json)"; rc=$?
  check "logcat --tag --json" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q chromium'
  out="$(run_dv logcat --crash --json)"; rc=$?
  check "logcat --crash --json" "$EX_OK" "$rc"

  # ── adb 透传：白名单 / 黑名单 / 超时 ──
  out="$(run_dv adb -- shell echo ok)"; rc=$?
  check "adb 透传（安全命令）" "$EX_OK" "$rc"
  out="$(run_dv adb -- reboot)"; rc=$?
  check "adb 拒绝危险命令 reboot → 2" "$EX_ARG" "$rc"
  out="$(run_dv adb -- kill-server)"; rc=$?
  check "adb 拒绝 kill-server → 2" "$EX_ARG" "$rc"
  out="$(run_dv adb --allow-danger -- reboot)"; rc=$?
  check "adb --allow-danger 放行 → 0" "$EX_OK" "$rc"

  # ── perf / crash ──
  out="$(run_dv perf --gfxinfo com.example.app --json)"; rc=$?
  check "perf --gfxinfo --json" "$EX_OK" "$rc" \
    'printf "%s" "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d[\"total_frames\"]==1234 and d[\"p90_ms\"]==9"'
  out="$(run_dv perf --record 2 -o "$ST/out/rec" --json)"; rc=$?
  check "perf --record（限时录屏）" "$EX_OK" "$rc"
  out="$(run_dv crash --json)"; rc=$?
  check "crash --json（tombstone 不可读如实说明）" "$EX_OK" "$rc" \
    'printf "%s" "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d[\"tombstones_readable\"] is False"'

  # ── 参数化：没配包名时清晰报错（不再静默回落到某个具体项目）──
  out="$(DV_PKG= run_dv check --json)"; rc=$?
  check "t35：check 未配包名也能跑（不再 exit 2）" "$EX_OK" "$rc"

  # ── dv build（假工程 + 假 gradlew）──
  local PROJ="$ST/proj"
  mkdir -p "$PROJ/app/build.gradle.kts" 2>/dev/null || true
  rmdir "$PROJ/app/build.gradle.kts" 2>/dev/null || true
  mkdir -p "$PROJ/app" "$ST/sdk/platforms" "$ST/jdk/bin"
  printf '#!/bin/sh\necho fake-java\n' > "$ST/jdk/bin/java"; chmod +x "$ST/jdk/bin/java"
  cat > "$PROJ/app/build.gradle.kts" <<'GRADLE'
android { signingConfigs { create("release") {} } }
GRADLE
  cat > "$PROJ/gradlew" <<'GRADLEW'
#!/usr/bin/env bash
set -u
mode="${DV_FAKE_GRADLE_MODE:-ok}"
echo "fake gradlew $*"
if [ "$mode" = "fail" ]; then
  echo "FAILURE: Build failed with an exception."
  echo "* What went wrong:"
  echo "Could not resolve com.android.tools.build:gradle:8.10.1 (network timeout)"
  exit 1
fi
if [ "$mode" = "ok" ]; then
  mkdir -p app/build/outputs/apk/debug
  head -c 2048 /dev/zero | tr '\0' 'A' > app/build/outputs/apk/debug/app-debug.apk
fi
exit 0
GRADLEW
  chmod +x "$PROJ/gradlew"

  out="$(DV_JAVA="$ST/jdk" DV_SDK="$ST/sdk" run_dv build --project "$PROJ" --json)"; rc=$?
  check "build --json（假工程出 APK）" "$EX_OK" "$rc" \
    'printf "%s" "$out" | grep -q "\"bytes\":2048" && printf "%s" "$out" | grep -q "\"ok\":true"'

  rm -rf "$PROJ/app/build"
  out="$(DV_JAVA="$ST/jdk" DV_SDK="$ST/sdk" DV_FAKE_GRADLE_MODE=noapk run_dv build --project "$PROJ" --json)"; rc=$?
  check "构建成功但无 APK → 6" "$EX_VERIFY" "$rc"

  out="$(DV_JAVA="$ST/jdk" DV_SDK="$ST/sdk" DV_FAKE_GRADLE_MODE=fail run_dv build --project "$PROJ")"; rc=$?
  check "构建失败 → 8" "$EX_BUILD" "$rc" 'grep -q "What went wrong" "$ST/stderr.log"'

  out="$(DV_JAVA="$ST/jdk" DV_SDK=/nonexistent/sdk run_dv build --project "$PROJ")"; rc=$?
  check "缺 SDK → 7" "$EX_ENV" "$rc" 'grep -q "找不到 Android SDK" "$ST/stderr.log"'

  out="$(run_dv build --project "$PROJ" --variant nope)"; rc=$?
  check "未知 variant → 2" "$EX_ARG" "$rc"

  out="$(run_dv build --project "$ST/no-such-dir")"; rc=$?
  check "找不到 gradlew → 7" "$EX_ENV" "$rc"

  # ── REVIEW-STATIC F-01：选项缺值必须 exit 2 且不挂（不是 124）──
  for c in "install --apk" "uitree --marker" "uitree --find" "shot -o" "cdp version --port" "npu run --apk"; do
    # shellcheck disable=SC2086
    timeout 5 env DV_ADB="$FAKE" DV_SERIAL=FAKE123 DV_FAKE_STATE="$DV_FAKE_STATE" \
      DV_OUT="$ST/out" DV_CONF=/nonexistent bash "$DV_BIN/dv" $c >/dev/null 2>&1; rc=$?
    check "F-01 缺值不挂：dv $c" "$EX_ARG" "$rc"
  done

  # ── F-02：npu check 必须真读到 /dev 节点与 vendor 清单（不再 IF 空串）──
  out="$(run_dv npu check --json)"; rc=$?
  check "F-02 npu check 读到设备节点" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq contains dev_nodes /dev/npu'

  # ── F-03：install --json 必须是纯 JSON（可 jq）──
  out="$(run_dv install --apk "$ST/fake.apk" --json 2>/dev/null)"; rc=$?
  check "F-03 install --json 可解析" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq truth ok -'

  # ── F-06：packages 子命令（不再指向不存在的命令）──
  out="$(run_dv packages --json)"; rc=$?
  check "F-06 packages --json 有内容" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq gt count 0'
  out="$(run_dv packages --filter browser --json)"; rc=$?
  check "F-06 packages --filter" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq count 1'

  # ── F-07：多设备未指定 → 2（不是 3）──
  out="$(DV_SERIAL= DV_FAKE_TWO_DEVICES=1 run_dv doctor --json)"; rc=$?
  check "F-07 多设备 → 2" "$EX_ARG" "$rc"
  out="$(run_dv devices --json)"; rc=$?
  check "devices --json（单台）" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq count 1'

  # ── F-09：ime snapshot --json 只输出一行 ──
  out="$(run_dv ime snapshot --json 2>/dev/null)"; rc=$?
  check "F-09 ime snapshot --json 单行" "$EX_OK" "$rc" '[ "$(printf "%s\n" "$out" | grep -c .)" = "1" ]'

  # ── F-15：restore 要清掉快照里没有的多余 IME ──
  run_dv ime snapshot >/dev/null 2>&1
  "$FAKE" -s FAKE123 shell 'ime enable com.extra.ime/.Svc' >/dev/null 2>&1
  out="$(run_dv ime restore --json)"; rc=$?
  check "F-15 restore 清掉多余 IME" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq truth ok -'

  # ── doctor --print-config：值与来源 ──
  out="$(run_dv doctor --print-config --json)"; rc=$?
  check "print-config 有来源标注" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq eq config.serial.source env eq config.derived.boot_s 8'
  out="$(DV_FAST=1 DV_TIMEOUT=30 run_dv doctor --print-config --json)"; rc=$?
  check "DV_FAST 不改真机派生值" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq eq config.derived.boot_s 8 eq config.derived.retry_s 2'

  # ── wait-until：命中 / 超时（超时要给 last_state）──
  cat > "$DV_FAKE_STATE/ui.xml" <<'XML2'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="设置" class="android.widget.TextView" package="com.example.app" content-desc="打开设置" bounds="[100,200][300,400]"/></hierarchy>
XML2
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv wait-until --text "设置" --timeout 5 --json)"; rc=$?
  check "wait-until 命中（text）" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq truth ok - truth last_state.found -'
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv wait-until --text "绝不存在" --timeout 2 --interval 1 --json)"; rc=$?
  check "wait-until 超时 → 4 且带 last_state" "$EX_DATA" "$rc" \
    'printf "%s" "$out" | jsonq eq code 4 eq last_state.found false minlen hint 10'
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv wait-until --focus com.example.app --timeout 3 --json)"; rc=$?
  check "wait-until 命中（focus）" "$EX_OK" "$rc"

  # ── input：坐标从树算 / 非 ASCII 拒绝 ──
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv input tap --text "设置" --json)"; rc=$?
  check "input tap --text 从树算中心点" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq eq x 200 eq y 300'
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv input tap --desc "打开设置" --json)"; rc=$?
  check "input tap --desc" "$EX_OK" "$rc"
  out="$(run_dv input text 'abc123' --json)"; rc=$?
  check "input text（ASCII）" "$EX_OK" "$rc"
  out="$(run_dv input text '中文' 2>/dev/null)"; rc=$?
  check "input text（非 ASCII → 2）" "$EX_ARG" "$rc"

  # ── lock：占用 → 3；释放后可用；TTL 过期 ──
  run_dv lock acquire alice 60 >/dev/null 2>&1; rc=$?
  check "lock acquire" "$EX_OK" "$rc"
  run_dv lock acquire bob 60 >/dev/null 2>&1; rc=$?
  check "lock 被别人占用 → 3" "$EX_NODEV" "$rc"
  run_dv lock release bob >/dev/null 2>&1; rc=$?
  check "lock 非持有者 release → 3" "$EX_NODEV" "$rc"
  run_dv lock release alice >/dev/null 2>&1; rc=$?
  check "lock release" "$EX_OK" "$rc"
  run_dv lock acquire bob 1 >/dev/null 2>&1; sleep 2
  out="$(run_dv lock status --json)"; rc=$?
  check "lock TTL 过期后空闲" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq held false'

  # ── --retry：只对 4/6 生效（3 不重试）──
  out="$(DV_FAKE_UI_ALWAYS_FAIL=1 DV_FAKE_DUMP_FAIL=0 run_dv --retry 1 uitree --timeout 2 --json)"; rc=$?
  check "--retry 对 4 生效后仍 4" "$EX_DATA" "$rc"

  # ── t26：input swipe / key 名称 / DPR 换算 / 候选列表 ──
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv input swipe --from 500,1800 --to 500,600 --ms 300 --json)"; rc=$?
  check "input swipe --from/--to/--ms" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq action swipe'
  out="$(run_dv input key BACK --json)"; rc=$?
  check "input key BACK → 4" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq key 4'
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv input tap --text "设置" --json)"; rc=$?
  check "input tap 打印 px+css+dpr+焦点" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq eq dpr 2.5 eq css_x 80 isbool focus_is_target -'
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv input tap --text "绝不存在的按钮" 2>&1)"; rc=$?
  check "input tap 未命中 → 4 且列出候选" "$EX_DATA" "$rc" 'printf "%s" "$out" | grep -q "树里前"'

  # ── t26：lock 路径带 serial + --ttl + 占用者信息 ──
  out="$(run_dv lock acquire t26a --ttl 120 --json)"; rc=$?
  check "lock acquire --ttl" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq ttl 120'
  out="$(run_dv lock acquire t26b --ttl 60 --json)"; rc=$?
  check "lock 抢占 → 3 且报占用者" "$EX_NODEV" "$rc" 'printf "%s" "$out" | jsonq eq held_by t26a'
  out="$(run_dv lock status --json)"; rc=$?
  check "lock 文件名带 serial" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq contains lock lock-FAKE123'
  run_dv lock release t26a >/dev/null 2>&1

  # ── t26：--retry 区分 flaky / failed ──
  rm -f "$DV_FAKE_STATE/screencap_once"
  out="$(DV_FAKE_SCREENCAP_FAIL_ONCE=1 run_dv --retry 1 shot --json -o "$ST/out/flaky")"; rc=$?
  check "--retry 重试后成功（flaky，attempts>1）" "$EX_OK" "$rc" \
    'printf "%s" "$out" | grep -q flaky'
  out="$(DV_FAKE_UI_ALWAYS_FAIL=1 run_dv --retry 1 uitree --timeout 2 --json)"; rc=$?
  check "--retry 仍失败 → failed/4" "$EX_DATA" "$rc" 'grep -q failed "$ST/stderr.log"'

  # ── t34：install 弹窗坐标可配 / lock 序列号含冒号 / input 非 ASCII 前置 ──
  out="$(DV_INSTALL_TAP=2000,3000 run_dv install --apk "$ST/fake.apk" 2>&1)"; rc=$?
  check "install 坐标越界 → 2" "$EX_ARG" "$rc" 'grep -q "超出屏幕范围" "$ST/stderr.log"'
  out="$(DV_INSTALL_TAP=600,1800 run_dv install --apk "$ST/fake.apk" --json 2>/dev/null)"; rc=$?
  check "install 坐标在屏内 → 0" "$EX_OK" "$rc"
  out="$(DV_INSTALL_TAP=none run_dv install --apk "$ST/fake.apk" --json 2>/dev/null)"; rc=$?
  check "install DV_INSTALL_TAP=none → 0" "$EX_OK" "$rc"

  run_dv lock acquire wtest >/dev/null 2>&1 || true
  out="$(DV_SERIAL="192.0.2.10:40211" run_dv lock status --json 2>/dev/null)"; rc=$?
  check "lock 无线序列号（含冒号）能加锁" "$EX_OK" "$rc"
  out="$(DV_SERIAL="192.0.2.10:40211" run_dv lock acquire wire --ttl 60 --json 2>/dev/null)"; rc=$?
  check "lock 冒号序列号 → 文件名用 _" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq contains lock 192.0.2.10_40211'
  run_dv lock release wire >/dev/null 2>&1 || true

  # input text 非 ASCII：即使没有 adb 也应先 exit 2（载荷问题先于环境问题）
  out="$(env -u DV_ADB PATH=/usr/bin:/bin "$DV_BIN/dv" input text '中文' 2>&1)"; rc=$?
  check "input text 非 ASCII 先于 adb 检查 → 2" "$EX_ARG" "$rc" 'printf "%s" "$out" | grep -q "只接受纯 ASCII"'

  # ── t35：B1 doctor 惰性 adb（PATH 里有 adb、但没设 DV_ADB）──
  mkdir -p "$ST/bin"
  ln -sf "$FAKE" "$ST/bin/adb"
  out="$(env -u DV_ADB PATH="$ST/bin:/usr/bin:/bin" DV_FAKE_STATE="$DV_FAKE_STATE" \
        DV_SERIAL=FAKE123 DV_PKG=com.example.app DV_OUT="$ST/out" \
        bash "$DV_BIN/dv" doctor --json 2>/dev/null)"; rc=$?
  check "B1 未设 DV_ADB 时 doctor 可用" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq truth online -'

  # ── t35：B4 uitree 默认不重启 App ──
  : > "$DV_FAKE_STATE/calls.log"
  cat > "$DV_FAKE_STATE/ui.xml" <<'XML3'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="x" package="com.example.app" bounds="[0,0][10,10]"/></hierarchy>
XML3
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv uitree --marker NOT-THERE --timeout 2 --json 2>/dev/null)"; rc=$?
  check "B4 marker 不匹配 → 4" "$EX_DATA" "$rc"
  check "B4 默认不 force-stop App" "$EX_OK" "0" '! grep -q "force-stop" "$DV_FAKE_STATE/calls.log"'

  # ── t35：B4 release 包重启需二次确认 ──
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv uitree --marker NOT-THERE --restart-app --timeout 2 --json 2>/dev/null)"; rc=$?
  check "B4 release + --restart-app → 6" "$EX_VERIFY" "$rc" 'printf "%s" "$out" | jsonq eq reason release_restart_refused'

  # ── t35：B2 check 不再强制包名 ──
  out="$(DV_PKG= run_dv check --json 2>/dev/null)"; rc=$?
  check "B2 check 无包名也能跑" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq truth online -'

  # ── t35：D 屏幕字段 ──
  out="$(run_dv doctor --json 2>/dev/null)"; rc=$?
  check "D doctor 有屏幕字段" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq eq screen.dpr 2.5 eq screen.wm_size 1200x2608'
  out="$(run_dv check --json 2>/dev/null)"; rc=$?
  check "D check 有 css_viewport" "$EX_OK" "$rc" 'printf "%s" "$out" | jsonq eq screen.css_viewport 480x1043'

  # ── t35：B3 ime 快照按设备隔离 ──
  rm -f "$ST"/ime-snapshot-*.json
  out="$(run_dv ime snapshot --json 2>/dev/null)"; rc=$?
  check "B3 快照文件名带序列号" "$EX_OK" "$rc" '[ -f "$ST/ime-snapshot-FAKE123.json" ]'
  # 伪造一份「别的设备」的快照，restore 必须拒绝
  python3 - "$ST/ime-snapshot-FAKE123.json" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["serial"] = "other-device"
json.dump(d, open(sys.argv[1], "w"))
PYX
  out="$(run_dv ime restore --json 2>/dev/null)"; rc=$?
  check "B3 跨设备 restore → 2" "$EX_ARG" "$rc" 'printf "%s" "$out" | jsonq eq reason serial_mismatch'

  # ── t37：B19 默认不自动点 / B18 安装判定按 APK 包名 ──
  out="$(run_dv install --apk "$ST/fake.apk" --json 2>/dev/null)"; rc=$?
  check "B19 默认不自动点（DV_INSTALL_TAP=none）" "$EX_OK" "$rc" 'grep -q "DV_INSTALL_TAP=none" "$ST/stderr.log"'
  check "B18 install --json 带 apk_package/pkg_source" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq truth pkg_source -'

  # ── t37：B18 安装失败时 installed 必须为 false（假阳性回归）──
  out="$(DV_FAKE_INSTALL=restricted run_dv install --apk "$ST/fake.apk" --json 2>/dev/null)"; rc=$?
  check "B18 安装被拒时 installed=false" "$EX_VERIFY" "$rc" \
    'printf "%s" "$out" | jsonq eq installed false eq status user_restricted'

  # ── t37：B15 perf 无帧 → 6 ──
  out="$(DV_FAKE_GFX_EMPTY=1 run_dv perf --gfxinfo com.example.app --json 2>/dev/null)"; rc=$?
  check "B15 perf 无帧数据 → 6" "$EX_VERIFY" "$rc" 'printf "%s" "$out" | jsonq eq reason no_frames'

  # ── t37：B16 logcat 认 DV_PKG ──
  out="$(run_dv logcat -n 5 --json 2>/dev/null)"; rc=$?
  check "B16 logcat 未给 --pkg 时用 DV_PKG" "$EX_OK" "$rc" \
    'printf "%s" "$out" | jsonq truth pkg -'

  # ── t37：B17 marker 缺失单独 reason ──
  cat > "$DV_FAKE_STATE/ui.xml" <<XML4
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="x" package="${DV_FAKE_PKG}" bounds="[0,0][10,10]"/></hierarchy>
XML4
  out="$(DV_FAKE_DUMP_FAIL=0 run_dv uitree --marker NOPE-THIS --timeout 2 --json 2>/dev/null)"; rc=$?
  check "B17 marker 缺失 → reason=marker_missing" "$EX_DATA" "$rc" \
    'printf "%s" "$out" | jsonq eq reason marker_missing eq nodes 1'

  # ── t37：B20 没有输入框时不虚报「已输入」──
  out="$(DV_FAKE_NO_INPUT_METHOD=1 run_dv input text 'abc' --json 2>/dev/null)"; rc=$?
  check "B20 无输入框 → 6" "$EX_VERIFY" "$rc" 'printf "%s" "$out" | jsonq eq reason no_input_box'

  # ── IME 快照 / 恢复 ──  # ── IME 快照 / 恢复 ──  # ── IME 快照 / 恢复 ──

  out="$(run_dv ime snapshot --json)"; rc=$?
  check "ime snapshot --json（写快照）" "$EX_OK" "$rc" 'ls "$ST"/ime-snapshot-*.json >/dev/null 2>&1'

  # 先禁用两个，再用快照恢复（restore 必须补回缺失项）
  run_dv ime snapshot >/dev/null 2>&1
  "$FAKE" -s FAKE123 shell 'ime disable com.sohu.inputmethod.sogou.xiaomi/.SogouIME' >/dev/null 2>&1
  "$FAKE" -s FAKE123 shell 'ime disable com.xiaomi.type/com.mi.ime.MiInputMethodService' >/dev/null 2>&1
  out="$(run_dv ime restore --json)"; rc=$?
  check "ime restore 补齐缺失项" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"ok\":true"'
  out="$(run_dv ime status --json)"; rc=$?
  check "ime status（恢复后与快照一致）" "$EX_OK" "$rc" 'printf "%s" "$out" | grep -q "\"matches\":true"'

  # restore 校验失败：enable 被做成 no-op
  "$FAKE" -s FAKE123 shell 'ime disable com.sohu.inputmethod.sogou.xiaomi/.SogouIME' >/dev/null 2>&1
  out="$(DV_FAKE_IME_ENABLE_NOOP=1 run_dv ime restore --json)"; rc=$?
  check "ime restore 不一致 → 6" "$EX_VERIFY" "$rc"

  # 全局选项写在子命令之后 → 2（help 文案与实现一致）
  run_dv shot -n 1 --serial FAKE123 >/dev/null 2>&1; rc=$?
  check "子命令后写全局选项 → 2" "$EX_ARG" "$rc"
  run_dv cycle --out "$ST/x" >/dev/null 2>&1; rc=$?
  check "cycle 后写 --out → 2" "$EX_ARG" "$rc"

  # 参数错误 → 2
  run_dv shot -n abc >/dev/null 2>&1; rc=$?
  check "非法参数 → 2" "$EX_ARG" "$rc"
  run_dv nosuchcmd >/dev/null 2>&1; rc=$?
  check "未知子命令 → 2" "$EX_ARG" "$rc"

  # adb 缺失 → 7（devices 曾因子 shell 吞掉 die 而误报 3）
  DV_ADB=/nonexistent/adb bash "$DV_BIN/dv" doctor >/dev/null 2>&1; rc=$?
  check "adb 缺失 → 7" "$EX_ENV" "$rc"
  DV_ADB=/nonexistent/adb bash "$DV_BIN/dv" devices >/dev/null 2>&1; rc=$?
  check "adb 缺失：devices → 7（不是 3）" "$EX_ENV" "$rc"

  # help
  run_dv help cdp >/dev/null 2>&1; rc=$?
  check "help cdp" "$EX_OK" "$rc"

  # logcat --all-pids：help 里有说明，且参数不再被当成错误（曾把跨进程日志静默丢掉）
  help_out="$(run_dv help logcat 2>/dev/null || true)"
  case "$help_out" in *--all-pids*) rc=0 ;; *) rc=1 ;; esac
  check "help logcat 提到 --all-pids" "$EX_OK" "$rc"
  run_dv logcat --all-pids -n 1 >/dev/null 2>&1; rc=$?
  [ "$rc" = "$EX_ARG" ] && rc_bad=1 || rc_bad=0
  check "logcat --all-pids 参数被接受" "$EX_OK" "$rc_bad"

  say ""
  if [ "$fail" = "0" ]; then
    ok "selftest 全部通过（$pass 项）"
    [ "$verbose" = "1" ] && { say "── stderr ──"; head -20 "$ST/stderr.log"; }
    return "$EX_OK"
  fi
  err "selftest 失败 $fail 项 / 通过 $pass 项"
  say "── stderr（尾部）──"; tail -20 "$ST/stderr.log"
  return 1
}
