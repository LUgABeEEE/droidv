# 验证状态与「补验证」指南

> droidv 的真机覆盖**由社区补充**。这个仓库自己的无设备自测（`dv selftest`，79 项）能证明「代码路径没坏」，
> 但**不能**证明「在你的设备、你的 ROM、你的 App 上能跑」。所以每个子命令都标了状态（主机侧 / 真机 / 仅 selftest / 未验证），缺的那一栏欢迎你填。

---

## 1. 状态定义（不要含糊）

| 状态 | 含义 | 需要什么证据 |
|---|---|---|
| **主机侧已验证** | 命令不碰设备（如 `dv build`），在**真实工程/真实主机环境**跑过 | 工程类型 + 耗时 + 产物大小 + 日期 |
| **真机已验证** | 有人在**真实设备**上跑过这条命令，并留下了可核对的结果 | 设备型号 + 系统版本 + Android 版本 + transport（USB / 无线）+ 日期 + 命令 + 退出码 + 输出片段 |
| **仅 selftest** | 只在 `dv selftest` 的 fake-adb / 假 devtools 端点上跑过 | 不需要额外证据（`./dv selftest` 可复现），但**不等于**真机可用 |
| **未验证** | 命令还没落地，或从未被任何方式执行过 | — |

**判定原则**：

- `dv selftest` 全绿 **不** 能把某条命令升级为「真机已验证」；
- **碰设备的命令**不能写成「主机侧已验证」——`build` 是唯一的主机侧命令（它只跑 Gradle）；
- 「我看了一眼觉得没问题」不算证据，**退出码 + 输出片段**才算；
- 一条命令在 A 设备上通了，B 设备上仍可能是「仅 selftest」——表里按**命令**汇总，设备差异写在备注。

---

## 2. 当前状态（2026-11-02，随仓库更新）

| 命令 | 状态 | 依据 / 备注 |
|---|---|---|
| `doctor` / `check` / `devices` / `packages` / `ime` / `shot` / `uitree` / `wait-until` / `logcat` / `crash` / `perf` / `lock` / `npu` / `adb` | **真机已验证** | 2026-11-02 · Xiaomi 17 Pro Max（USB）+ Xiaomi Pad 9 Pro Max（无线调试）· Android 17 (SDK 37) / 澎湃 OS 4.0 · 成功路径与失败路径（`wait-until` 超时→4、`adb -- reboot` 被拒→2、`lock` 争用→3）；逐条退出码/耗时见 `selftest/LIVE-STATUS.md` |
| `cycle` | **真机已验证**（平板 `.debug`） | 两次 `exit 5`（无 CDP 时的正确结果）；产物齐全、`forward --list` 前后为空；手机未跑 |
| `build --variant debug` | **主机侧已验证** | 手机 6684 ms / 平板 7524 ms → 9.46 MB；`release` 无签名 → `exit 6`（不需要设备） |
| `install` | 有条件已验证（平板） | 默认 `DV_INSTALL_TAP=none` 不自动点；显式 `DV_INSTALL_TAP="1060,1224"` → **1.24 s 成功**；手机坐标未量 |
| `input` | 真机已验证（`tap` + 失败路径） | 平板 `input tap --text 局域网访问` → 0（打印 px/css/dpr=2.5）；找不到文本 → 4；`text 中文` → 2 |
| `cdp` | **历史已验证 / 今日未复跑** | 历史：t7 三段全通（socket + `/json/version` + WS `Runtime.evaluate`）；今日两侧因**配对需人参与**未复跑；release 包 `cdp version` 正确 `exit 5` |
| `input text <ASCII>` 正向输入到真实会话 | 未验证 | 今日页面没有输入框（旧版假成功，现已改为无输入框 → `exit 4`） |
| `build --install`（手机） | 未验证 | 平板已验证（复用同一安装路径） |
| `--retry` | 未验证 | 只对 `4`/`6` 生效；真机只跑过一次「无 flaky」 |

`dv help` 与 `dv selftest` 不需要设备，不参与状态判定。

> 截至本次发布：真机覆盖为 **2026-11-02 两台设备（Xiaomi 17 Pro Max / Pad 9 Pro Max，Android 17 / 澎湃 OS 4.0）**
> 的 55 条实跑记录。凡是当天跑过的都标「真机已验证」并注明设备与日期；**CDP 只标历史已验证**（今日配对需人参与，
> 未复跑），`input text` 正向输入与手机上的 `build --install` 仍标未验证。

---

## 3. 怎么补一条验证（给外部贡献者）

