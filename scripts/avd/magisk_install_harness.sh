#!/system/bin/sh
# 在 AVD Shell Root 下按 Magisk 约定安装模块（模拟 Magisk installer 的调用环境）。
#
# Magisk 真实行为：
#   1. 解压 zip 到 $MODPATH（临时目录）
#   2. 在 $MODPATH 内、以 $MODPATH 为 cwd 执行 install.sh，并提供 ui_print/abort 函数
#   3. 把 $MODPATH 移动到 /data/adb/modules/<id>/
#   4. 开机时执行 service.sh
#
# 本脚本复现 1-3，用于在无 Magisk 的 userdebug 模拟器上验证模块脚本的真实行为。
set -eu

ZIP=/data/local/tmp/komari-module-upload/module.zip
STAGE=/data/local/tmp/komari-module-stage
MODULES=/data/adb/modules
MODID=komari_agent

rm -rf "$STAGE"
mkdir -p "$STAGE" "$MODULES"

echo "=== 1. 解压模块 zip ==="
cd "$STAGE"
unzip -o -q "$ZIP"
ls -la "$STAGE"

echo
echo "=== 2. 校验 module.prop ==="
cat "$STAGE/module.prop"
if ! grep -qx "id=${MODID}" "$STAGE/module.prop"; then
  echo "FAIL: module.prop id mismatch"
  exit 1
fi

echo
echo "=== 3. 执行 install.sh（提供 Magisk 的 ui_print/abort）==="
MODPATH="$STAGE"
export MODPATH
cd "$STAGE"
sh -c '
  ui_print() { printf "%s\n" "$*"; }
  abort() { printf "ABORT: %s\n" "$*" >&2; exit 1; }
  . "$MODPATH/install.sh"
'
echo "install.sh exit=$?"

echo
echo "=== 4. 搬到 /data/adb/modules/$MODID ==="
rm -rf "$MODULES/$MODID"
mv "$STAGE" "$MODULES/$MODID"
rm -f "$MODULES/$MODID/remove" 2>/dev/null || true
ls -la "$MODULES/$MODID"

echo
echo "=== 5. 安装结果检查 ==="
echo "--- /data/adb/komari-agent ---"
ls -laR /data/adb/komari-agent 2>&1
echo "--- config.json ---"
cat /data/adb/komari-agent/config.json 2>&1
echo
echo "--- 已安装二进制 ---"
file /data/adb/komari-agent/bin/komari-agent 2>&1
/data/adb/komari-agent/bin/komari-agent --show-warning >/dev/null 2>&1 && echo "binary runs: OK" || echo "binary runs: FAIL"

echo
echo "=== 6. 脚本执行位 ==="
for f in install.sh service.sh uninstall.sh; do
  ls -l "$MODULES/$MODID/$f"
done
