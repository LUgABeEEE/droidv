# 红线

> 这四条都是**真机踩出来的**，不是风格偏好。踩一次的成本从「重连一遍」到「整台设备从网络消失」不等。
> 每条都给「别做什么 / 为什么 / 该做什么」。

---

## 1. 不要对无线调试的 transport 用 `adb reconnect`

**别做**

```bash
adb -s <device-ip>:<port> reconnect        # ✘
adb reconnect offline                      # ✘
```

**为什么**

无线调试的 transport 是「Wi-Fi + mDNS + 设备端守护进程」三者凑起来的。`reconnect` 会先把 transport 摘掉，
再指望设备端重新广播；而设备一息屏、或省电策略降了 Wi-Fi，就再也广播不出来：

- `adb devices` 空
- `adb connect <ip:port>` → `No route to host`
- `adb mdns services` 空
- 主机侧 `ip neigh` 对该 IP 显示 `FAILED`

现场还原：一次 `adb shell` 卡住 → 执行 `adb -s … reconnect` → 整台设备从网络消失，
只能等人把设备点亮、重新打开无线调试。

**该做**

1. 等 `dv` 自带的超时返回（`DV_ADB_TIMEOUT`，默认 30 s）—— CLI 不会跟着一起挂住；
2. `adb connect <ip>:<port>`（**端口可能已经变了**，去设备「无线调试」页面看）；
3. 还不行就请人看一眼设备：亮屏、Wi-Fi 在线、无线调试开着；
4. 需要重连时只重连**你指定的那一个**地址，不要动全局 transport。

---

## 2. 不要 `adb kill-server`

**别做**

```bash
adb kill-server        # ✘
```

**为什么**

- 重起的 daemon 可能拿不到 USB 设备节点权限，留下 `no permissions` 的假象，看起来像「设备坏了」；
- 会清掉**所有** `forward` / `reverse`（包括别的窗口正在用的）与全部无线连接；
- 在容器 / 沙箱里重起的 daemon 往往和原来不是同一个（USB 直通、udev 规则都可能不同）。

**该做**

`dv adb` 已经把这类命令列进**默认拒绝清单**（`reboot / root / remount / kill-server / reconnect / tcpip /
uninstall / settings put`），命中就 `exit 2`；确实需要时得显式 `--allow-danger`。

真觉得 server 状态脏，就**只清自己建的 forward**：

```bash
adb -s <serial> forward --remove tcp:9333
```

`dv cdp` 本来就会在**任何退出路径**（成功 / 失败 / 超时 / Ctrl-C）回收它自己建的 forward。

---

## 3. 全局选项必须写在子命令**之前**

**别做**

```bash
dv --pkg com.example.app shot --serial <serial>            # ✘ exit 2（--serial 是全局的）
dv --pkg com.example.app cycle --out /tmp/run              # ✘ exit 2（--out 是全局的）
dv --pkg com.example.app install --apk app-debug.apk --out /tmp   # ✘ exit 2（--out 是全局的）
```

**为什么**

`dv` 只把**第一个非选项参数之前**的选项当全局选项，之后的一律原样交给子命令。这样做的原因很实际：
`--pkg` 既是全局选项、又可能被某个子命令用不同语义解释；与其猜，不如**直接报错**——
`exit 2` 比「选项被静默忽略、命令跑在错的设备上」便宜太多。

**该做**

```bash
dv --pkg com.example.app --serial <serial> shot          # ✔
dv --pkg com.example.app --out /tmp/run cycle --no-cdp   # ✔
dv --pkg com.example.app.debug cdp report --json         # ✔
```

子命令自己的选项（`shot -n 3 -o DIR`、`uitree --find`、`cdp --port`）当然写在子命令之后。

---

## 4. 任何 `ime disable` 之前先 `dv ime snapshot`

**别做**

```bash
adb shell ime disable <id>          # ✘ 没有快照就禁
# 恢复时只 enable 默认那一个
adb shell ime enable <default-id>   # ✘ 另外几个还留在禁用状态
```

**为什么**

- 现场还原：为了把大小写混合的文本原样输进输入框，临时禁用了全部 4 个 IME；恢复时只 `ime enable`
  了默认那个，另外 3 个留在禁用状态 —— 用户后来报「键盘不见了」；
- **只禁一个**更糟：系统会自动切到另一个输入法，并弹出首启隐私弹窗（等于把 UI 树和焦点都换掉了）；
- 所以规则是**要么全禁、要么不动**，而「全禁」必须配快照。

**该做**

```bash
dv ime snapshot     # 存：启用列表 + 默认 IME + show_ime_with_hard_keyboard
# …做你的事…
dv ime restore      # 按快照逐个 ime enable + ime set 默认，然后回读校验
dv ime status       # 现状 + 快照是否一致（不一致 exit 6）
```

快照默认落在 `${XDG_CACHE_HOME:-~/.cache}/dv/ime-snapshot.json`（不可写时退化到 `$DV_OUT/`）。
`dv doctor` 也会做 IME 基线检查（启用数 < 2、或默认 IME 不在启用列表 → WARN + 修复提示），
但**只告警、绝不自动改设备**。

---

## 附：两条「看起来能省事、实际会误判」的

### A. release 包不能当 debug 包用

`setWebContentsDebuggingEnabled(BuildConfig.DEBUG)` 在 release 上是 `false` ⇒ 没有
`webview_devtools_remote_*` socket ⇒ `dv cdp` 必然 `exit 5`。这不是 bug，是签名配置的结果。
三条正路：装 `.debug` 变体（`dv --pkg com.example.app.debug cdp report`）/ App 侧加 console 桥 /
改走 UI 树（`dv uitree --marker …`）。

### B. 别把系统浏览器的 socket 当成被测 App

`browser_webview_devtools_remote_*` 是浏览器进程的 socket。`dv cdp` 用 `/json/version` 的
`Android-Package` 字段**认领**端点，不匹配就 `exit 6`；自己写脚本时也要做这一步，
否则「断言通过」可能是在测浏览器首页。
