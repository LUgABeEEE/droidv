# 贡献指南

## 先跑自测

不需要真机，也不需要 Android SDK 之外的任何东西（`python3` + `node` ≥ 18 即可）：

```bash
./dv selftest            # 期望 79 项全 PASS（约 36 s），exit 0
./dv selftest --verbose  # 失败时附 stderr
bash -n dv lib/*.sh      # 语法检查（回归前先过这一步）
```

自测靠 `selftest/fake-adb`（假 adb：可注入 `uiautomator dump` 失败次数、伪造 forward 的 ADD/REMOVE、
伪造 IME 状态）与 `selftest/fake-devtools.py`（假 `/json/version`、`/json/list`、最小 WebSocket）。
**新加的失败路径必须有对应的假 adb 分支 + 一条断言**。

## 补一条真机验证（最受欢迎的贡献）

不需要改代码：在你的设备上跑一条命令，按 [docs/verification.md](docs/verification.md) 的模板交「设备 + 系统 +
transport + 命令 + 退出码 + 输出片段（已脱敏）」，就能把 [`README.md`](README.md#验证状态) 里对应行从
「仅 selftest」升级为「真机已验证」（`dv build` 这类不碰设备的命令走「主机侧已验证」，不能算真机验证）。

规则只有一条：**`dv selftest` 全绿不等于真机可用**，不要把「仅 selftest」改成「已验证」。

## 目录约定

```
dv                 # 唯一入口：解析全局选项 → source lib/<子命令>.sh → 调用 dv_cmd_<子命令>
lib/common.sh      # 配置优先级 / 颜色 / 退出码 / adb 封装 / 设备发现 / JSON 工具
lib/<cmd>.sh       # 每个子命令一个文件，导出 dv_help_<cmd> 与 dv_cmd_<cmd>
                   #   20 个：doctor check install cdp shot uitree wait-until cycle logcat crash perf
                   #         adb input lock build ime npu packages devices selftest
lib/cdp-eval.mjs   # CDP WebSocket 求值（零依赖）
examples/          # 可直接跑的示例脚本
docs/              # 配方与红线（不是设计文档）
selftest/          # fake adb / 假 devtools / 真机实跑脚本
docs/              # 配方 / 红线 / 验证状态与补验证指南（verification.md）
```

## 改代码时请守住

1. **不改退出码语义**：`0` 成功 · `1` 仅 selftest 有断言失败 · `2` 参数错 · `3` 无设备 ·
   `4` 取数失败 · `5` 通道不可用 · `6` 校验失败 · `7` 环境缺失 · `8` 仅 `dv build` 构建失败。
   新增场景先想清楚该归哪一类，不要发明 `9`。
2. **`--json` 一行一个对象**，字段名不要随手改（有人拿它写 CI）；要加字段就往后加。
3. **任何 forward 都要回收**：`trap … EXIT INT TERM`，成功、失败、超时三条路径都要。自测里有断言锁这个行为。
4. **不要引入 `adb reconnect` / `kill-server`**（见 [`docs/redlines.md`](docs/redlines.md)）。
5. **不要在代码里写死 IP / 端口 / 序列号 / 本机绝对路径**：一律走 `--serial` / `DV_*` / `dv.conf` / mdns 自动发现。
6. **不要提交凭据**：`dv` 不读 token、密码、配对码；示例与文档里也不要出现。
7. **帮助文案与实现同步**：`dv help <cmd>` 就是唯一真源，README 抄它；改了选项顺手改 `dv_help_<cmd>`。

## 提交

- 一个提交做一件事；标题用英文祈使句（`add dv perf`、`fix forward leak on claim failure`）。
- 附「怎么验证的」：`./dv selftest` 结果、（如果有真机）跑过哪几条命令、退出码。
- 不要在同一个提交里混「文档重排」和「行为改动」。
