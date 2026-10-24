#!/bin/sh
# Magisk 模块脚本的 Android 可移植性静态检查。
#
# 为什么需要这个检查：
#   模块脚本由 Magisk 用 Android 的 /system/bin/sh（mksh）执行，其中的
#   grep/sed 来自 toybox，而不是 GNU coreutils。toybox 刻意只实现 POSIX
#   子集，例如它**不支持 GNU BRE 的 "\+" 运算符**。
#
#   本仓库曾用 `grep -q '"endpoint"..."[^"]\+"'` 判断 endpoint 非空。BSD/macOS
#   的 grep 支持该扩展，CI（Ubuntu，GNU grep）也支持，所以本地与 CI 全绿；
#   但在真机上 toybox 把非空 endpoint 判成空，agent 永远不启动。
#
# 这个脚本扫描 magisk/*.sh，拦截这类"换平台才炸"的构造。它是零依赖的静态
# 检查，不需要 Android 设备或 toybox 即可确定性地执行，因此可以进 CI 长期
# 守住这个回归。
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# MODULE_DIR 允许在别的目录上复用同一套检查（自检用例需要它）。
MOD="${MODULE_DIR:-$ROOT/magisk}"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1" >&2; }

fail() {
  not_ok "$1"
  shift
  for line in "$@"; do
    printf '    %s\n' "$line" >&2
  done
}

# --- 1. 禁止 GNU BRE 的 "\+" / "grep -P" 等非 POSIX 构造 ---
#
# "\+" 只在 GNU BRE / POSIX ERE 中有意义。toybox grep 会把它当字面 "+"，
# 从而让本该匹配非空的模式失配。
#
# 这里用 grep -E 扫描转义后的反斜杠加号：`\\+` 在 ERE 中表示"一个反斜杠
# 后跟一个加号"，正好对应脚本里的 BRE 转义写法。
scan_for_gnu_bre() {
  file="$1"
  # 精确匹配"反斜杠 + 加号"：ERE 里 "\\" 是字面反斜杠，"[+]" 是字面加号。
  # 这样不会误报 sed 的 \1 反向引用，也不会误报行尾续行反斜杠。
  # 注释行被排除：注释里出现 "\+" 是在解释该规则本身，不是用法。
  hits=$(grep -nE '\\[+]' "$file" 2>/dev/null | grep -vE ':[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    fail "$file: GNU BRE \"\\+\" is not supported by Android toybox grep" "$hits"
    return 1
  fi
  ok "$file: no GNU BRE \"\\+\" operator"
}

# --- 2. 禁止 grep -P（PCRE）与 \d \w \s \b 等 PCRE 转义 ---
scan_for_pcre() {
  file="$1"
  hits=$(tr '\n' ' ' < "$file" | grep -oE 'grep[[:space:]]+(-[a-zA-Z]*[Pp][a-zA-Z]*|--perl-regexp)' 2>/dev/null || true)
  if [ -n "$hits" ]; then
    fail "$file: grep -P/--perl-regexp is not supported by Android toybox grep" "$hits"
    return 1
  fi
  ok "$file: no PCRE grep mode"
}

# --- 3. 禁止脚本依赖 bash 专有语法 ---
#
# Magisk 用 /system/bin/sh 执行脚本，且 shellcheck -s sh 也按 POSIX 校验。
# 这里额外断言没有出现 bash 专有的数组/过程替换等写法，作为双保险。
scan_for_bashisms() {
  file="$1"
  hits=$(grep -nE '(^|[;&|(])[[:space:]]*(declare|local[[:space:]]+-[[:alnum:]_]+=|function[[:space:]]+[a-zA-Z_]+[[:space:]]*\(\)|<\(|>\()' "$file" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    fail "$file: bash-only syntax is not valid under /system/bin/sh" "$hits"
    return 1
  fi
  ok "$file: no bash-only syntax"
}

# --- 4. 关键配置判定必须真的做非空判断 ---
#
# service.sh 依赖"endpoint 非空"来决定是否启动 agent。这里断言它用的是
# 可移植写法：先把值取出来再判空，而不是靠正则匹配"看起来非空"。
scan_endpoint_guard() {
  file="$MOD/service.sh"
  # grep 的模式是字面量文本匹配，不展开变量；shellcheck SC2016 在此不适用。
  if grep -q 'endpoint_value=' "$file" 2>/dev/null &&
     # shellcheck disable=SC2016
     grep -q 'if \[ -z "\$endpoint_value" \]' "$file" 2>/dev/null; then
    ok "service.sh extracts the endpoint value before testing it for emptiness"
    return 0
  fi
  fail "service.sh: endpoint emptiness must be decided by extracting the value and comparing it, not by regex-matching \"[^\\\"]*\" (which cannot tell \"\" from \"x\")" \
    "$(grep -n 'endpoint' "$file" 2>/dev/null | head -5 || true)"
}

# --- 5. 脚本必须以 /system/bin/sh 的 shebang 开头 ---
scan_shebang() {
  file="$1"
  first=$(head -n 1 "$file")
  case "$first" in
    '#!/system/bin/sh'*) ok "$file: uses #!/system/bin/sh" ;;
    *) fail "$file: shebang must be #!/system/bin/sh (Magisk runs it with Android's shell), got: $first" ;;
  esac
}

