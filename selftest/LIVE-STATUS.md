# 真机实跑状态（LIVE-STATUS）

> 这一页记录 **`dv` 在真机上跑到哪一步**，为了让人知道哪些子命令「只有自测」、哪些「真机通过」。
> 设备信息只写通用描述，不写序列号 / IP / 内部代号。
> 逐命令的状态（主机侧已验证 / 真机已验证 / 仅 selftest / 未验证）以 [README 的「验证状态」](../README.md#验证状态) 与
> [docs/verification.md](../docs/verification.md) 为准；这一页只记录「某次真机跑过什么」。

被测设备：一台 **Android 17（SDK 37）+ HyperOS / 澎湃 OS 4** 的平板/手机（Wi-Fi 无线调试接入）。

## 已在真机上实跑过（**证据未随仓库发布**，故 README 里仍标「仅 selftest / 待补」）

| 命令 | 结果 |
|---|---|
| `dv doctor` | exit 0 —— adb 可用 / 设备在线 / Android 17 (SDK 37) / 系统版本读取正确 / 被测包已安装 / 无悬挂 forward / 焦点 / IME 基线 |
| `dv check` | exit 0 —— `devices -l` + 型号 + Android/系统版本 + WebView 版本 + 当前焦点 |
| `dv cdp version`（release 包） | **exit 5**（正确行为）：无 devtools socket，并提示「release 包默认不建 socket」 |

## 主机侧已跑过（不需要设备）

| 命令 | 结果 |
|---|---|
| `dv build --variant debug`（真实 Gradle 工程） | exit 0 —— **7524 ms → 9.46 MB**；`--variant release` 无签名配置时 **exit 6**（明确说「需要 signingConfig」） |

## 待补跑（设备在线后一条命令）

```bash
DV_PKG=com.example.app bash selftest/run-live.sh <device-ip>:<port>
# 可选：DV_LIVE_APK=./app-debug.apk DV_BUILD_PROJ=../path/to/project
```

覆盖 13 步：`doctor` / `check` / `shot -n 3` / `uitree --find` / `cycle --json` / `npu check` /
`install`（装完即卸）/ `cdp version` + 浏览器阳对照 / `logcat --pkg --json` / `adb -- shell echo ok` /
`perf --gfxinfo` / `crash --json` / `build --variant debug`。

**尚未有任何真机记录的新命令**（selftest 只覆盖参数、退出码与 fake 路径）：
`wait-until`、`input`、`lock`、`packages`、`devices`、`doctor --print-config`、`--retry`。

## 无设备自测（随时可复跑，79 项 / 约 36 s）

```bash
./dv selftest
```

覆盖：doctor（含 `--print-config` 的值与来源）/ check / devices / packages / cdp（认领、forward 回收、
Ctrl-C 130）/ uitree（重试、idle 快速失败、`--timeout` 派生值）/ wait-until（五谓词 + 超时 `last_state`）/
shot / cycle / logcat（`--pkg`/`--tag`/`--crash`）/ adb（白名单、黑名单、`--allow-danger`）/ perf /
crash / input（tap/text/key、非 ASCII→2）/ lock（抢占→3、TTL）/ ime（snapshot/restore 补缺清多余/status）/
build（出 APK、noapk→6、失败→8、缺 SDK→7）/ 参数缺值→2（28 处）/ 全局选项位置→2 / `--retry` /
退出码收敛（1 只给 selftest）/ adb 缺失→7 / help 全命令。

它靠 `selftest/fake-adb`（可注入 dump 失败次数、伪造 forward ADD/REMOVE、伪造 IME/gfxinfo/logcat/
tombstone、假 gradlew 出 APK）与 `selftest/fake-devtools.py`（假 `/json/version`、`/json/list`、
最小 WebSocket）跑完，**不需要真机、不需要 Android SDK/JDK**。

## 已知坑（都是真机踩出来的）

- **`adb reconnect` 会把无线调试的 transport 摘掉**：一次 `adb shell` 卡死后执行 `reconnect`，
  叠加设备息屏/省电降 Wi-Fi，整台设备从网络消失（`No route to host`、`adb mdns` 空），
  只能等人点亮设备重开无线调试。红线见 [`docs/redlines.md`](../docs/redlines.md)。
- **release 包 = 没有 CDP**：`setWebContentsDebuggingEnabled(BuildConfig.DEBUG)` 为 `false`，
  `webview_devtools_remote_*` 不存在 ⇒ `dv cdp` 必然 exit 5。要么装 `.debug` 变体，要么走 UI 树。
- **安装弹窗 10 秒倒计时**：HyperOS 的「继续安装」弹窗超时即拒（`INSTALL_FAILED_USER_RESTRICTED`），
  且弹窗存活期 `uiautomator dump` 返回 0 字节，只能按坐标点 —— 换分辨率要校准坐标。
- **Gradle 的 `*_USER_HOME` 目录「存在 ≠ 可写」**：`ANDROID_USER_HOME` 里 AGP 要写
  `debug.keystore.lock`，`GRADLE_USER_HOME` 不可写时 wrapper 报
  `Could not create parent directory for lock file` —— 两条报错都离真因很远，`dv build` 已做写测试 + 退化 + 提示。
