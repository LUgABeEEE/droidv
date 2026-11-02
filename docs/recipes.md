# 10 条任务配方

> 约定：**全局选项（`--serial` / `--pkg` / `--out` / `--json`）写在子命令前**，子命令选项写在子命令后。
> 所有例子用占位符：`<serial>`（USB 序列号或 `<device-ip>:<port>`）、`com.example.app`（换成你的包名）。
> **需要包名的子命令**（`check` / `cdp` / `uitree` / `cycle` / `perf --gfxinfo`）必须带 `--pkg`——包名没有默认值，
> 不给会 `exit 2`；其余（`doctor` / `shot` / `logcat` / `crash` / `adb` / `build` / `ime` / `npu`）不需要。
> 每条给「命令 → 预期 → 失败怎么读」。退出码含义见 [README](../README.md#退出码)。

---

## R1 装 debug 包并取一次 CDP JSON

```bash
dv --pkg com.example.app.debug install --apk app-debug.apk
dv --pkg com.example.app.debug cdp report --json | jq '{pkg:.android_package, targets, fact}'
```

**预期**：`install` 打印耗时并复核 `pm list packages`；`cdp report` 的 `android_package` 必须以 `.debug` 结尾。

**失败**：`5` = 没有 devtools socket（多半装成 release 了 / App 没开 `WebContentsDebuggingEnabled`）；
`6` = forward 落到了系统浏览器（`Android-Package` 不匹配）。`install` 报 `6` + `USER_RESTRICTED` 见 R9。

---

## R2 量 44dp 触控目标（几何断言，不截图）

```bash
dv --pkg com.example.app cdp eval 'JSON.stringify([...document.querySelectorAll("button,[role=button],input,select,textarea")]
  .filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&Math.min(r.width,r.height)<44})
  .map(e=>{const r=e.getBoundingClientRect();return {t:(e.textContent||"").trim().slice(0,20),w:Math.round(r.width),h:Math.round(r.height)}}))'
```

**预期**：返回 JSON 数组，`[]` = 全部 ≥ 44。判据是**几何**，不是“看起来挺大”。

**没有 CDP 时**用 UI 树拿 `bounds` 现算（见 R4），**别写死坐标**：分辨率、字号、系统手势区都会漂。

> 为什么这么在意：真实项目里，「截图看着没问题」和「实际有 41 个触控目标 < 44dp」可以同时成立 ——
> 前者是人眼在 1× 缩略图上的判断，后者是 `getBoundingClientRect()` 的几何事实。

---

## R3 抓失败/崩溃现场（证据三件套 + 崩溃缓冲）

```bash
mkdir -p /tmp/fail
dv crash --json > /tmp/fail/crash.json          # crash 缓冲 + ANR + tombstone 可读性
dv shot -n 1 -o /tmp/fail
dv --pkg com.example.app uitree --json --dump-out /tmp/fail/ui.xml > /tmp/fail/uitree.json
dv doctor --json > /tmp/fail/doctor.json
```

**产出**：`crash.json`（崩溃缓冲/ANR/tombstone）+ `shot-*.png`（像素证据）+ `ui.xml`（可断言文本/bounds）
+ `doctor.json`（设备/焦点/IME 上下文）。一条命令版：`examples/logcat-crash.sh --pkg <pkg>`。

**失败时更要归档**：这三样是复盘最快的材料 —— 截图回答「长什么样」，UI 树回答「树里到底有什么」，
doctor 回答「当时设备是什么状态」。只留截图，等于只留了最不能断言的那一份。

---

## R4 release 包没有 CDP：走「页面文本 → UI 树回读」

```bash
dv --pkg com.example.app uitree --json --marker '[dvmeta:' --dump-out /tmp/cch.xml | jq '{nodes:.stats.nodes, texts:.stats.texts}'
```

**前提**：页面把结构化数据渲染成**可见文本节点**（分片 + 校验），并且只认 `text` 属性
（`aria-label` / `content-desc` 不进 `text`，要用 `--find` 单独匹配）。

**预期**：一次 dump 拿全（实测单页 61 KB、单节点 ≥262,144 字符无损）。

**失败**：`4` = dump 三次 + 重启轮询仍失败；`6` = marker 不在（页面没渲染完 / marker 选错了）。
注意 `nodes≈6` 是“页面还没渲染完”的典型指纹，不是 dump 坏了（见 R10）。

---

## R5 检查 NPU（只读枚举 → 需要时再跑 demo）

```bash
dv npu check --json | jq '{hal_lines, dev_nodes}'
dv npu run --apk ./npu-demo.apk        # 唯一有副作用的 npu 动作：会装 App
```

**预期**：多数设备 `hal_lines=0`、`/dev` 里只有 `*_freq_qos` 这类 QoS 旋钮（推理实际落 CPU）。
`check` 的用途是**复核这个结论**，不是「跑 NPU」。

**注意**：`run` 会装 demo 包（默认 `com.example.npuscout`，用 `DV_NPU_PKG` 换），跑完记得卸。
`check` 完全只读，可以随便跑。

---

## R6 换设备 / 换包名

```bash
dv --pkg com.example.app --serial <serial> check
DV_CONF=./phone.conf dv doctor
dv --pkg com.example.app.debug uitree --json --find "设置"
```

一台设备一份 conf，用 `DV_CONF` 切换：

```bash
cp conf.example pad.conf   && $EDITOR pad.conf     # CONF_SERIAL=<device-ip>:<port>
cp conf.example phone.conf && $EDITOR phone.conf
DV_CONF=./pad.conf   dv doctor
DV_CONF=./phone.conf dv doctor
```

**别把 IP 写进脚本**：无线调试端口每次可能变。写进脚本的 IP 过期后，`dv` 会给你一个 `exit 3`，
而你会以为是设备坏了。

---

## R7 批量跑多台设备并消费 `--json`

```bash
for s in <serial-a> <serial-b>; do
  dv --pkg com.example.app --serial "$s" cycle --json | jq -c --arg s "$s" '{serial:$s, ok, restart_ms, cdp_ok:(.cdp!=null), dir}'
done | tee /tmp/batch.jsonl

jq -s 'map(select(.ok|not)) | length' /tmp/batch.jsonl      # 失败台数
```

`--json` 一律**一行一个 JSON 对象**，可以直接 `jq` / 落 `jsonl`。
批量时**别用 `set -e`**：先收集所有结果再判定，否则第一台失败就看不到其余设备的状态。

---

## R8 排查「配对设备已达上限」

```bash
dv doctor --json | jq '.pair_device_count'
```

**前提**：设了 `DV_GATEWAY`（`doctor` 会去读 `<gateway>/api/mobile-access/lan/status` 的 `deviceCount`）。没设就是 `null`，这项直接跳过。

**读法**：`deviceCount` 逼近上限时，装 debug 包会被**对端**拒（不是 `adb` 拒），表现往往是
「装成功但连不上」这类次生症状。处置：在主机侧移除旧设备再重试 `dv --pkg … cdp report`。
`doctor` 会在数值 ≥ 32 时给黄色告警。

---

## R9 排查 `INSTALL_FAILED_USER_RESTRICTED`

```bash
dv install --apk app-debug.apk; echo "exit=$?"
```

**失败**：`6` + 提示「弹窗 10 s 内没点上」。按这个顺序查：

1. 屏幕**亮着且已解锁**（息屏时弹窗根本不渲染）；
2. 开发者选项里「USB 安装」/「通过 USB 安装应用」已开（部分 ROM 还要开「USB 调试（安全设置）」）；
3. 弹窗真的出现了 —— 弹窗存活期 `uiautomator dump` 返回 **0 字节**，所以只能按坐标点；
4. 换分辨率/方向就用**单个** `DV_INSTALL_TAP="x,y"`（或 `dv.conf` 的 `CONF_INSTALL_TAP`）给坐标——默认 `none`
   不自动点，弹窗出现后手点「继续安装」。参考值：横屏平板 3408×2272 实测 `1060,1224`（1.24 s 成功）、
   手机 1200×2608 可先试 `600,1800`，坐标越界会 `exit 2` 并报实际屏幕尺寸。

重试前先 `dv adb -- shell input keyevent 4` 关掉残留弹窗 —— **别**在弹窗活着时连点（会点到「拒绝」）。

---

## R10 等页面真的就绪，而不是 `sleep 10`

```bash
dv --pkg com.example.app wait-until --text "保存" --timeout 15
dv --pkg com.example.app wait-until --focus com.example.app --timeout 15 --json | jq '.last_state'
```

**预期**：命中即 `exit 0`（通常 < 1 s，省掉固定 sleep）；超时 `exit 4`，并打印「等了多久 / 最后一次观察到的
状态 / 排查建议」，`--json` 里是结构化的 `last_state`。

**为什么需要它（反例）**：以前这段是

```bash
sleep 10 && dv --pkg com.example.app uitree --json --verbose --dump-out /tmp/ui.xml | jq .stats
```

`sleep 10` 有两个坏处：页面 800 ms 就好了时白等 9 s；页面要 12 s 才好时照样 dump 到半成品
（`nodes≈6` = 页面还没渲染完的典型指纹，**不是 dump 坏了**）。`wait-until` 把「等」变成**有判据的等待**：
+ 页面动画不停 / 明显卡顿时，`uitree` 现在会**立即 `exit 4`**（约 50 ms，带 `reason=idle_timeout`），不再空耗 3×11 s；
+ 仍然想手看树时用 `dv --pkg com.example.app uitree --json --verbose --dump-out /tmp/ui.xml`，
  但记得 `nodes≈6` 说明的是「页面没就绪」，不是「工具坏了」。
