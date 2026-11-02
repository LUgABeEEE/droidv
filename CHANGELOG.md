# CHANGELOG

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号用 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 明确不做

流程 DSL（`dv run flow.yaml`）、录制回放、自带 MCP server、设备农场、ADB 协议重实现、视频流/输入注入引擎、
OCR 断言、APK badging 解析 —— 理由与替代方案见 README「明确不做」一节。

## [0.1.1] — 2026-11-02

首个公开修复版（`0.1.0` 是早期构建，已 deprecate）。

- `selftest` 不再依赖 `jq`（18 处断言改用 `python3`）
- `install`：`--json` 的 `installed` 改为按 **APK 内的包名**判定；`DV_INSTALL_TAP` 缺省改为 `none`（默认不自动点弹窗，坐标随分辨率/ROM 变化不可靠）
- `uitree`：失败不再重启 App（默认 exit 4），重启需显式 `--restart-app`；`marker_missing` 独立原因码
- `doctor`：adb 惰性解析；新增 `wm_size` / `wm_density` / `dpr` / `css_viewport`
- `ime`：快照按设备序列号隔离，跨设备 `restore` 会被拒绝
- `check` / `uitree`：不再强制 `--pkg`；`cdp list/version` 无包名时列出全部 target
- `lock`：争用时恢复可见报错；`selftest` 使用隔离锁目录
- `logcat`：认 `DV_PKG`
- `perf`：包未运行时 `exit 6`（`no_frames`）而不是静默返回空数据

## [0.1.0] — 2026-11-02

首个公开版本。纯 bash（少量 `python3` / `node` / `curl`），无第三方依赖，不做全局安装、不写系统路径、
不改 `PATH` / rc。**20 个子命令**，无设备自测 **79 项**。

### 新增

- 入口 `dv`：单一命令 + 全局选项（`--serial` / `--pkg` / `--adb` / `--out` / `--json` / `--verbose` /
  `--retry N` / `--no-color`）。**全局选项必须写在子命令之前**（写后面按参数错误 `exit 2`）。
  `--retry N` 只对可重试的 `4`/`6` 生效，`--json` 下多打一行 `{"phase":"retry","attempts":N,"outcome":…}`。
- **观测**：`doctor`（含 `--print-config`：打印生效值 + 来源 cli/env/conf/auto）、`check`、`devices`、
  `packages`（`--filter` / `--third-party`）、`shot`、`uitree`、`wait-until`（`--text/--focus/--expr/--shell/--pkg-visible`）、
  `cycle`、`logcat`、`crash`、`perf`。
- **驱动**：`cdp`（forward 必回收，Ctrl-C 回收后 `exit 130`）、`install`（**默认不自动点安装弹窗**，见下方「行为变更」）、
  `input`（`tap --text/--desc/--xy`、`text`、`key`；坐标从 UI 树现算，非 ASCII 直接 `exit 2`）、
  `lock`（跨进程设备锁，TTL 自动失效）、`adb`（透传 + 强超时 + 危险命令默认拒绝）。
- **构建**：`build`（任意 Gradle 工程出 APK，自动找 `gradlew`；`release` 无签名 → `exit 6`；构建失败 `exit 8`）。
- **维护**：`ime`（快照/恢复/现状，恢复会补缺 + 清多余 + 回读校验）、`npu`（只读枚举 / demo 运行）、
  `selftest`（79 项）、`help`。
- 零依赖 CDP `Runtime.evaluate`（Node ≥ 22 原生 `WebSocket`）；统一错误对象
  `{ok:false, code, phase, hint}`；`--verbose` 回显真实 adb 命令。
- `examples/`：`cdp-assert.sh`（断言代替截图）、`batch-shots.sh`（批量截图归档）、`logcat-crash.sh`（崩溃 bundle）。
- `docs/recipes.md`（10 条配方）、`docs/redlines.md`（红线）、`docs/verification.md`（三态 + 补验证模板）、
  `selftest/`（fake-adb + 假 devtools）。

### 设计取舍

- **退出码固定 8 档**：`0` 成功 / `1` 仅 selftest / `2` 参数错 / `3` 无设备或锁被占 / `4` 取数失败 /
  `5` 通道不可用 / `6` 校验失败（含找不到 APK、未签名产物）/ `7` 环境缺失（adb/python3/node≥22/curl/JDK/SDK）/
  `8` 仅 build 构建失败。
