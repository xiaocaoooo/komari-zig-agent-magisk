#!/bin/sh
# Magisk 模块脚本行为测试。
#
# 与 shellcheck 互补：shellcheck 只查语法/风格，本脚本验证真实行为：
#   - install.sh 能安装二进制、生成配置、探测 DNS、且不覆盖已有配置
#   - service.sh 在 endpoint 为空时不启动、日志给出原因
#   - uninstall.sh 只杀掉指向本模块二进制的进程
#
# 用临时目录伪造 /data/adb/komari-agent 与 getprop，可在任意 POSIX 环境运行。
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MOD="$ROOT/magisk"
BASE="${MODULE_TEST_BASE:-${TMPDIR:-/tmp}/komari-module-test.$$}"
PASS=0
FAIL=0

cleanup() {
  [ "${MODULE_TEST_KEEP:-0}" = 1 ] || rm -rf "$BASE"
}
trap cleanup EXIT HUP INT TERM

ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1" >&2; }

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null 2>&1
}
assert_file() { [ -f "$1" ]; }

# 断言助手：避免 `A && B || C` 在 A 为真而 B 失败时误走 C。
check() {
  if "$@"; then
    ok "$DESC"
  else
    not_ok "$DESC"
    return 1
  fi
}

# --- 环境准备 ---
# 模块脚本写死 /data/adb/komari-agent，测试时用 sed 重写为临时目录，
# 这样能验证真实脚本逻辑而不需要 root 或 Android。
prepare_case() {
  case_dir="$BASE/$1"
  mkdir -p "$case_dir/modpath" "$case_dir/data/bin" "$case_dir/data/logs" "$case_dir/fakebin"
  for f in install.sh service.sh uninstall.sh; do
    sed "s|/data/adb/komari-agent|$case_dir/data|g" "$MOD/$f" > "$case_dir/modpath/$f"
    chmod 0755 "$case_dir/modpath/$f"
  done
  printf '#!/bin/sh\n' > "$case_dir/modpath/komari-agent"
  chmod 0755 "$case_dir/modpath/komari-agent"

  # 伪造 getprop：模拟 Android 的 vendor.net.<iface>.dns1
  cat > "$case_dir/fakebin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  vendor.net.wlan0.dns1) echo "10.0.2.3" ;;
  *) echo "" ;;
esac
EOF

  # 伪造 Magisk installer 提供的 ui_print / abort
  cat > "$case_dir/fakebin/magisk_stubs" <<'EOF'
ui_print() { printf '%s\n' "$*"; }
abort() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
EOF
  chmod 0755 "$case_dir/fakebin/getprop"
  printf '%s' "$case_dir"
}

run_install() {
  d="$1"
  PATH="$d/fakebin:$PATH" sh -c ". '$d/fakebin/magisk_stubs'; MODPATH='$d/modpath' sh '$d/modpath/install.sh'" >"$d/out.log" 2>&1
}

# --- 用例 1：install.sh 生成配置并写入探测到的 DNS ---
test_install_generates_config() {
  d="$(prepare_case install)"
  if ! run_install "$d"; then
    not_ok "install.sh runs"
    cat "$d/out.log" >&2
    return
  fi
  DESC="install.sh installs binary" check assert_file "$d/data/bin/komari-agent" || true
  DESC="install.sh creates config.json" check assert_file "$d/data/config.json" || true
  DESC="install.sh writes detected DNS into custom_dns" \
    check assert_contains "$d/data/config.json" '"custom_dns": "10.0.2.3"' || true
}

# --- 用例 2：已有配置不被覆盖 ---
test_install_preserves_config() {
  d="$(prepare_case preserve)"
  printf '{"endpoint":"https://keep.example","token":"keep"}\n' > "$d/data/config.json"
  if ! run_install "$d"; then
    not_ok "install.sh rerun"
    return
  fi
  DESC="install.sh preserves existing config" check assert_contains "$d/data/config.json" 'keep.example' || true
}

# --- 用例 3：service.sh 在 endpoint 为空时不启动 ---
test_service_skips_empty_endpoint() {
  d="$(prepare_case service_empty)"
  printf '{"endpoint":"","token":""}\n' > "$d/data/config.json"
  printf '#!/bin/sh\ntouch "%s/started"\n' "$d/data" > "$d/data/bin/komari-agent"
  chmod 0755 "$d/data/bin/komari-agent"
  # service.sh 的看护循环不会自然结束，跑几秒后杀掉。
  PATH="$d/fakebin:$PATH" sh -c "MODPATH='$d/modpath' sh '$d/modpath/service.sh' & p=\$!; sleep 3; kill \$p 2>/dev/null" >"$d/out.log" 2>&1 || true
  if [ -f "$d/data/started" ]; then
    not_ok "service.sh skips start when endpoint empty"
  else
    ok "service.sh skips start when endpoint empty"
  fi
  DESC="service.sh logs empty-endpoint reason" check assert_contains "$d/data/logs/agent.log" 'endpoint is empty' || true
}

# --- 用例 4：service.sh 在 endpoint 非空时必须启动 agent ---
#
# 回归用例：曾经的实现用 GNU BRE 的 "\+" 判断 endpoint 非空，而 Android 的
# /system/bin/grep 是 toybox，不支持 "\+"，导致真机上永远判定为空、agent 永不
# 启动，而本地 BSD grep 却能通过。这里断言"非空 endpoint 必须真的启动 agent"，
# 是防止该缺陷复发的关键守卫。
test_service_starts_with_endpoint() {
  d="$(prepare_case service_start)"
  printf '{"endpoint":"https://panel.example","token":"tok"}\n' > "$d/data/config.json"
  printf '#!/bin/sh\ntouch "%s/started"\n' "$d/data" > "$d/data/bin/komari-agent"
  chmod 0755 "$d/data/bin/komari-agent"
  PATH="$d/fakebin:$PATH" sh -c "MODPATH='$d/modpath' sh '$d/modpath/service.sh' & p=\$!; sleep 3; kill \$p 2>/dev/null" >"$d/out.log" 2>&1 || true
  DESC="service.sh starts agent when endpoint is set" check assert_file "$d/data/started" || true
  DESC="service.sh records start in log" check assert_contains "$d/data/logs/agent.log" 'agent started' || true
}

# --- 用例 5：uninstall.sh 只杀指向本模块二进制的进程 ---
test_uninstall_kills_only_module_binary() {
  d="$(prepare_case uninstall)"
  sleep 60 &
  other=$!
  cp "$(command -v sleep)" "$d/data/bin/komari-agent"
  "$d/data/bin/komari-agent" 60 &
  agent=$!
  sleep 1
  printf '%s\n' "$agent" > "$d/data/agent.pid"
  PATH="$d/fakebin:$PATH" sh "$d/modpath/uninstall.sh" >"$d/out.log" 2>&1 || true
  sleep 1
  if kill -0 "$agent" 2>/dev/null; then
    not_ok "uninstall.sh terminates module agent"
    kill -9 "$agent" 2>/dev/null || true
  else
    ok "uninstall.sh terminates module agent"
  fi
  if kill -0 "$other" 2>/dev/null; then
    ok "uninstall.sh leaves unrelated processes alone"
  else
    not_ok "uninstall.sh leaves unrelated processes alone"
  fi
  kill -9 "$other" 2>/dev/null || true
}

mkdir -p "$BASE"

test_install_generates_config
test_install_preserves_config
test_service_skips_empty_endpoint
test_service_starts_with_endpoint
test_uninstall_kills_only_module_binary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
