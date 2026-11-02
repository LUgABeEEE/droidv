#!/usr/bin/env bash
# logcat-crash.sh —— 崩溃取证一条命令：crash 缓冲 + ANR + tombstone + 截图 + UI 树，全部落到一个 bundle
#
# 和「人肉 adb logcat | grep」的差别：用的是 dv 的结构化输出（`dv crash --json` / `dv logcat --crash --json`），
# 崩溃块按行合并（不丢栈中间的行），像素证据与 UI 树一起归档，退出码直接回答「这次到底有没有崩」。
#
# 用法:
#   examples/logcat-crash.sh --pkg com.example.app
#   examples/logcat-crash.sh --pkg com.example.app --serial 192.0.2.10:5555 -o /tmp/crash
#   examples/logcat-crash.sh --pkg com.example.app --clear --wait 10   # 先清缓冲，操作 10 s 再抓
#
# 产物（默认 <out>/crash-<ts>/）: crash.json  logcat-crash.json  crash.txt  shot.png  ui.xml  uitree.json
# 退出码: 0 抓到崩溃证据 · 1 没抓到 · 2 参数错误 · 3 无设备 · 4 取数失败
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DV="${DV:-$HERE/../dv}"

PKG=""; SERIAL=""; OUT=""; CLEAR=0; WAIT=0; LINES=200

die() { printf '✘ %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="${2:-}"; shift 2 ;;
    --serial) SERIAL="${2:-}"; shift 2 ;;
    -o|--out) OUT="${2:-}"; shift 2 ;;
    --clear) CLEAR=1; shift ;;
    --wait) WAIT="${2:-0}"; shift 2 ;;
    -n|--lines) LINES="${2:-200}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "不认识的参数：$1（-h 看用法）" ;;
  esac
done

# 全局选项必须写在子命令之前（见 docs/redlines.md 第 3 条）
G=(--json)
[ -n "$SERIAL" ] && G+=(--serial "$SERIAL")
[ -n "$PKG" ] && G+=(--pkg "$PKG")

[ -n "$OUT" ] || OUT="$(pwd)/dv-out/crash-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || die "建不了目录：$OUT"

if [ "$CLEAR" = "1" ]; then
  if "$DV" ${SERIAL:+--serial "$SERIAL"} adb -- logcat -c >/dev/null 2>&1; then
    echo "· 已清空 logcat 缓冲"
  else
    printf '✘ 清缓冲失败（exit 4）\n' >&2; exit 4
  fi
fi
if [ "$WAIT" -gt 0 ] 2>/dev/null; then echo "· 等待 ${WAIT}s（现在去操作设备复现）"; sleep "$WAIT"; fi

# 1) 崩溃缓冲 + ANR + tombstone（dv 的结构化输出）
"$DV" "${G[@]}" crash -n "$LINES" > "$OUT/crash.json" 2>"$OUT/crash.err"
RC=$?
[ "$RC" = "0" ] || { printf '✘ dv crash 失败（exit %s）\n' "$RC" >&2; cat "$OUT/crash.err" >&2; exit "$RC"; }
rm -f "$OUT/crash.err"

# 2) 结构化崩溃行（可能为空：崩溃缓冲没东西，属正常）
"$DV" "${G[@]}" logcat --crash -n "$LINES" > "$OUT/logcat-crash.json" 2>/dev/null \
  || echo '{"ok":true,"lines":0,"items":[]}' > "$OUT/logcat-crash.json"

# 3) 现场另外两件套（有设备就一定拿得到；失败不影响主结论）
SER="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1], encoding="utf-8")).get("serial",""))
except Exception: print("")' "$OUT/crash.json" 2>/dev/null)"
[ -n "$SER" ] || SER="$SERIAL"
"$DV" ${SER:+--serial "$SER"} shot -n 1 -o "$OUT" --json > "$OUT/shot.json" 2>/dev/null || rm -f "$OUT/shot.json"
"$DV" "${G[@]}" uitree --json --dump-out "$OUT/ui.xml" > "$OUT/uitree.json" 2>/dev/null || rm -f "$OUT/uitree.json"

# 4) 判定：崩溃缓冲有内容 / 有 ANR / 有结构化崩溃行，三者有其一即「抓到证据」
python3 - "$OUT/crash.json" "$OUT/logcat-crash.json" "$OUT/crash.txt" <<'PY'
import json, sys, re
crash_p, lines_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3]

def load(p, default):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return default

crash = load(crash_p, {})
items = load(lines_p, {}).get("items") or []

text = (crash.get("crash") or "").splitlines()
fatal = [l for l in text if re.search(r"FATAL EXCEPTION|ANR in |Fatal signal|beginning of crash", l)]

print("· serial      %s" % (crash.get("serial") or "?"))
print("· crash 行数  %s" % (crash.get("crash_lines", 0)))
print("· ANR         %s" % ("有" if (crash.get("anr") or "").strip() else "无"))
print("· tombstone   %s" % ("可读" if crash.get("tombstones_readable") else "不可读（通常需要 root，不算失败）"))
print("· 结构化日志  %d 行" % len(items))

with open(out_p, "w", encoding="utf-8") as f:
    f.write("\n".join(text) + ("\n" if text else ""))

evidence = bool(text) or bool((crash.get("anr") or "").strip()) or bool(items)
if evidence and fatal:
    print("\n── 关键行 ──")
    for l in fatal[:8]:
        print("  " + l)
sys.exit(0 if evidence else 1)
PY
RC=$?

echo "· bundle: $OUT（crash.json / logcat-crash.json / crash.txt / shot.png / ui.xml / uitree.json）"
if [ "$RC" = "0" ]; then
  echo "✔ 抓到崩溃证据：$OUT/crash.txt"
  exit 0
fi
echo "· 没抓到崩溃证据（exit 1）：crash 缓冲空、无 ANR 记录"
echo "  ↳ 复现类问题用 --clear --wait 10：先清缓冲，再操作设备，再抓"
exit 1
