# droidv

**「用断言代替截图」的安卓设备自动化调试 CLI。**

一个 `dv` 命令，管住开发者模式下的那堆脏活：装包（自动点掉系统安装弹窗）、WebView CDP 断言、
原生 UI 树、条件等待（`wait-until`）、截图归档、结构化 logcat、崩溃取证（crash 缓冲 + ANR + tombstone）、
帧统计、**节点定位输入注入**（`input tap --text`）、**跨进程设备锁**（`lock`）、IME 快照、NNAPI 枚举、
Gradle 出包、包/设备清单、无设备自测。纯 bash（少量 `python3` / `node`），不装东西、不写系统路径、
不改 `PATH` / rc。

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version](https://img.shields.io/badge/version-0.1.0-informational.svg)](CHANGELOG.md)
[![shell](https://img.shields.io/badge/shell-bash%204%2B-89e051.svg)](#安装)
[![node](https://img.shields.io/badge/node-%E2%89%A518-339933.svg)](#安装)

> **真机覆盖由社区补充**，当前每条命令跑到哪一步见[验证状态](#验证状态)；怎么补一条见 [docs/verification.md](docs/verification.md)。
>
> English summary → [跳到文末](#english-summary) · 英文全文 → [README.en.md](README.en.md)

---

## 这是什么

`dv` 把「改一次代码 → 在真机上看一眼」这件事，从**人读截图**变成**机器可判的断言**：

```bash
dv --pkg com.example.app cdp eval 'document.querySelectorAll("button").length'   # 177 ms，拿事实
dv shot -n 1                                                        # 515 ms，拿像素（不需要包名）
```

它不是设备农场，也不是测试框架 —— 它是**调试期**用的那把螺丝刀：每个坑都来自真机现场，
每个坑都有一个固定退出码。你在 CI 里能用它，在工位上也能用它。
（工具本身在哪些设备上真跑过，见[验证状态](#验证状态)；没跑过的一律标「仅 selftest」。）

- 适配目标：Android 11+（重点验证 **Android 17 / 澎湃 OS 4**，HyperOS 安装器、无线调试、WebView CDP）
- 命令：`dv`（项目名 `droidv`，仓库即工具，无安装步骤）
- 依赖：`bash 4+`、`adb`、`python3`；`dv cdp` 另需 `node ≥ 22`（原生 WebSocket）与 `curl`
- 不做：多设备并行调度、输入注入编排、跨 App 元素级自动化、流程 DSL、录制回放、自带 MCP server
  （原因见[明确不做](#明确不做)；跨 App 编排交给 Appium / Maestro，见[对比](#与其它工具对比)）

---

## 为什么：截图 515 ms + 人读 5–20 s vs CDP 断言 177 ms

同一台机器、同一条 Wi-Fi、同一个页面，两条路：

| 通道 | 单次耗时 | 谁来判断 | 能不能进 CI |
|---|---|---|---|
| `adb exec-out screencap -p`（截图） | **515 ms**（Wi-Fi）/ 0.51 s（USB） | **人**（或视觉模型）看图 | ✘ 一轮要人读 **5–20 s**，不可重试 |
| CDP `Runtime.evaluate`（断言） | **177 ms**（Wi-Fi，App 内） | **代码**（DOM / 几何 / 文本） | ✔ 失败可复现、可重试 |

> 数字来自公开可复现的真机实测（Wi-Fi transport，同一页面、同一次会话；不含冷启动与配对）。
> 口径说明：这组数字是**用独立脚本测的通道耗时**，不是 `dv` 自身的耗时——`dv` 各命令的真机覆盖见[验证状态](#验证状态)。
> 注意口径：USB 下 CDP 协议 RTT 可以低到 43 ms，**不同 transport 的数字不能互相比较**。

一轮「改完 → 看到结果」的预算：

| 做法 | 单轮耗时 |
|---|---|
| headless（无设备/模拟器） | ~12.5 s |
| 真机截图通道（重启 + 等页面 + 截图 + **人读**） | **~30–40 s**（其中人读 5–20 s） |
| **dv：CDP 5 次断言** | **≈0.9 s**（177 ms × 5） |
| dv：5 次断言 + 一次截图留证 | ≈1.4 s |

结论很朴素：**截图是证据，不是判据**。判据要用能返回值的通道（CDP 的 DOM/几何，或 UI 树的文本/bounds），
截图留给「留档、目检、视觉回归语料」。

---

## 安装

没有安装步骤 —— clone 下来直接用：

```bash
git clone <repo-url> droidv
cd droidv
./dv help
```

<sub>（`<repo-url>` 待仓库发布后替换为实际地址；本项目当前以源码目录形式分发，不做包管理器安装。）</sub>

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| `adb` | 所有设备操作 | 退出码 **7**（`--adb` / `DV_ADB` / `dv.conf` 的 `CONF_ADB` 指定；默认找 `$ANDROID_HOME/platform-tools/adb`，再找 `PATH`） |
| `python3` | JSON 拼装/转义、UI 树解析、CDP 包名认领 | **`exit 7`**（除 `dv help` 外每个子命令起手即检查） |
| `node ≥ 22` | `dv cdp eval` / `report`（需要原生全局 `WebSocket`；Node 18/20 没有） | 缺 node 或 **Node < 22**：`exit 7`（起手用 `typeof WebSocket` 探测） |
| `curl` | `dv cdp` 取 `/json/version` · `/json/list` | `exit 7`（只在 cdp 路径检查） |
| `bash 4+` | 自身 | — |

想加个别名：

```bash
alias dv="$(pwd)/dv"
```

> **运行前提：只有这些路径强制要求包名** —— `cdp eval|report`、`cycle`、`uitree --restart-app`、
> `wait-until --expr`（都是"要判断是不是你的 App"的场景）。它们走全局 `--pkg`（或 `DV_PKG` /
> `dv.conf` 的 `CONF_PKG`）；没有就 `exit 2` 并提示怎么配，`dv packages --filter …` 可以先查装了哪些。
>
> **不强制**（自带参数或读 `DV_PKG` 兜底）：`cdp version|list`、裸 `uitree`、`wait-until --text/--focus/
> --shell/--pkg-visible`、`perf --gfxinfo <pkg>`、`logcat --pkg <pkg>`（缺省读 `DV_PKG`）、`input`、
> `check`（只报连接/焦点，不校验包名）。
> 完全不需要包名：`doctor` / `shot` / `crash` / `adb` / `build` / `ime` / `npu` / `devices` /
> `packages` / `lock`。
>
> `dv help` 与 `dv selftest` **不需要 adb**（惰性解析：真要用 adb 时才去 `PATH`/常见路径找）；
> 其余子命令在 adb 缺失时 `exit 7`。

---

## 5 分钟上手

**① 环境自检**（一条命令说清「现在能不能干活」，**不需要先知道包名**）

```bash
dv doctor
```

```
dv doctor  (v0.1.2)
────────────────────────────────────────────
✔ adb        /opt/android-sdk/platform-tools/adb  (v1.0.41)
✔ 设备       <device-ip>:<port>
             model=<机型>  Android 17 (SDK 37)  HyperOS OS4.0
             包未指定（用 --pkg / DV_PKG / dv.conf 指定后才检查安装状态）
             配对配额未检查（未配置 DV_GATEWAY）
✔ 悬挂 forward 无
! 焦点       mCurrentFocusedWindow = com.android.systemui（不是 com.example.app）
✔ IME        3 个启用，默认 com.example.ime/.Service
```

**② 接一台设备**（USB 或无线都行）

```bash
adb devices                                   # USB：插上并在设备上授权
adb pair <device-ip>:<pair-port>              # 无线：设备→开发者选项→无线调试（端口每次会变）
adb connect <device-ip>:<port>
```

**③ 跑一遍全链路**（重启 App → CDP → 截图 → UI 树 → 归档）

```bash
dv --pkg com.example.app cycle
ls dv-out/cycle-*/        # cdp.json / shot.json / uitree.json / ui.xml / shot-*.png
```

**④ 换成断言，而不是看图**

```bash
dv --pkg com.example.app cdp eval 'document.title'              # 177 ms 拿到事实
dv --pkg com.example.app cdp report --json | jq '{url:.fact, targets}'
examples/cdp-assert.sh --pkg com.example.app --find "保存" --max-small 0   # 文本在 + 无 <44dp 触控目标
```

**⑤ 出问题就看日志，崩了就看现场**

```bash
dv --pkg com.example.app logcat -n 50 --level E      # 只取错误及其后
dv --pkg com.example.app logcat --crash --json | jq '.lines'
dv crash --json | jq '{crash_lines, anr, tombstones_readable}'
examples/logcat-crash.sh --pkg com.example.app        # 一条命令出 bundle（崩溃块 + 截图 + UI 树）
```

**⑥ 别再 `sleep 10` 赌页面加载完了**

```bash
dv --pkg com.example.app wait-until --text "保存" --timeout 15   # 命中就返回（通常 <1 s），超时 exit 4 带现场
dv --pkg com.example.app wait-until --focus com.example.app --json | jq '.last_state'
dv packages --filter example                          # 忘了包名？先列一下
dv --pkg com.example.app input tap --text "保存"       # 坐标从树现算，不写死 846 2002
```

**⑦ 跑自测**（不需要设备，验证这套东西本身没坏）

```bash
./dv selftest        # 79 项断言，约 36 s，exit 0
```

---

## 子命令

按**难度 / 常用度**分组。20 个子命令，全部已实现（无「规划中」）。

### 观测（最常用，先看再改）

| 命令 | 说明 |
|---|---|
| `dv check [--json]` | 连接检查：`devices -l` + 型号/Android/SDK/系统版本 + WebView 版本 + 当前焦点（**需要包名**） |
| `dv doctor [--json] [--print-config]` | 环境自检：adb / 设备 / 版本 / 包 / 配对配额（需 `DV_GATEWAY`）/ 悬挂 forward / 焦点 / IME 基线。`--print-config` 只打印「生效值 + 来源（cli/env/conf/auto）」，不碰设备。**不需要包名** |
| `dv devices [--json]` | 设备清单：序列号 / 状态 / 型号 / `product:device` / transport / 有线或无线；**没有在线设备时 `exit 3`** 并给 USB/无线提示 |
| `dv packages [--filter SUBSTR] [--third-party] [--json]` | 列出设备上的包名；`--third-party` 只看第三方。**忘记包名时先跑它** |
| `dv shot [-n N] [-o DIR] [--json]` | 截图归档，逐张记录耗时 |
| `dv uitree [--marker M] [--find TEXT] [--json] [--dump-out FILE] [--timeout N]` | 原生 UI 树：`rm → dump → 三件套校验 → 重试 → 重启轮询`；`idle-state` 失败**立即 exit 4**（约 50 ms，不再空耗 3×11 s） |
| `dv wait-until <--text T\|--focus PKG\|--expr JS\|--shell CMD\|--pkg-visible PKG> [--timeout N] [--interval S] [--json]` | **有判定条件的等待**：命中 `exit 0`，超时 `exit 4` 并给出「等了多久 / 最后观察到的状态 / 排查建议」（`--json` 里是 `last_state`） |
| `dv cycle [--json] [--no-cdp]` | 全链路组合：重启 → CDP → 截图 → UI 树 → 归档到 `cycle-<ts>/` |
| `dv logcat [--pkg P] [--pid N] [--tag T] [--level V\|D\|I\|W\|E] [-n N] [--since T] [--crash] [--json] [--follow [秒]]` | 日志取数：按进程/pid/tag/级别过滤，`--json` 每行一个对象，`--follow` 限时跟流 |
| `dv crash [-n N] [--json]` | 崩溃取证：`logcat -b crash` + ANR 摘要 + `/data/tombstones` 列表（读不到如实说明，不算失败） |
| `dv perf --gfxinfo <pkg> [--json]` / `dv perf --record <秒> [-o DIR]` | 帧统计摘要（总帧/掉帧/p50/p90/p95/p99）或限时录屏并拉回 |

### 驱动（要改设备状态，慎用）

| 命令 | 说明 |
|---|---|
| `dv cdp version\|list\|eval '<js>'\|report [--json]` | WebView CDP：自动 forward + `Android-Package` 认领 + **任何退出路径都回收 forward**（Ctrl-C 也会回收后 `exit 130`） |
| `dv install [--apk PATH] [--json]` | 装 APK。**默认不自动点安装弹窗**（`DV_INSTALL_TAP=none`）：弹窗出现后请手点「继续安装」；要自动点就显式给坐标（见[安装弹窗](#安装弹窗默认不自动点)）。超时判 `USER_RESTRICTED`（`exit 6`）；`--json` 的 `installed` **按 APK 里的包名判定**，不拿 `--pkg` 冒充 |
| `dv input tap (--text T\|--desc D\|--xy X,Y) [--index N]` / `dv input swipe --from X1,Y1 --to X2,Y2 [--ms N]` / `dv input text <ASCII>` / `dv input key <KEYCODE\|名称>` | **按节点定位再点 / 滑动 / 输入 / 按键**：坐标从 UI 树现算（打印 px + css + dpr），不用写死；`text` 只收纯 ASCII，**非 ASCII 直接 `exit 2` 并给三种绕开方式**；`key` 支持 `BACK/HOME/ENTER/TAB/DEL/MENU/APP_SWITCH/SPACE/ESC/WAKEUP/POWER/VOLUME_*` 等 13 个名称 |
| `dv lock acquire <名字> [TTL秒=900]` / `release` / `status [--json]` | **跨进程设备锁**（锁文件 `~/.cache/dv/lock-<serial>`，每台设备一把）：被别人持有 → `exit 3` 并打印持有者 + pid + 获取时间 + 剩余秒数；TTL 到期自动失效（会话崩掉不会把设备锁死） |
| `dv adb [--timeout N] [--allow-danger] -- <adb 子命令…>` | adb 透传：自动 `-s` + 强制超时；**危险命令默认拒绝**（reboot/root/remount/kill-server/reconnect/tcpip/uninstall/settings put），要放行得显式 `--allow-danger` |

### 构建

| 命令 | 说明 |
|---|---|
| `dv build [--project DIR] [--variant debug\|release] [--flavor NAME] [--install] [--offline] [--json]` | 从任意 Gradle 工程出 APK（自动向上找 `gradlew`，最多 8 层），可选直接装到设备。实测：debug 构建 **7524 ms → 9.46 MB**。`release` 没配 `signingConfig` 直接 `exit 6`（不会给你一个装不上的 unsigned 包）；构建失败固定 `exit 8` |

### 维护（管好工具自己）

| 命令 | 说明 |
|---|---|
| `dv ime snapshot\|restore\|status [--json]` | IME 快照 / 按快照恢复（**补缺 + 清掉快照里没有的多余 IME**，回读校验不一致 → `exit 6`）/ 现状。`ime disable` 前必须先 `snapshot` |
| `dv npu check\|run [--apk PATH]` | NNAPI / NPU：`check` 只读枚举（4 次独立取数，不会再假阴性），`run` 装并运行 demo（唯一有副作用的 npu 动作） |
| `dv selftest [--verbose]` | 无设备自测：fake-adb + 假 devtools 端点，**79 项断言**（约 36 s） |
| `dv help [子命令]` | 帮助（**子命令的选项与退出码以它为准**） |

全局选项（**必须写在子命令之前**，见[红线第 3 条](docs/redlines.md#3-全局选项必须写在子命令之前)）：

```
--serial <S>  --pkg <P>  --adb <PATH>  --out <DIR>  --json  --verbose  --retry N  --no-color
```

- `--retry N`：失败自动重试 N 次，**只对可重试的 `4`（取数失败）/ `6`（校验失败）生效**；
  `--json` 下会多打一行 `{"phase":"retry","attempts":N,"outcome":"flaky|failed"}`。
- `--verbose`：把实际执行的 adb 命令回显到 stderr。

---

## 验证状态

状态定义（主机侧 / 真机 / 仅 selftest / 未验证）、补验证流程与脱敏要求见 **[docs/verification.md](docs/verification.md)**。
一句话：`dv selftest` 全绿**不等于**真机可用；只有留了「设备 + 系统 + transport + 命令 + 退出码 + 输出片段」才算。

**2026-11-02 真机实跑**：Xiaomi 17 Pro Max（USB，1200×2608 @480dpi → DPR 3.0）+ Xiaomi Pad 9 Pro Max
（无线调试，2272×3408 @400dpi → DPR 2.5），均 **Android 17 (SDK 37) / 澎湃 OS 4.0**。
逐条退出码、耗时、原始 stderr 见 [`selftest/LIVE-STATUS.md`](selftest/LIVE-STATUS.md)（手机 29 条 + 平板 26 条）。

| 命令 | 状态 | 依据 / 备注 |
|---|---|---|
| `doctor` / `check` / `devices` / `packages` / `ime` / `shot` / `uitree` / `wait-until` / `logcat` / `crash` / `perf` / `lock` / `npu` / `adb` | **真机已验证** | 2026-11-02，两台设备（见上），含成功路径与失败路径（`wait-until` 超时 → 4；`adb -- reboot` 被拒 → 2；`lock` 争用 → 3） |
| `cycle` | **真机已验证**（平板 `.debug`） | 两次 `exit 5`（无 CDP 时的正确结果），产物齐全、`forward --list` 前后为空（无泄漏）；手机未跑 |
| `build --variant debug` | **真机已验证**（主机侧行为，不需要设备） | 手机 6684 ms、平板同工程 7524 ms → 9.46 MB；`release` 无签名 → `exit 6` |
| `install` | 有条件已验证（平板） | 默认 `DV_INSTALL_TAP=none` 不自动点；显式 `DV_INSTALL_TAP="1060,1224"`（横屏 3408×2272）→ **1.24 s 成功**；手机坐标未量 |
| `input` | 真机已验证（`tap` 路径 + 失败路径） | 平板 `input tap --text 局域网访问` → 0，打印 `(1704,528) px = (681.6,211.2) css [dpr=2.5]`；`tap` 找不到 → 4；`text 中文` → 2 |
| `cdp` | **历史已验证 / 今日未复跑** | 历史：t7 三段全通（socket + `/json/version` + WS `Runtime.evaluate`，Android 17 / 无线调试）；今日两侧都因**配对需人参与**未复跑；release 包上 `cdp version` 正确 `exit 5` |
| `input text <ASCII>` 正向输入到真实会话 | 未验证 | 今日实测时页面没有输入框（旧版假成功，现已改为无输入框 → `exit 4`） |
| `build --install` 到手机 | 未验证 | 平板已验证（`--install` 复用同一套安装逻辑） |
| `--retry` | 未验证 | 只对 `4`/`6` 生效；真机只跑过一次「无 flaky」 |

> 这张表只写「谁在什么设备上跑过」。**不要**为了表格好看把「未验证」改成「已验证」；补一条就按
> `docs/verification.md` 的模板交（设备型号 + 系统 + transport + 日期 + 命令 + 退出码 + 10–30 行输出）。

---

## 退出码

固定 8 档，脚本可以直接按码分支，不需要解析文案。`1` 只留给 `selftest`，`8` 只留给 `build`。

| 码 | 含义 | 典型场景 |
|---|---|---|
| `0` | 成功 | |
| `1` | **仅** `dv selftest` 内部断言失败（其他任何失败一律不用 `1`） | 自测回归 |
| `2` | 参数错误 | 未知子命令/选项、选项缺值、`-n abc`、**全局选项写到子命令后面**、多设备未指定、`input text` 含非 ASCII |
| `3` | 无设备 / 锁被占 | `adb devices` 空且 mdns 也找不到；显式 serial 连不上；`dv lock acquire` 时锁被他人持有 |
| `4` | 取数失败（重试后） | `uitree` 重试用尽/`idle-state` 立即失败；`wait-until` 超时；截图文件异常（< 1000 B）；`adb` 超时 |
| `5` | 通道不可用 | 无 devtools socket、forward 失败、HTTP 非 200、`cdp eval` 超时；`cycle` 里 CDP 失败 |
| `6` | 校验失败 | `Android-Package` 不匹配、XML 缺 marker/package、安装被拒（`USER_RESTRICTED`）、找不到 APK、`release` 只出未签名产物 |
| `7` | 环境缺失 | adb 不存在（`help` 除外）、缺 `python3` / `node ≥22` / `curl` / JDK / Android SDK |
| `8` | **构建失败**（仅 `dv build`） | Gradle 返回非 0（依赖下载失败、编译错误……） |

`--json` 一律**一行一个 JSON 对象**，可直接 `jq` / 落 `jsonl`。

---

## 10 条配方

完整版（含预期、失败怎么读）在 [`docs/recipes.md`](docs/recipes.md)。

| # | 场景 | 一行命令 |
|---|---|---|
| R1 | 装 debug 包并取一次 CDP JSON | `dv --pkg <pkg>.debug install --apk app-debug.apk && dv --pkg <pkg>.debug cdp report --json \| jq .android_package` |
| R2 | 量 44dp 触控目标（几何断言） | `dv --pkg com.example.app cdp eval '<收集 <44dp 元素的 JS>'`（见配方） |
| R3 | 抓失败/崩溃现场（证据三件套） | `dv crash --json` + `dv shot -n 1 -o /tmp/fail` + `dv uitree --dump-out /tmp/fail/ui.xml` |
| R4 | release 包没有 CDP → 页面文本回读 | `dv --pkg com.example.app uitree --json --marker '[dvmeta:' --dump-out /tmp/cch.xml` |
| R5 | 检查 NPU（只读） | `dv npu check --json \| jq '{hal_lines,dev_nodes}'` |
| R6 | 换设备 / 换包名 | `dv --pkg com.example.app --serial <serial> check` · `DV_CONF=./phone.conf dv doctor` |
| R7 | 批量跑多台设备并消费 JSON | `for s in <a> <b>; do dv --serial "$s" cycle --json \| jq -c . ; done \| tee batch.jsonl` |
| R8 | 排查「配对设备已达上限」 | `dv doctor --json \| jq .pair_device_count`（需 `DV_GATEWAY`） |
| R9 | 排查 `INSTALL_FAILED_USER_RESTRICTED` | `dv install --apk app-debug.apk; echo "exit=$?"` |
| R10 | 等页面真的就绪（别再 `sleep`） | `dv --pkg com.example.app wait-until --text "保存" --timeout 15` |

---

## 红线

完整版（含现场还原与正确做法）在 [`docs/redlines.md`](docs/redlines.md)。

1. **不要对无线调试的 transport 用 `adb reconnect`** —— 会摘掉 transport，叠加息屏/省电降 Wi-Fi
   之后设备可能**从网络消失**（`No route to host`、mdns 空），只能等人点亮设备重开无线调试。
2. **不要 `adb kill-server`** —— 重起的 daemon 可能拿不到 USB 权限，并清掉所有 forward/reverse 与无线连接。
3. **全局选项必须写在子命令之前** —— 写后面 `exit 2`；比「选项被静默忽略、命令打在错设备上」便宜太多。
4. **任何 `ime disable` 之前先 `dv ime snapshot`** —— 只恢复默认那个 IME 会把其余留在禁用状态；
   只禁一个会触发系统自动切换 + 首启隐私弹窗。恢复用 `dv ime restore`（按快照补齐 + 回读校验）。
   `restore` 会**补缺 + 清掉快照里没有的多余 IME**，然后回读校验；仍不一致才 `exit 6`。

附：**release 包不能当 debug 用**（没有 devtools socket，`dv cdp` 必然 `5`）；
**别把系统浏览器的 socket 当成被测 App**（`dv cdp` 用 `Android-Package` 认领，不匹配就 `6`）。

---

## 与其它工具对比

| | **droidv (`dv`)** | adb 裸脚本 | uiautomator / Espresso | Appium / uiautomator2 / Maestro | scrcpy |
|---|---|---|---|---|---|
| 形态 | 单一 CLI，无服务端 | 你得自己写 | 测试 APK / instrumentation | server + driver，生态重 | 实时投屏/控制 |
| 判定依据 | **CDP 断言（DOM/几何）+ UI 树文本/bounds** | 解析 adb 文本 | View 树 / 无障碍树 | 元素定位 + 断言 | 人眼 |
| 单次判定耗时 | **~177 ms**（CDP）/ 1–3 s（UI 树 dump） | 看你写什么 | 快（同进程） | 慢（多一跳 HTTP/WS） | 实时，但要人看 |
| 依赖 | bash + adb + python3(+node) | adb | Android SDK + 构建 | Python/Node + server + driver | server jar |
| 安装成本 | **0**（clone 即用） | 0 | 中 | 高 | 低 |
| 适合 | **调试期：改一次验一次、抓现场、留证** | 一次性排查 | App 内单测 / 回归套件 | 跨 App 端到端冒烟 | 需要人看的场景 |
| 不适合 | 跨 App 编排、并发设备农场 | 长期维护 | 非本 App / WebView 内容 | 快速单点验证（启动成本高） | 自动判定 |

**怎么选**：调试期用 `dv`（判定快、现场全）；要长期回归就把它包进你的测试框架；
要跨 App 编排再上 Appium / Maestro —— 那些方案的启动成本在这里换不回速度。

> 诚实标注：上表里 Appium / uiautomator2 / Maestro / Espresso 一列是**未在本机实测**的工程常识，
> 量级用于选型参考，不当精确数字用。adb/CDP 的数字来自真机实测（独立脚本，可复现，见[为什么](#为什么截图-515-ms--人读-520-s-vs-cdp-断言-177-ms)）；
> `dv` 自身跑到哪一步见[验证状态](#验证状态)。

### Related work（与同类工具的差别）

droidv 不是又一个 UI 测试框架，而是一条**面向「改一次、验一次」的窄 CLI**。

- **Appium** 以 W3C 会话和插件化驱动覆盖全平台，适合成套用例；
- **uiautomator2** 以设备端 agent 提供最顺手的 Python 选择器；
- **Maestro** 用 YAML 把流程写成可读文本；
- **mobile-mcp** 把动作拆成给 LLM 用的细粒度工具。

它们的共同点是**都要装东西、都要起服务、都把「断言」留给上层**。droidv 的选择相反：

1. **断言优先** —— `dv --pkg … cdp eval` / `dv --pkg … uitree --find` 直接对页面内指标下判断，退出码就是结论
   （`0/2/3/4/5/6/7/8` 分层，脚本可直接分支）；
2. **零第三方依赖** —— 纯 bash + 已有的 `adb`，外加可选的 `node` / `python3`，不装 agent、不起 server；
3. **单文件 CLI** —— 一个 `dv`，拷过去就能跑，不写 `PATH`、不改 rc、不碰系统目录。

它**不**做设备农场、不做录制回放、不做分片调度：需要时把 scrcpy / Appium / SoloPi 当独立程序调用即可。
droidv 只补一件它们都不专门做的事——**在真机上用一条命令拿到「可判定、可归档、可复现」的证据**。

灵感来源（只学设计，不复制代码）：pidcat（logcat 的 UX）、scrcpy（设备选择 / 推 server）、
uiautomator2（等待模型）、mobile-mcp（工具粒度）、adbkit（错误模型）。

### License 边界

本仓库 **MIT**，且不 vendor 任何 GPL / 自定义许可代码：只 shell out 到独立程序（`adb`、可选 `scrcpy` / `gradlew`），
属「独立程序聚合」，不触发传染。核对过的同类项目许可：

| 许可 | 项目（举例） | 能否抄代码 |
|---|---|---|
| GPL-2.0 | Marathon | ❌ 不能（只能读设计 / 独立进程调用） |
| 自定义非 OSI | Fastbot（Fastbot Revised License） | ❌ 不能（保守按只读处理） |
| Apache-2.0 | scrcpy、Appium、Maestro、Airtest、STF、Flank、mobile-mcp、pidcat | ✅ 可借鉴；若粘贴片段需保留声明（必要时加 `NOTICE`） |
| MIT | uiautomator2、DroidBot、droidv 自身 | ✅ 保留版权声明即可 |

若将来粘贴 Apache-2.0 片段：在仓库根加 `NOTICE`，注明来源文件 + 版权行 + “modified”。
**不要**把 Marathon 的 jar 打进发布包，也不要 vendor 任何 GPL 代码。

---

## 配置

优先级：**命令行 > 环境变量 `DV_*` > `dv.conf` > 自动探测**。

```bash
cp conf.example dv.conf && $EDITOR dv.conf    # 全部是可选的默认值；dv 不读任何凭据
```

常用环境变量：

| 变量 | 作用 |
|---|---|
| `DV_SERIAL` / `DV_PKG` / `DV_ADB` / `DV_OUT` / `DV_ACTIVITY` | 同 `--serial` / `--pkg` / `--adb` / `--out` |
| `DV_FORWARD_PORT` | CDP 本地转发端口（默认 9333，被占用自动往后找） |
| `DV_ADB_TIMEOUT` | 单条 adb 调用超时（默认 30 s；设备卡死时 CLI 不会一起挂住） |
| `DV_TIMEOUT` | 统一超时预算（默认 30 s）：`uitree` 的重试/重启/轮询次数由它派生（retry=/15、boot=/4 向上取整、poll=/10） |
| `DV_LOCK_FILE` | 覆盖 `dv lock` 的锁文件路径；默认是 **`~/.cache/dv/lock-<serial>`**（每台设备一把锁，序列号里的 `:` 换成 `_`；目录不可写时退化到 `$DV_OUT/lock-<serial>`） |
| `DV_SELFTEST_FAST` | `=1` 时 selftest 跳过假延时（**不影响真机路径**） |
| `DV_INSTALL_TAP` / `CONF_INSTALL_TAP` | 安装弹窗的自动点击坐标 `"x,y"`；**默认 `none` = 不自动点**（弹窗出现后手点「继续安装」）。给了坐标才会点；越界（按 `wm size`）会 `exit 2` 并报实际屏幕尺寸 |
| `DV_INSTALL_TIMEOUT` | 等安装结果的总超时（默认 180 s）；超时/被拒 → `exit 6`（`USER_RESTRICTED`） |
| `DV_APK` / `DV_NPU_APK` / `DV_NPU_PKG` | 默认 APK 与 NNAPI demo 包名 |
| `DV_IME_SNAPSHOT` | IME 快照路径（默认 `${XDG_CACHE_HOME:-~/.cache}/dv/ime-snapshot.json`） |
| `DV_GATEWAY` / `CONF_GATEWAY` | 可选：主机侧网关地址（`doctor` 会去读 `<gateway>/api/mobile-access/lan/status` 的 `deviceCount`）；不配则跳过这项 |
| `DV_MARKER` | `uitree` 的默认 marker（C 通道就绪判据），缺省为空=不校验 |
| `DV_JAVA` / `DV_SDK` | `dv build` 用的 JDK / Android SDK 路径（优先级最高） |
| `DV_BUILD_TIMEOUT` | `dv build` 超时（默认 1800 s） |
| `DV_ANDROID_USER_HOME` | `dv build` 的 `ANDROID_USER_HOME`（默认 `~/.cache/dv/android`，**做写测试**，不可写自动退化） |
| `DV_GRADLE_USER_HOME` | `dv build` 的 `GRADLE_USER_HOME`（默认 `$GRADLE_USER_HOME` / `~/.gradle`，同样做写测试） |
| `DV_CONF` | 换一份配置文件 |
| `NO_COLOR` / `DV_VERBOSE` | 关色 / 等价 `--verbose` |

`dv.conf` 里的键与 `DV_*` 一一对应（`CONF_SERIAL` / `CONF_PKG` / `CONF_ADB` / `CONF_OUT` /
`CONF_ACTIVITY` / `CONF_MARKER` / `CONF_GATEWAY` / `CONF_FORWARD_PORT` / `CONF_NPU_APK` / `CONF_APK`），
完整模板见 [`conf.example`](conf.example)。

设备发现顺序：显式指定（`--serial` > `DV_SERIAL` > `CONF_SERIAL`，离线会**尝试 `adb connect` 一次**）→
`adb devices` 唯一在线 → 多台在线时**报错并列出设备**（要求用 `--serial`；**实测退出码 3**，因为调用方把
「多台」的 2 折成了 3，见[已知限制](#已知限制)）→ `adb mdns` 的 `_adb-tls-connect` → 都失败 `exit 3`。

---

## 已知限制

- **一次只操作一台设备**：多设备必须显式 `--serial`，不做并行调度（批量见[配方 R7](docs/recipes.md)）。
- **`dv cdp` 只做读**：`eval` 可以写 DOM（`el.click()`、`Page.reload` 未封装），但**不做输入注入**
  （IME 状态、坐标漂移、软键盘遮挡都会让注入不可复现）。
- **UI 树依赖 `uiautomator dump`**：`could not get idle state`（页面动画不停 / 明显卡顿）现在**立即
  `exit 4`**（约 50 ms，带 `reason=idle_timeout` 与替代建议），不再重试三次；其余瞬时错误仍按
  `重试 → 重启 → 轮询` 的阶梯走。
- **只认 `text` 属性**：`content-desc` / `aria-label` 要单独用 `--find` 匹配，不会自动合并。
- **`dv selftest` 仍要 ~36 s**（79 项）：瓶颈是 79 次 `dv` 进程启动，不是等待；`DV_SELFTEST_FAST=1`
  只跳过假延时，**没有**把它压到 10 s 以内。要更快得改成「source lib 进程内调用」，属结构性改动，未做。
- **`dv input text` 只接受纯 ASCII**：非 ASCII（中文、emoji）会 `exit 2` 并给三种绕开方式（剪贴板 /
  `adb shell input text` 的 %s 编码 / App 侧输入）。这是刻意拒绝，不是 bug。
- **`dv lock` 是协作锁，不是强制锁**：它只约束「愿意先 acquire 的调用方」；TTL 到期自动失效，
  长任务要自己续期（重新 `acquire`）。
- **`dv check` 需要包名**（`--pkg` / `DV_PKG` / `dv.conf`）：它要判断焦点和安装状态；没有包名时给
  `exit 2` 而不是猜一个。`dv doctor` 不需要包名。
- **`dv crash` 的 tombstone 通常读不到**：`/data/tombstones` 一般只有 root 可读，工具会如实标注
  `tombstones_readable: false`，这不是失败。
- **`dv perf --gfxinfo` 只对「硬件加速渲染的 App」有数**：纯 WebView/软件渲染的进程可能全是 0，
  这时该看 `dv cdp` 的 DOM/几何而不是帧统计。
- **`dv logcat --follow` 是限时窗口**（默认 30 s，`Ctrl-C` 可中断），不是常驻服务；要长期采集请自己
  起 `adb logcat` 重定向到文件。
- **`dv build` 依赖本机 JDK + Android SDK**：缺任何一个都是 `exit 7`；构建失败是 `exit 8`。
  它只做 `./gradlew assemble<Variant>` + 找产物，不解析 AGP 配置。
- **不在 CI/容器里测过**：容器内 adb daemon 的 USB 权限、udev 规则是另一套坑，本仓库未覆盖。
- **真机覆盖是「两台设备、一天」的量级**：2026-11-02 在 Xiaomi 17 Pro Max 与 Xiaomi Pad 9 Pro Max
  （Android 17 / 澎湃 OS 4.0）上跑了 55 条、覆盖 18 个命令（其中 `install` 是「有条件已验证」；见[验证状态](#验证状态)），
  但 CDP 今日未复跑、
  `input text` 正向输入与手机上的 `build --install` 仍未验证。其他 ROM 的安装弹窗、IME 列表、
  `dumpsys` 字段名都可能有差异（这正是 `doctor` 存在的理由）。

---

## 已知坑与定向提示

真机上踩过、而且**报错位置离真因很远**的几处。`dv` 已经把判断做进命令里，但你仍然要知道它在防什么。

### Gradle 的两个 `*_USER_HOME`：`mkdir` 成功 ≠ 可写

- **`ANDROID_USER_HOME`**：AGP 会往里写 `debug.keystore.lock`。目录存在但**不可写**时，构建会在很靠后的
  阶段炸，报错看起来像签名问题。`dv build` 的做法：`mkdir -p` 之后**写测试**（`mkdir && : > .dv-w`），
  失败就退化到 `~/.cache/dv/android` 并打提示（`DV_ANDROID_USER_HOME` 可指定）。
- **`GRADLE_USER_HOME`**：同理。目录不可写时 Gradle wrapper 报
  `Could not create parent directory for lock file` —— 这条报错完全不提「权限」，很容易被当成网络问题。
  `dv build` 同样做写测试、退化、提示；用 `DV_GRADLE_USER_HOME` 指向已有缓存的目录可以复用依赖、少下几分钟。

### 构建失败：保留日志 + 三条定向提示

`dv build` 失败时（`exit 8`）不会只给一句 "BUILD FAILED"：它把完整 Gradle 日志留在
`<project>/.dv-build.log`，并**只摘 `What went wrong` 到 `* Try:` 那一段**打到 stderr，然后按错误特征给定向提示：

| 日志特征 | 提示 |
|---|---|
| `Read timed out` / `Could not resolve` | 分发包/依赖下载超时：重试、`--offline`（依赖已缓存）、或给 Gradle 配镜像（**dv 不写死任何镜像**） |
| `distributionUrl=file:` + 路径含中文/空格 | 换成 `file://` URI 编码后的路径，或把发行包放到纯 ASCII 路径 |
| `Could not create parent directory` / `Permission denied` | `*_USER_HOME` 不可写：见上一小节，用 `DV_GRADLE_USER_HOME` / `DV_ANDROID_USER_HOME` 指到可写目录 |

### `release` 没有 `signingConfig` → `exit 6`，不是 `8`

构建本身可能"成功"，但产物是 `*-unsigned.apk`，装不上。`dv build` 在构建前就检查
`signingConfig` / `DV_ANDROID_KEYSTORE_FILE`，缺了直接 `exit 6` 并说明「需要 signingConfig」——
**宁可早失败，也不给你一个装不上的包**。要出包就 `--variant debug`，或在工程里配签名。

### `dv doctor` 的 IME 基线：只告警，绝不改设备

`doctor` 会读 `ime list -s` 的数量、`settings get secure default_input_method`、
`show_ime_with_hard_keyboard`，发现「启用数 < 2」或「默认 IME 不在启用列表」时只打 WARN + 修复提示。
**它不会自动 `ime enable/disable`** —— 改输入法状态是用户的设备，不是工具的。

### 安装弹窗：默认不自动点

旧版本会按固定坐标 `846,2002` 自动点「继续安装」。**这个默认值已经不可靠**：按钮位置随分辨率、DPI、
**横竖屏**和 ROM 版本变化，在 2272×3408 的横屏平板上会点到「拒绝」→ `INSTALL_FAILED_USER_RESTRICTED`（`exit 6`）。

所以 0.1.1 起：`DV_INSTALL_TAP` **缺省是 `none`**——不点，弹窗出现后由你手点「继续安装」，
`dv await`（`--json` 时看 `status`）等安装结果；超时会给出明确错误而不是静默失败。

要自动点就显式给坐标：

```bash
DV_INSTALL_TAP="1060,1224" dv --pkg com.example.app install --apk app-debug.apk   # 平板横屏 3408×2272 实测值
DV_INSTALL_TAP="600,1800"  dv install --apk app-debug.apk                          # 手机 1200×2608 可作起点
```

- 坐标单位是 **px**（不是 dp/css）；用 `dv doctor --json` 的 `screen` 字段（`wm_size` / `wm_density` / `dpr`）换算；
- 换设备/换方向要重新量：弹窗按钮位置与窗口方向绑定；
- 坐标越界会被拒（`exit 2`，报出实际屏幕尺寸），避免"点到屏幕外还以为成功"；
- 也可以写进 `dv.conf`：`CONF_INSTALL_TAP=1060,1224`。

**`--json` 的 `installed` 按 APK 里的包名判定**（`aapt2`/`aapt` 读 `package: name=`，再和 `pm list packages`
前后差集比对），不再拿 `--pkg` 冒充——否则装的是 `.debug` 而 `--pkg` 是 release 时，会给出假的 `installed:true`。

### 其它老坑（都已在命令里处理）

- **`uiautomator dump` 的 idle-state 失败**：单次空耗 ~11 s，连发无效，所以内置「失败 sleep 2 再试」；
  真机实测后改为**失败即 `exit 4`**（约 50 ms），不再重试三次、也**不再默认重启 App**（重启要显式
  `--restart-app`，release 包还要再加 `--allow-restart-release`）。
- **`uitree --marker` 不匹配**：dump 成功但没有 marker 时给独立的 `reason: "marker_missing"`（不再报成
  "UI 树取不到"），并打印节点数与 marker，便于区分「页面没就绪」和「树没拿到」。
- **`perf --gfxinfo` 对没在跑的 App 会"假成功"**：现在检测 `total_frames` 为空/0 → `exit 6`（`reason: no_frames`）
  并提示先启动 App；不再输出一堆 `null` 当成功。
- **`input text` 没有聚焦输入框时**：旧版会假成功「已输入 N 个字符」，现在先查 `dumpsys input_method`
  的焦点视图，没有 Editable → `exit 4` 并提示先点输入框。
- **release 包没有 devtools socket**：`dv cdp` 必然 `5`，不是工具坏了。

---

## 明确不做

这些不是「还没做」，是**决定不做**（每条都有理由，能挡掉一半 feature request）：

| 不做 | 为什么 | 该用什么 |
|---|---|---|
| `dv run flow.yaml` 流程 DSL | 声明式 DSL 的语法/等待语义/生态是另一个产品；bash 里维护不住 | 要编排就 shell out 给 [Maestro](https://docs.maestro.dev/maestro-flows) |
| 录制 / 回放 | 录制产物对分辨率、时序、数据状态强耦合，回放失败率高于收益 | [Airtest](https://github.com/AirtestProject/Airtest) / SoloPi |
| 自带 MCP server | 多一层协议就多一层版本负担；`--json` + 退出码已经足够被任何上层包装 | 上层自己包 `dv --json` |
| 设备农场 / 分片调度 | 队列、锁、Web 控制台是另一个产品；我们的单位是「一轮验证」不是「一套用例」 | STF / Marathon / Flank |
| ADB 协议重实现 | 协议版本差异（server 41 vs client 36 会互踢）会变成永久维护负担 | shell out `adb`（现状） |
| 视频流 / 输入注入 | scrcpy 十年打磨的 MediaCodec + 注入链路，自己写必翻车 | [scrcpy](https://github.com/Genymobile/scrcpy) |
| 图像识别 / OCR 断言 | 识别率与字体、缩放、抗锯齿强耦合，不可复现 | 用 CDP/DOM 取文本，别截图识别 |
| APK 解析（badging） | 二进制格式，重写必错 | `aapt2 dump badging` |

---

## English summary

**droidv is a CLI for Android device debugging that replaces screenshot-reading with assertions.**

`dv` wraps the boring, error-prone parts of developer-mode debugging — installing debug builds past the
system installer dialog, WebView CDP assertions, native UI-tree dumps, screenshots, structured logcat,
crash forensics (crash buffer + ANR + tombstones), frame stats, IME snapshots, NNAPI enumeration, Gradle
builds and a device-free self-test — into one bash entry point (small amounts of `python3` / `node`;
nothing is installed globally, no system paths are touched).

Why it exists, in one line: **a screenshot costs 515 ms and a human 5–20 s to read, while a CDP
`Runtime.evaluate` returns a hard fact in 177 ms** (Wi-Fi transport, same page and session). Screenshots
are evidence; assertions are the verdict.

```bash
git clone <repo-url> droidv && cd droidv
./dv help                                  # works without adb (lazy resolution)
./dv selftest                              # 79 assertions, no device/adb needed
./dv doctor                                # adb / device / OS version / forwards / focus / IME baseline
./dv --pkg com.example.app cycle           # restart → CDP → screenshot → UI tree → archive
./dv --pkg com.example.app cdp eval 'document.title'   # 177 ms, a fact you can assert on
./dv --pkg com.example.app logcat --crash --json       # structured crash-buffer lines
./dv crash --json                          # crash buffer + ANR + tombstone availability
./dv --pkg com.example.app wait-until --text "Save" --timeout 15   # wait on a condition, not a sleep
```

- **Exit codes**: `0` ok · `1` failing self-test · `2` bad args · `3` no device · `4` data failure ·
  `5` channel unavailable · `6` verification failed · `7` environment missing · `8` build failure.
- **Global options go before the subcommand** (`dv --serial X shot`), otherwise `exit 2`.
- **Red lines**: never `adb reconnect` a wireless transport, never `adb kill-server`, always
  `dv ime snapshot` before any `ime disable`.
- **Recipes** (10, with expected/failure readings): [`docs/recipes.md`](docs/recipes.md).
- **Red lines** in full: [`docs/redlines.md`](docs/redlines.md).
- **Deliberately out of scope**: flow DSL, record/replay, a bundled MCP server, device farms,
  re-implementing the ADB protocol, video streaming, OCR-based assertions (see 明确不做 above).
- **All 20 subcommands are implemented** — including `wait-until`, `devices`, `doctor --print-config`
  (they are documented above, not "planned"). Full English README: [README.en.md](README.en.md).

License: MIT © 2026 LUgABeEEE.

---

## 来源与致谢

- 每条子命令**要防的现象**都来自真机现场（WebView CDP 的两套 socket 命名、`Android-Package` 认领、
  安装弹窗的 10 s 倒计时、`uiautomator dump` 的 idle-state 超时、IME 位移事故……）；命令本身的真机覆盖
  见[验证状态](#验证状态)，缺的部分欢迎按 [docs/verification.md](docs/verification.md) 补。
  踩坑记录提炼成 [`docs/recipes.md`](docs/recipes.md) 与 [`docs/redlines.md`](docs/redlines.md)。
- 本项目的前身是一组内部调试脚本与「设备适配校验」工具，整理成公开 CLI 时删掉了所有环境相关默认值，
  改成 `--serial` / `DV_*` / 占位符。
- CDP 部分只依赖 Node 原生 `WebSocket`，没有第三方包；`#!/usr/bin/env node` 脚本可以直接读。

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，变更见 [CHANGELOG.md](CHANGELOG.md)。