### 3.1 准备

```bash
git clone <repo-url> droidv && cd droidv
export DV_ADB="$ANDROID_HOME/platform-tools/adb"     # 或 --adb
adb devices                                          # 确认设备在线（USB 或无线）
./dv selftest                                        # 先确认工具本身没坏（79 项，约 36 s）
```

需要 debug 包的场景（`cdp` / `install` / `cycle`）请用**你自己的 App** 或任意开源 demo App；
本仓库不带私有 APK。

### 3.2 跑哪几条

按你想补的命令跑，**一条也行**（表里逐命令汇总）。推荐的最小集合：

```bash
dv doctor --json
dv --pkg <your.package> check --json
dv --pkg <your.package> shot -n 1 -o /tmp/v
dv --pkg <your.package> uitree --json --dump-out /tmp/v/ui.xml
dv --pkg <your.package> logcat -n 20 --json
dv crash --json
```

带设备状态改动的命令（`install` / `npu run` / `ime restore` / `adb --allow-danger`）请只在你**自己的设备**上跑，
并顺手跑一遍 `dv ime snapshot` 留底。

### 3.3 交什么（缺一项就可能被退回）

一段可以直接贴进 issue/PR 的文本，包含：

1. **环境**：设备型号（可写通用说法）、系统版本（HyperOS/One UI/…）、Android 版本 + SDK、transport（USB/无线）、日期；
2. **命令**：原样可复制（含 `--pkg` 等参数）；
3. **退出码**：`echo $?` 的结果；
4. **输出片段**：关键行即可（建议 10–30 行），不要贴整篇；
5. （可选）`dv doctor --json` 的输出——它一次说清 adb/设备/版本/焦点/IME 基线。

模板：

```markdown
### `dv <command>` — 真机验证

- 设备：<厂商> <型号>（通用说法即可，**不要**写内部代号）
- 系统：<HyperOS 3 / One UI 7 / …> / Android <版本> (SDK <n>)
- transport：USB / 无线调试（<device-ip>:<port> 已脱敏）
- 日期：2026-11-02
- 命令：`dv --pkg com.example.app <subcommand> …`
- 退出码：0

```
<10–30 行输出片段，已脱敏>
```
```

### 3.4 怎么脱敏（提交前自检）

| 要删/替换 | 换成 |
|---|---|
| 设备序列号（15 位数字 / USB 序列号） | `<serial>` |
| 局域网 IP / 无线调试地址 | `192.0.2.10:<port>`（RFC5737 文档地址）或 `<device-ip>` |
| 设备内部代号（`ro.product.device` 之类） | 不写；只写市场型号的通用说法 |
| 包名 / App 名（若为私有项目） | `com.example.app` |
| token / 配对码 / 密码 / 密钥 | **绝对不要贴**，删掉 |
| 本机绝对路径（`/home/<you>/…`） | `$HOME/…` 或 `~/…` |

自检（在你要提交的片段/文件上跑）：

```bash
grep -nE "192\.168\.|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.|[0-9]{15}|/home/[a-z]|/Users/[A-Za-z]" your-log.txt
```

### 3.5 提到哪里

- **PR**：改本文件 §2 的表格（把对应行从「仅 selftest」改成「真机已验证」，并在备注里写设备/日期），
  同时把 §3.3 模板那段贴进 PR 描述（或作为 `docs/verification-logs/<命令>-<设备>-<日期>.log` 落盘，脱敏后）。
- **Issue**：不想开 PR 就开 issue，标题写 `verify: dv <command> on <device>`，正文用 §3.3 模板；
  维护者会把结论回填进表格。
- 一次只补一条命令最容易合并；不要顺手改代码（行为问题请单独开 issue，附复现命令与退出码）。

### 3.6 会被拒的情况

- 只有「跑通了」没有退出码/输出片段；
- 贴了未脱敏的序列号、内网 IP、配对码；
- 用 `dv selftest` 的通过当作真机证据；
- 在别人的设备/生产环境上跑破坏性命令（`adb --allow-danger`、`npu run` 装包等）而没有说明。

---

## 4. 维护者怎么回填

1. 合并 PR 后把 §2 对应行改成「真机已验证」，备注写「设备族 + 系统 + Android 版本 + 日期」；
2. 若某设备上失败：保留「仅 selftest」，在 `docs/redlines.md` 或 issue 里记录失败退出码与现场，
   **不要**为了让表格变绿而改判定口径；
3. 命令新增/删除时同步这张表（Release 前由维护者按发布流程核对一遍）。