- **`--json` 一行一个 JSON 对象**；失败也保持同形状（`{ok:false, code, phase, hint}`）。
- **不写死任何具体 App**：包名默认空，缺了 `exit 2` + 修法；`dv packages` 用来先查包名。
- **等待要用判据**：`wait-until` 替代固定 `sleep`；`uitree` 的 `idle-state` 失败改为**立即** `exit 4`（~50 ms）。

### 行为变更（真机实跑后）

- **`install` 默认不再自动点「继续安装」**：`DV_INSTALL_TAP` 缺省 `none`（旧的固定坐标 `846,2002` 在横屏平板上
  会点到「拒绝」→ `INSTALL_FAILED_USER_RESTRICTED`）。要自动点就显式给**单个** `"x,y"`（`CONF_INSTALL_TAP` 同义）；
  平板 3408×2272 实测 `1060,1224` → 1.24 s 成功。坐标越界（按 `wm size`）直接 `exit 2` 并报实际屏幕尺寸。
- **`uitree` 默认不重启 App**：旧行为「连续 3 次失败 → force-stop + 重启 + 轮询 10 轮」在真机上耗时 68.7 s
  且打断 release 包用户；现在失败即 `exit 4`，重启要显式 `--restart-app`（release 包还要再加 `--allow-restart-release`）。

### 真机实跑（2026-11-02）修的 7 条

| ID | 问题 | 修复 |
|---|---|---|
| **B15** | `perf --gfxinfo` 对**没在跑**的 App「假成功」：指标全 `null`、`raw_head: "No process found"`，退出码 0 | 检测 `total_frames` 空/0 → **`exit 6`** + `reason: no_frames` + 提示先启动 App |
| **B16** | `logcat` 不认 `DV_PKG`（其它子命令都认），只吃显式 `--pkg` | `--pkg` 缺省回落到 `$PKG`（`DV_PKG` / `CONF_PKG`） |
| **B17** | `uitree --marker` 不匹配时报成「UI 树取不到」（dump 其实成功） | 独立 `reason: "marker_missing"` + 节点数与 marker，区分「页面没就绪」与「树没拿到」 |
| **B18** | `install --json` 的 `installed` 拿 `--pkg` 冒充，装 `.debug` 时会假 `true` | 从 APK 读包名（`aapt2`/`aapt` `package: name=`）+ 安装前后 `pm list` 差集判定 |
| **B19** | 固定弹窗坐标在横屏平板点不中，`.debug` 连败 3 次；d2probe 走满 10 s 才成 | 默认 `DV_INSTALL_TAP=none`（不点、提示手点）；显式坐标时按 `wm size` 校验越界 |
| **B20** | `input text` 没有聚焦输入框也报「已输入 N 个字符」（假成功） | 先查 `dumpsys input_method` 焦点视图，无 Editable → **`exit 4`** + 提示先点输入框 |
| **B21** | selftest 的 `lock` 用例共用真实锁文件，跟开发者本机的 `dv lock` 打架 | selftest 用隔离锁文件（`DV_LOCK_FILE=$ST/locks/...`） |

### 已知问题 / 未达标（诚实标注）

- **`dv selftest` 仍需 ~36 s**（79 项）：瓶颈是 79 次进程启动，`DV_SELFTEST_FAST=1` 只跳过假延时，
  **没有**压到 10 s 以内；要更快得改成进程内调用，属结构性改动，未做。
- **真机覆盖极窄**：`doctor` / `check` / `cdp version` 在真机跑过，但**证据（型号/系统版本/日期/输出片段）不随仓库
  发布**，所以 README 的「验证状态」里它们仍标「仅 selftest / 真机验证待补」；`build --variant debug`
  是**主机侧**行为（真实 Gradle 工程，7524 ms → 9.46 MB），标「主机侧已验证」。其余命令仅 selftest，
  `input` / `lock` / `wait-until` / `--retry` 连 selftest 之外的记录都没有。
- **`dv input text` 只支持 ASCII**（非 ASCII 明确拒绝并给绕开方式）。
- **未在 CI/容器里验证**：容器内 adb daemon 的 USB 权限与 udev 规则是另一类问题。
