# droidv

**A CLI for Android device debugging that replaces screenshot-reading with assertions.**

One `dv` command for the grunt work of developer-mode debugging: installing debug builds past the system
installer dialog, WebView CDP assertions, native UI-tree dumps, conditional waiting (`wait-until`),
screenshots, structured logcat, crash forensics (crash buffer + ANR + tombstones), frame stats,
**node-targeted input injection** (`input tap --text`), a **cross-process device lock** (`lock`), IME
snapshots, NNAPI enumeration, Gradle builds, package/device inventories, and a device-free self-test.
Plain bash (small amounts of `python3` / `node`), no install step, no system paths touched, no `PATH` / rc edits.

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version](https://img.shields.io/badge/version-0.1.0-informational.svg)](CHANGELOG.md)
[![shell](https://img.shields.io/badge/shell-bash%204%2B-89e051.svg)](#install)
[![node](https://img.shields.io/badge/node-%E2%89%A522-339933.svg)](#install)

> **Real-device coverage is contributed by the community** — see [verification status](#verification-status) for
> where each command stands, and [docs/verification.md](docs/verification.md) for how to add a row.
>
> 中文主 README → [README.md](README.md)

---

## What it is

`dv` turns "change one line → take a look on the device" from **a human reading a screenshot** into
**a machine-checkable assertion**:

```bash
dv --pkg com.example.app cdp eval 'document.querySelectorAll("button").length'   # 177 ms, a fact
dv shot -n 1                                                                    # 515 ms, pixels
```

It is not a device farm and not a test framework — it is the screwdriver you reach for *while debugging*.
Every subcommand exists because of a real-world failure mode, and every failure mode has a fixed exit code.
(Where the tool itself has actually run on hardware is listed in [verification status](#verification-status) —
anything not listed there is marked "selftest only".)

- Target: Android 11+ (validated mainly on **Android 17 / HyperOS 4**: installer dialogs, wireless debugging,
  WebView CDP)
- Command: `dv` (project name `droidv`; the repo *is* the tool)
- Deps: `bash 4+`, `adb`, `python3`; `dv cdp` also needs `node ≥ 22` (native `WebSocket`) and `curl`
- Not for: multi-device orchestration, flow DSLs, record/replay, a bundled MCP server
  (see [deliberately out of scope](#deliberately-out-of-scope))

---

## Why: 515 ms screenshot + 5–20 s of human reading vs a 177 ms assertion

Same machine, same Wi-Fi, same page, two channels:

| Channel | Cost per call | Who judges | CI-able |
|---|---|---|---|
| `adb exec-out screencap -p` | **515 ms** (Wi-Fi) / 0.51 s (USB) | **a human** (or a vision model) | ✘ 5–20 s of reading per round, not retryable |
| CDP `Runtime.evaluate` | **177 ms** (Wi-Fi, in-app) | **code** (DOM / geometry / text) | ✔ reproducible, retryable |

> Numbers come from publicly reproducible on-device measurements (Wi-Fi transport, same page and session;
> cold start and pairing excluded). Scope note: these are **channel timings taken with a standalone script**,
> not `dv`'s own timings — see [verification status](#verification-status) for what `dv` itself has run.
> Caveat: over USB the CDP round-trip can be as low as 43 ms — **never compare figures across transports**.

Per-round budget for "edit → see result":

| Approach | Per round |
|---|---|
| headless (no device) | ~12.5 s |
| real-device screenshots (restart + wait + shot + **human read**) | **~30–40 s** (5–20 s of it is reading) |
| **dv: five CDP assertions** | **≈0.9 s** (177 ms × 5) |
| dv: five assertions + one screenshot for the record | ≈1.4 s |

The conclusion is blunt: **a screenshot is evidence, not a verdict.** Verdicts need a channel that returns
a value (CDP DOM/geometry, or UI-tree text/bounds); keep screenshots for archiving, eyeballing and visual
regression corpora.

---

## Install

There is nothing to install — clone and run:

```bash
git clone <repo-url> droidv
cd droidv
./dv help
```

<sub>(`<repo-url>` becomes the real URL once the repository is published; the project ships as a source tree, no package manager.)</sub>

| Dependency | Used for | When missing |
|---|---|---|
| `adb` | every device operation | exit **7** (`--adb` / `DV_ADB` / `CONF_ADB`; default lookup: `$ANDROID_HOME/platform-tools/adb`, then `adb` on `PATH`) |
| `python3` | JSON assembly/escaping, UI-tree parsing, CDP package claiming | **exit 7** (checked at startup for every subcommand except `dv help`) |
| `node ≥ 22` | `dv cdp eval` / `report` (needs the global `WebSocket`; Node 18/20 lacks it) | exit **7** (`typeof WebSocket` is probed before use) |
| `curl` | `dv cdp` fetching `/json/version` · `/json/list` | exit **7** (checked on the cdp path only) |
| JDK + Android SDK | `dv build` only | exit **7** |

> **Prerequisite: only these paths force a package** — `cdp eval|report`, `cycle`, `uitree --restart-app`,
> `wait-until --expr` (the cases where dv must know "is this your app?"). They read the global `--pkg`
> (or `DV_PKG` / `CONF_PKG`); without one they exit `2` and print how to set it. `dv packages --filter …`
> lists what is installed.
> **Not forced** (they take their own argument or fall back to `DV_PKG`): `cdp version|list`, bare `uitree`,
> `wait-until --text/--focus/--shell/--pkg-visible`, `perf --gfxinfo <pkg>`, `logcat --pkg <pkg>`,
> `input`, and `check` (it only reports connection/focus, it does not validate the package).
> No package at all: `doctor` / `shot` / `crash` / `adb` / `build` / `ime` / `npu` / `devices` / `packages` / `lock`.
>
> `dv help` and `dv selftest` work **without adb** (adb is resolved lazily, only when a command needs it);
> every other subcommand exits **7** when adb is missing.

---

## Five-minute quickstart

**① Health check** (does not need a package name)

```bash
dv doctor
```

```
dv doctor  (v0.1.1)
────────────────────────────────────────────
✔ adb        /opt/android-sdk/platform-tools/adb  (v1.0.41)
✔ 设备       <device-ip>:<port>
             model=<model>  Android 17 (SDK 37)  HyperOS OS4.0
             包未指定（用 --pkg / DV_PKG / dv.conf 指定后才检查安装状态）
             配对配额未检查（未配置 DV_GATEWAY）
✔ 悬挂 forward 无
! 焦点       mCurrentFocusedWindow = com.android.systemui（不是 com.example.app）
✔ IME        3 个启用，默认 com.example.ime/.Service
```

**② Connect a device** (USB or wireless)

```bash
adb devices                          # USB: plug in and authorize on the device
adb pair <device-ip>:<pair-port>     # wireless: Settings → Developer options → Wireless debugging (port changes)
adb connect <device-ip>:<port>
dv devices --json | jq '.[] | {serial, state, model}'   # what dv sees
```

**③ Run the full loop**

```bash
dv --pkg com.example.app cycle
ls dv-out/cycle-*/     # cdp.json / shot.json / uitree.json / ui.xml / shot-*.png
```

**④ Switch to assertions**

```bash
dv --pkg com.example.app cdp eval 'document.title'
dv --pkg com.example.app cdp report --json | jq '{url:.fact, targets}'
examples/cdp-assert.sh --pkg com.example.app --find "Save" --max-small 0   # text present + no tap target < 44dp
```

**⑤ Logs and crash scenes**

```bash
dv --pkg com.example.app logcat -n 50 --level E        # errors and what follows
dv --pkg com.example.app logcat --crash --json | jq '.lines'
dv crash --json | jq '{crash_lines, anr, tombstones_readable}'
examples/logcat-crash.sh --pkg com.example.app          # one-command bundle: crash block + screenshot + UI tree
```

**⑥ Stop gambling with `sleep 10`**

```bash
dv --pkg com.example.app wait-until --text "Save" --timeout 15   # returns on hit (<1 s), exit 4 with state on timeout
dv --pkg com.example.app wait-until --focus com.example.app --json | jq '.last_state'
dv packages --filter example                                      # forgot the package name?
dv --pkg com.example.app input tap --text "Save"                   # coordinates computed from the tree
```

**⑦ Self-test** (no device required)

```bash
./dv selftest          # 79 assertions, ~36 s, exit 0
```

---

## Commands

20 subcommands, all implemented (nothing "planned" below).

### Observe (most used: look before you change)

| Command | Purpose |
|---|---|
| `dv check [--json]` | connection check: `devices -l` + model / Android / SDK / OS version + WebView + focus (**needs a package**) |
| `dv doctor [--json] [--print-config]` | environment self-check: adb / device / versions / package / pairing quota (needs `DV_GATEWAY`) / dangling forwards / focus / IME baseline. `--print-config` prints effective values **with their source** (cli/env/conf/auto) and touches no device. **No package needed** |
| `dv devices [--json]` | device inventory: serial / state / model / `product:device` / transport / usb-or-tcp; **no online device → `exit 3`** with USB/wireless hints |
| `dv packages [--filter SUBSTR] [--third-party] [--json]` | installed packages; `--third-party` limits to user apps. **Run this first when you forgot the package name** |
| `dv shot [-n N] [-o DIR] [--json]` | screenshot archiving with per-shot timing |
| `dv uitree [--marker M] [--find TEXT] [--json] [--dump-out FILE] [--timeout N]` | native UI tree: `rm → dump → 3-part validation → retry → restart polling`; an `idle-state` failure now **exits 4 immediately** (~50 ms instead of 3×11 s) |
| `dv wait-until <--text T\|--focus PKG\|--expr JS\|--shell CMD\|--pkg-visible PKG> [--timeout N] [--interval S] [--json]` | **conditional waiting**: hit → `exit 0`; timeout → `exit 4` with "how long / last observed state / what to check" (`last_state` in `--json`) |
| `dv cycle [--json] [--no-cdp]` | restart → CDP → screenshot → UI tree → archive into `cycle-<ts>/` |
| `dv logcat [--pkg P] [--pid N] [--tag T] [--level V\|D\|I\|W\|E] [-n N] [--since T] [--crash] [--json] [--follow [secs]]` | structured logs, one JSON object per line, bounded follow mode |
| `dv crash [-n N] [--json]` | crash buffer + ANR summary + `/data/tombstones` availability (unreadable is reported, not an error) |
| `dv perf --gfxinfo <pkg> [--json]` / `dv perf --record <secs> [-o DIR]` | frame stats (total/janky/p50/p90/p95/p99) or a bounded screen recording pulled back |

### Drive (mutates device state — mind the red lines)

| Command | Purpose |
|---|---|
| `dv cdp version\|list\|eval '<js>'\|report [--json]` | WebView CDP: auto-forward + `Android-Package` claiming + **forward reclaimed on every exit path** (Ctrl-C reclaims, then `exit 130`) |
| `dv install [--apk PATH] [--json]` | install an APK. **The installer dialog is not auto-tapped by default** (`DV_INSTALL_TAP=none`): tap "Continue install" yourself; give coordinates explicitly to automate it (see [installer dialog](#installer-dialog-not-auto-tapped-by-default)). Timeout → `USER_RESTRICTED` (`exit 6`); `--json`'s `installed` is decided **by the package name inside the APK**, never by `--pkg` |
| `dv input tap (--text T\|--desc D\|--xy X,Y) [--index N]` / `dv input swipe --from X1,Y1 --to X2,Y2 [--ms N]` / `dv input text <ASCII>` / `dv input key <KEYCODE\|name>` | **locate a node, then tap / swipe / type / press a key**: coordinates are computed from the UI tree (prints px + css + dpr) instead of hardcoding `846 2002`; `text` accepts **pure ASCII only** and exits `2` with three workarounds otherwise; `key` takes 13 names (`BACK/HOME/ENTER/TAB/DEL/MENU/APP_SWITCH/SPACE/ESC/WAKEUP/POWER/VOLUME_*`) or raw keycodes |
| `dv lock acquire <name> [TTL=900]` / `release` / `status [--json]` | **cross-process device lock** (`~/.cache/dv/lock-<serial>`, one per device): held by someone else → `exit 3` printing holder + pid + acquired-at + remaining seconds; TTL expires automatically so a crashed session cannot wedge the device |
| `dv adb [--timeout N] [--allow-danger] -- <adb args…>` | adb passthrough with automatic `-s` and a hard timeout; **dangerous commands are refused by default** (reboot/root/remount/kill-server/reconnect/tcpip/uninstall/settings put) |

### Build

| Command | Purpose |
|---|---|
| `dv build [--project DIR] [--variant debug\|release] [--flavor NAME] [--install] [--offline] [--json]` | build an APK from any Gradle project (walks up to find `gradlew`, max 8 levels), optionally install it. Measured: debug build **7524 ms → 9.46 MB**. A `release` variant without `signingConfig` fails fast with `exit 6`; build failure is always `exit 8` |

### Maintain

| Command | Purpose |
|---|---|
| `dv ime snapshot\|restore\|status [--json]` | IME snapshot / restore (**adds missing *and* disables IMEs absent from the snapshot**, read-back verified, `exit 6` on mismatch) / status. Always snapshot before `ime disable` |
| `dv npu check\|run [--apk PATH]` | NNAPI / NPU: `check` is read-only (four independent probes, no more false negatives), `run` installs and runs a demo |
| `dv selftest [--verbose]` | device-free self-test (fake adb + fake devtools), **79 assertions** (~36 s) |
| `dv help [子命令]` | help — **the source of truth for per-command options and exit codes** |

Global options (**must precede the subcommand**):

```
--serial <S>  --pkg <P>  --adb <PATH>  --out <DIR>  --json  --verbose  --retry N  --no-color
```

- `--retry N` retries failures **only for `4` (data failure) and `6` (verification failure)**; with `--json` it
  emits an extra `{"phase":"retry","attempts":N,"outcome":"flaky|failed"}` line.
- `--verbose` echoes the actual adb commands to stderr.

---

## Verification status

State definitions (host-side / on-device / selftest-only / unverified), the contribution flow and the sanitisation
rules live in **[docs/verification.md](docs/verification.md)**. In one line: a green `dv selftest` does **not** mean
"works on a device"; only "device + OS + transport + command + exit code + output excerpt" does.

**Real-device run on 2026-11-02**: Xiaomi 17 Pro Max (USB, 1200×2608 @480dpi → DPR 3.0) and Xiaomi Pad 9 Pro Max
(wireless debugging, 2272×3408 @400dpi → DPR 2.5), both **Android 17 (SDK 37) / HyperOS 4.0**.
Per-command exit codes, timings and raw stderr: [`selftest/LIVE-STATUS.md`](selftest/LIVE-STATUS.md) (29 phone + 26 tablet entries).

| Command | Status | Basis / note |
|---|---|---|
| `doctor` / `check` / `devices` / `packages` / `ime` / `shot` / `uitree` / `wait-until` / `logcat` / `crash` / `perf` / `lock` / `npu` / `adb` | **verified on device** | 2026-11-02, both devices above; success **and** failure paths (`wait-until` timeout → 4; `adb -- reboot` refused → 2; `lock` contention → 3) |
| `cycle` | **verified on device** (tablet, `.debug`) | two runs `exit 5` (correct without CDP), all artifacts present, `forward --list` empty before/after (no leak); not run on the phone |
| `build --variant debug` | **verified on device** (host-side behaviour, no device needed) | phone 6684 ms, tablet 7524 ms → 9.46 MB; `release` without signing → `exit 6` |
| `install` | conditionally verified (tablet) | default `DV_INSTALL_TAP=none` does not tap; explicit `DV_INSTALL_TAP="1060,1224"` (landscape 3408×2272) → **1.24 s success**; phone coordinates not measured |
| `input` | verified on device (`tap` path + failure paths) | tablet `input tap --text 局域网访问` → 0, printed `(1704,528) px = (681.6,211.2) css [dpr=2.5]`; missing text → 4; `text 中文` → 2 |
| `cdp` | **verified historically / not re-run today** | historically t7 passed all three legs (socket + `/json/version` + WS `Runtime.evaluate`, Android 17 / wireless debugging); **not re-run today because pairing needs a human**; on release builds `cdp version` correctly exits `5` |
| `input text <ASCII>` into a real session | unverified | today the page had no input field (the old build faked success; it now exits `4` when nothing is focused) |
| `build --install` on the phone | unverified | verified on the tablet (`--install` reuses the same install path) |
| `--retry` | unverified | only applies to `4`/`6`; one real-device run produced no flake, so the retry path was not exercised |

> This table only records "who ran what, on which device". **Never** turn "unverified" into "verified" to make the
> table look better; to add a row, follow the template in `docs/verification.md` (device + OS + transport + date +
> command + exit code + 10–30 lines of output).

---

## Exit codes

Fixed, so scripts branch on the code instead of parsing prose. `1` is reserved for a failing self-test,
`8` for `dv build` only.

| Code | Meaning | Typical cause |
|---|---|---|
| `0` | success | |
| `1` | **only** a failing assertion inside `dv selftest` (nothing else uses `1`) | self-test regression |
| `2` | bad arguments | unknown subcommand/option, option missing its value, `-n abc`, **global option after the subcommand**, multiple devices unspecified, non-ASCII `input text` |
| `3` | no device / lock taken | `adb devices` empty and mdns finds nothing; explicit serial unreachable; `dv lock acquire` when someone else holds it |
| `4` | data failure after retries | `uitree` retries exhausted or `idle-state` fast-fail; `wait-until` timeout; screenshot < 1000 B; `adb` timeout |
| `5` | channel unavailable | no devtools socket, forward failure, non-200 HTTP, `cdp eval` timeout |
| `6` | verification failed | `Android-Package` mismatch, XML missing marker/package, install rejected (`USER_RESTRICTED`), APK not found, `release` produced only an unsigned artifact |
| `7` | environment missing | adb missing (except `help`), `python3` / `node ≥ 22` / `curl` / JDK / Android SDK missing |
| `8` | **build failure** (`dv build` only) | Gradle returned non-zero |

`--json` always prints **one JSON object per line** — pipe it into `jq`, append to `jsonl`.

---

## Ten recipes

Full versions (expected output, how to read failures) in [`docs/recipes.md`](docs/recipes.md).

| # | Scenario | One-liner |
|---|---|---|
| R1 | install a debug build and grab CDP JSON | `dv --pkg <pkg>.debug install --apk app-debug.apk && dv --pkg <pkg>.debug cdp report --json` |
| R2 | measure 44dp tap targets (geometry) | `dv --pkg com.example.app cdp eval '<JS collecting elements < 44dp>'` |
| R3 | capture a failure/crash scene | `dv crash --json` + `dv shot` + `dv --pkg com.example.app uitree --dump-out` |
| R4 | no CDP on release builds → read the UI tree | `dv --pkg com.example.app uitree --json --marker '[dvmeta:' --dump-out /tmp/cch.xml` |
| R5 | inspect NPU (read-only) | `dv npu check --json \| jq '{hal_lines,dev_nodes}'` |
| R6 | switch device / package | `dv --pkg com.example.app --serial <serial> check` · `DV_CONF=./phone.conf dv doctor` |
| R7 | batch several devices, consume JSON | `for s in <a> <b>; do dv --pkg com.example.app --serial "$s" cycle --json; done \| tee batch.jsonl` |
| R8 | "too many paired devices" | `dv doctor --json \| jq .pair_device_count` (needs `DV_GATEWAY`) |
| R9 | `INSTALL_FAILED_USER_RESTRICTED` | `dv install --apk app-debug.apk; echo "exit=$?"` |
| R10 | wait for the page to be ready (stop sleeping) | `dv --pkg com.example.app wait-until --text "Save" --timeout 15` |

---

## Red lines

Full versions (incident write-ups) in [`docs/redlines.md`](docs/redlines.md).

1. **Never `adb reconnect` a wireless transport.** It tears the transport down; combined with screen-off /
   Wi-Fi power saving the device can vanish from the network (`No route to host`, empty mdns) until a human
   wakes it and re-enables wireless debugging.
2. **Never `adb kill-server`.** The restarted daemon may lack USB permissions and it drops every
   forward/reverse plus all wireless connections.
3. **Global options go before the subcommand.** After it, you get `exit 2` — cheaper than silently running
   against the wrong device.
4. **Always `dv ime snapshot` before any `ime disable`.** Restoring only the default IME leaves the others
   disabled; disabling a single IME triggers an automatic switch plus a first-run privacy dialog. `dv ime restore`
   adds missing IMEs **and** disables extras, then read-back verifies (`exit 6` on mismatch).

Also: **release builds have no CDP** (no devtools socket → `dv cdp` exits `5`), and **never mistake the
system browser's socket for your app** (`dv cdp` claims endpoints via `Android-Package`, else `6`).
`dv adb` refuses the dangerous subset by default; `--allow-danger` is an explicit, logged decision.

---

## How it compares

| | **droidv (`dv`)** | raw adb scripts | uiautomator / Espresso | Appium / uiautomator2 / Maestro | scrcpy |
|---|---|---|---|---|---|
| Shape | one CLI, no server | you write it | test APK / instrumentation | server + driver, heavy stack | live mirror/control |
| Verdict from | **CDP assertions (DOM/geometry) + UI-tree text/bounds** | adb text parsing | view/accessibility tree | element locators + assertions | human eyes |
| Cost per check | **~177 ms** (CDP) / 1–3 s (UI dump) | depends | fast (in-process) | slow (extra HTTP/WS hop) | real-time, human-bound |
| Deps | bash + adb + python3 (+node/curl for cdp) | adb | Android SDK + build | Python/Node + server + driver | server jar |
| Setup | **zero** | zero | medium | high | low |
| Best at | **debug loop: verify once, grab the scene, keep evidence** | one-off poking | in-app test suites | cross-app E2E smoke | anything a human must watch |
| Not for | cross-app orchestration, device farms | long-term maintenance | other apps / WebView content | single fast checks (startup dominates) | automated verdicts |

**Choosing**: during debugging use `dv` (fast verdict, complete scene); for long-term regression wrap it in
your test framework; for cross-app orchestration reach for Appium / Maestro — their startup cost does not buy
back speed here.

> Honest labelling: the Appium / uiautomator2 / Maestro / Espresso column is **not measured on this machine** —
> it is engineering common sense for sizing. The adb/CDP numbers are reproducible on-device measurements;
> where `dv` itself stands is in [verification status](#verification-status).

### Related work

droidv is not another UI test framework; it is a **narrow CLI for the "change once, verify once" loop**.
Appium covers every platform through W3C sessions and pluggable drivers; uiautomator2 ships a device-side
agent with the friendliest Python selectors; Maestro writes flows as readable YAML; mobile-mcp slices actions
into fine-grained tools for LLMs. What they share: **you install something, you run a service, and the
assertion is left to the layer above**.

droidv picks the opposite end: **assertion first** (`dv cdp eval` / `dv uitree --find` judge page facts
directly, and the exit code *is* the verdict: `0/2/3/4/5/6/7/8`), **zero third-party dependencies** (plain
bash + an existing `adb`, optional `node` / `python3` / `curl`; no agent, no server), and **a single-file CLI**
(copy `dv` anywhere, it runs; no `PATH` edits, no rc edits, no system directories).

It does **not** do device farms, record/replay, or sharded test runs: call scrcpy / Appium / SoloPi as
separate programs when you need them. droidv fills the one gap none of them specialises in — **getting
judgeable, archivable, reproducible evidence out of a real device in one command**.

Inspired by (design only, no code copied): pidcat (logcat UX), scrcpy (device selection / server push),
uiautomator2 (waiting model), mobile-mcp (tool granularity), adbkit (error model).

### License boundaries

This repository is **MIT** and vendors no GPL / custom-licensed code: it only shells out to independent
programs (`adb`, optionally `scrcpy` / `gradlew`), which is "aggregation of independent programs" and does not
trigger copyleft.

| License | Projects (examples) | Copy code? |
|---|---|---|
| GPL-2.0 | Marathon | ❌ No (read the design, or call it as a separate process) |
| Custom, non-OSI | Fastbot (Fastbot Revised License) | ❌ No (treat as read-only) |
| Apache-2.0 | scrcpy, Appium, Maestro, Airtest, STF, Flank, mobile-mcp, pidcat | ✅ Borrow ideas; if you paste snippets, keep notices (add `NOTICE` if needed) |
| MIT | uiautomator2, DroidBot, droidv itself | ✅ Keep the copyright notice |

If an Apache-2.0 snippet is ever pasted in: add a root `NOTICE` with source file + copyright line +
"modified". Never bundle Marathon's jar, and never vendor GPL code.

---

## Configuration

Precedence: **command line > `DV_*` env > `dv.conf` > auto-detection**.

```bash
cp conf.example dv.conf && $EDITOR dv.conf    # every key is an optional default; dv reads no credentials
```

Common environment variables:

| Variable | Effect |
|---|---|
| `DV_SERIAL` / `DV_PKG` / `DV_ADB` / `DV_OUT` / `DV_ACTIVITY` | same as `--serial` / `--pkg` / `--adb` / `--out` |
| `DV_FORWARD_PORT` | local CDP forward port (default 9333; auto-increments when busy) |
| `DV_ADB_TIMEOUT` | per adb call timeout (default 30 s; keeps the CLI alive when the device hangs) |
| `DV_TIMEOUT` | timeout budget (default 30 s): `uitree` retry/reboot/poll counts derive from it (retry=/15, boot=/4 rounded up, poll=/10) |
| `DV_LOCK_FILE` | overrides the `dv lock` file; default is **`~/.cache/dv/lock-<serial>`** (one lock per device; `:` in the serial becomes `_`; falls back to `$DV_OUT/lock-<serial>`) |
| `DV_SELFTEST_FAST` | `=1` skips fake delays **in selftest only** (never changes real-device derived values) |
| `DV_INSTALL_TAP` / `CONF_INSTALL_TAP` | auto-tap coordinates `"x,y"` for the installer dialog; **default `none` = do not tap** (tap "Continue install" yourself). It only taps when coordinates are given; out-of-range values (checked against `wm size`) exit `2` and print the real screen size |
| `DV_INSTALL_TIMEOUT` | overall wait for the install result (default 180 s); timeout/rejection → `exit 6` (`USER_RESTRICTED`) |
| `DV_APK` / `DV_NPU_APK` / `DV_NPU_PKG` | default APKs and the NNAPI demo package |
| `DV_IME_SNAPSHOT` | IME snapshot path (default `${XDG_CACHE_HOME:-~/.cache}/dv/ime-snapshot.json`) |
| `DV_GATEWAY` / `CONF_GATEWAY` | optional host-side gateway; `doctor` reads `<gateway>/api/mobile-access/lan/status` for `deviceCount` |
| `DV_MARKER` | default `uitree` / `wait-until` marker (readiness signal); empty means "don't check" |
| `DV_JAVA` / `DV_SDK` | JDK / Android SDK for `dv build` (highest precedence) |
| `DV_BUILD_TIMEOUT` | `dv build` timeout (default 1800 s) |
| `DV_ANDROID_USER_HOME` | `ANDROID_USER_HOME` for `dv build` (default `~/.cache/dv/android`, **write-tested**, auto-fallback) |
| `DV_GRADLE_USER_HOME` | `GRADLE_USER_HOME` for `dv build` (default `$GRADLE_USER_HOME` / `~/.gradle`, write-tested too) |
| `DV_CONF` | use another config file |
| `NO_COLOR` / `DV_VERBOSE` | disable color / same as `--verbose` |

Device discovery: explicit (`--serial` > `DV_SERIAL` > `CONF_SERIAL`, one `adb connect` attempt when offline)
→ the single online `adb devices` entry → multiple online devices fail with **`exit 2`** (the message names
`dv devices`) → `adb mdns` `_adb-tls-connect` → otherwise `exit 3`.

---

## Known limitations

- **One device at a time.** Multiple devices require an explicit `--serial`; no parallel scheduling. `dv lock`
  is a cooperative lock: it only binds callers that acquire it first, and its TTL expires (re-acquire to renew).
- **`dv selftest` still takes ~36 s** (79 assertions): the bottleneck is 79 `dv` process launches, not waiting.
  `DV_SELFTEST_FAST=1` only skips fake delays and does **not** bring it under 10 s; doing so would require
  "source the libs and call in-process", a structural change that was deliberately not made.
- **`dv input text` accepts ASCII only.** Non-ASCII (CJK, emoji) exits `2` with three workarounds (clipboard,
  `%s`-encoded `adb shell input text`, an in-app hook). This is a deliberate refusal, not a bug.
- **`dv cdp eval` writes the DOM but does not wrap higher-level actions.** `el.click()` works through `eval`;
  `Page.reload`/input injection are not wrapped (IME state, coordinate drift and keyboard occlusion make
  injection unreproducible).
- **UI tree depends on `uiautomator dump`.** A `could not get idle state` failure now exits `4` immediately
  (~50 ms, `reason=idle_timeout`, with alternatives); other transient failures still walk the
  retry → restart → poll ladder.
- **Only the `text` attribute is used.** `content-desc` / `aria-label` need an explicit `--find` / `--desc`.
- **`dv check` requires a package name**; without one it exits `2` rather than guessing. `dv doctor` does not need it.
- **`dv crash` cannot read tombstones without root** — it reports `tombstones_readable: false`, which is not a failure.
- **`dv perf --gfxinfo` is meaningful only for hardware-accelerated apps**; a pure WebView/software-rendered
  process may report zeros — use CDP geometry instead.
- **`dv logcat --follow` is a bounded window** (default 30 s, `Ctrl-C` works), not a daemon.
- **`dv build` needs a local JDK + Android SDK** (`exit 7` otherwise); it only runs `./gradlew assemble<Variant>`
  and finds the artifact, it does not parse AGP configuration.
- **Not tested in CI/containers.** adb daemon USB permissions and udev rules are a separate class of problems.
- **Very narrow real-device coverage.** Only `doctor` / `check` / `cdp version` (Android 17 + HyperOS 4, wireless
  debugging) and `build --variant debug` have run on hardware; everything else has only run in the device-free
  self-test (see [verification status](#verification-status)). Other ROMs differ in installer dialogs, IME lists
  and `dumpsys` field names — which is exactly why `doctor` exists.

---

## Known pitfalls and targeted hints

Pitfalls where **the error message is far from the real cause**. `dv` builds the check into the command, but you
should still know what it is guarding against.

### The two Gradle `*_USER_HOME` dirs: `mkdir` succeeding does not mean writable

- **`ANDROID_USER_HOME`** — AGP writes `debug.keystore.lock` there. If the directory exists but is **not writable**,
  the build dies much later and the error looks like a signing problem. `dv build` does `mkdir -p` **plus a write
  test** (`mkdir && : > .dv-w`), falls back to a writable temp dir and says so (`DV_ANDROID_USER_HOME` overrides).
- **`GRADLE_USER_HOME`** — same story. When it is not writable the Gradle wrapper reports
  `Could not create parent directory for lock file`, which never mentions permissions and is easily mistaken for a
  network problem. `dv build` write-tests, falls back and hints; point `DV_GRADLE_USER_HOME` at an existing cache
  to reuse dependencies.

### Build failures: keep the log, give three targeted hints

On failure (`exit 8`) `dv build` does not just print "BUILD FAILED": it keeps the full Gradle log, prints **only
the `What went wrong` → `* Try:` section** to stderr, and adds hints based on the log's fingerprint:

| Log fingerprint | Hint |
|---|---|
| `Read timed out` / `Could not resolve` | distribution/dependency download timeout: retry, `--offline` (if cached), or configure a Gradle mirror (**dv never hardcodes a mirror**) |
| `distributionUrl=file:` with CJK/spaces in the path | use a URI-encoded `file://` path, or move the distribution to an ASCII-only path |
| `Could not create parent directory` / `Permission denied` | `*_USER_HOME` not writable — see above, use `DV_GRADLE_USER_HOME` / `DV_ANDROID_USER_HOME` |

### `release` without `signingConfig` → `exit 6`, not `8`

The build may "succeed" but produce `*-unsigned.apk`, which cannot be installed. `dv build` checks
`signingConfig` / `DV_ANDROID_KEYSTORE_FILE` **before** building and exits `6` with "needs signingConfig" —
better to fail early than hand you an artifact you cannot install. Use `--variant debug`, or configure signing.

### `dv doctor`'s IME baseline: warn only, never mutate the device

`doctor` reads the enabled IME count (`ime list -s`), `settings get secure default_input_method` and
`show_ime_with_hard_keyboard`. When the count is < 2 or the default IME is not in the enabled list it prints a
WARN plus the fix — **it never runs `ime enable/disable` by itself**. The device belongs to the user.

### Installer dialog: not auto-tapped by default

Older builds tapped "Continue install" at a fixed `846,2002`. **That default is no longer reliable**: the button
position depends on resolution, DPI, **orientation** and ROM build — on a 2272×3408 landscape tablet it lands on
"Reject" and you get `INSTALL_FAILED_USER_RESTRICTED` (`exit 6`).

Since 0.1.1, `DV_INSTALL_TAP` **defaults to `none`** — nothing is tapped; the dialog appears, you tap
"Continue install", and `dv install` waits for the result and fails loudly on timeout instead of silently.

To automate it, give coordinates explicitly:

```bash
DV_INSTALL_TAP="1060,1224" dv --pkg com.example.app install --apk app-debug.apk   # measured on a 3408×2272 landscape tablet
DV_INSTALL_TAP="600,1800"  dv install --apk app-debug.apk                         # starting point for a 1200×2608 phone
```

- coordinates are **px** (not dp/css); convert with the `screen` fields from `dv doctor --json`
  (`wm_size` / `wm_density` / `dpr`);
- re-measure when you change device or orientation — the button is tied to the window orientation;
- out-of-range coordinates are refused (`exit 2` plus the real screen size), so you cannot "tap off-screen" and
  believe it worked;
- it can also live in `dv.conf`: `CONF_INSTALL_TAP=1060,1224`.

**`--json`'s `installed` is decided by the APK's own package name** (`aapt2`/`aapt` reads `package: name=`, then a
before/after `pm list packages` diff) instead of trusting `--pkg` — otherwise installing `.debug` while `--pkg`
points at release would report a fake `installed:true`.

### Other long-standing traps (already handled by the commands)

- **`uiautomator dump` idle-state failures** used to burn ~11 s each; after real-device runs they now **fail fast**
  (`exit 4`, ~50 ms) and **no longer restart the app by default** (restart requires `--restart-app`, plus
  `--allow-restart-release` for release builds).
- **`uitree --marker` mismatch** now reports a distinct `reason: "marker_missing"` (instead of "could not get the
  UI tree"), together with the node count and the marker, so "page not ready" is distinguishable from "no tree".
- **`perf --gfxinfo` on an app that is not running** used to look successful with `null` metrics; it now exits `6`
  (`reason: no_frames`) and tells you to start the app first.
- **`input text` with no focused input field** used to report "typed N characters" falsely; it now checks the
  `dumpsys input_method` focus view and exits `4` with a hint to tap the field first.
- **Release builds have no devtools socket**, so `dv cdp` always exits `5`. That is not a broken tool.

---

## Deliberately out of scope

Not "not yet" — decided against, each with a reason (this kills half of all feature requests):

| Not doing | Why | Use instead |
|---|---|---|
| A flow DSL (`dv run flow.yaml`) | DSL grammar, wait semantics and ecosystem are another product; bash cannot maintain them | [Maestro](https://docs.maestro.dev/maestro-flows) |
| Record / replay | Recordings couple to resolution, timing and data state; replay flakiness outweighs the gain | [Airtest](https://github.com/AirtestProject/Airtest) / SoloPi |
| A bundled MCP server | One more protocol layer, one more version burden; `--json` + exit codes are enough for any wrapper | wrap `dv --json` upstream |
| Device farms / sharding | Queues, locks and a web console are another product; our unit is "one verification round", not "a suite" | STF / Marathon / Flank |
| Re-implementing the ADB protocol | Version skew (server 41 vs client 36 kick each other) becomes permanent maintenance | shell out to `adb` |
| Video streaming / input injection engines | scrcpy's decade of MediaCodec + injection work; a reimplementation will fail. `dv input` is a thin, tree-driven helper, not a replacement | [scrcpy](https://github.com/Genymobile/scrcpy) |
| OCR / image-based assertions | Recognition couples to fonts, scaling and anti-aliasing — unreproducible | read text via CDP/DOM |
| APK badging | Binary format; reimplementations get it wrong | `aapt2 dump badging` |

---

License: MIT © 2026 LUgABeEEE. Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md).