scan_all() {
  for f in "$MOD/install.sh" "$MOD/service.sh" "$MOD/uninstall.sh"; do
    [ -f "$f" ] || { fail "missing $f"; continue; }
    scan_for_gnu_bre "$f" || true
    scan_for_pcre "$f" || true
    scan_for_bashisms "$f" || true
    scan_shebang "$f" || true
  done

  scan_endpoint_guard || true
}

# --- 自检：确认这个守卫真的能抓到回归 ---
#
# 一个从不失败的检查等于没有检查。这里把 service.sh 的可移植写法改回当初的
# GNU BRE 写法（"[^"]\+"），再跑一遍扫描，断言它确实报错。
#
# 做法：复制模块到临时目录 -> 用 sed 把可移植片段替换成旧写法 -> 对副本执行
# 扫描 -> 期望非零退出。
self_test() {
  work="$BASE/self-test"
  mkdir -p "$work"
  cp "$MOD/install.sh" "$MOD/service.sh" "$MOD/uninstall.sh" "$work/"

  # 把可移植的"取值再判空"还原成旧的 GNU BRE "非空匹配"。
  # sed 表达式是刻意构造的字面量替换（含 \$ 与 \\+），不展开任何变量。
  # shellcheck disable=SC2016
  sed -e 's|^  endpoint_value=.*|  if ! grep -q '"'"'"endpoint"[[:space:]]*:[[:space:]]*"[^"]\\+"'"'"' "$CONFIG" 2>/dev/null; then|' \
      -e 's|^  if \[ -z "\$endpoint_value" \]; then|    echo legacy|' \
      "$MOD/service.sh" > "$work/service.sh"

  if grep -q '\\[+]' "$work/service.sh"; then
    ok "self-test: the legacy GNU BRE pattern was injected"
  else
    not_ok "self-test: failed to inject the legacy GNU BRE pattern"
    return 1
  fi

  if MODULE_DIR="$work" "$0" >"$work/scan.out" 2>&1; then
    not_ok "self-test: scanner accepted the legacy GNU BRE pattern (guard is ineffective)"
    sed -n '1,20p' "$work/scan.out" >&2
    return 1
  fi
  ok "self-test: scanner rejects the legacy GNU BRE pattern"
  return 0
}

BASE="${TMPDIR:-/tmp}/komari-portability-test.$$"
cleanup() {
  [ "${MODULE_TEST_KEEP:-0}" = 1 ] || rm -rf "$BASE"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$BASE"

scan_all

if [ "${1:-}" = "--self-test" ]; then
  self_test || true
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
