#!/system/bin/sh
# Magisk 模块安装脚本：由 Magisk installer 在刷入时执行。
# 约定：$MODPATH 是模块暂存目录，本脚本结束时 Magisk 会把它搬到 /data/adb/modules/<id>。
#
# 职责：
#   1. 把随模块分发的 agent 二进制安装到持久目录 /data/adb/komari-agent/bin/
#   2. 首次安装时生成 config.json 模板，并**自动探测 Android DNS** 写入 custom_dns
#      （关键：Android 没有 /etc/resolv.conf，musl 静态 getaddrinfo 无法解析域名）
#   3. 保留已存在的用户配置，不覆盖

# SKIPUNZIP 由 Magisk installer 读取，本脚本不直接使用；shellcheck 会误报未使用。
# shellcheck disable=SC2034
SKIPUNZIP=0

DATA_DIR=/data/adb/komari-agent
BIN_DIR="$DATA_DIR/bin"
LOG_DIR="$DATA_DIR/logs"
CONFIG_FILE="$DATA_DIR/config.json"

ui_print "- Komari Agent (Zig) 模块安装"
ui_print "- 数据目录: $DATA_DIR"

mkdir -p "$BIN_DIR" "$LOG_DIR"
if [ ! -d "$BIN_DIR" ]; then
  ui_print "! 无法创建 $BIN_DIR"
  abort "! 安装失败：数据目录不可写"
fi

# --- 1. 安装二进制 ---
if [ -f "$MODPATH/komari-agent" ]; then
  cp -f "$MODPATH/komari-agent" "$BIN_DIR/komari-agent"
  chmod 0755 "$BIN_DIR/komari-agent"
  ui_print "- 已安装二进制: $BIN_DIR/komari-agent"
else
  abort "! 模块内缺少 komari-agent 二进制"
fi

# --- 2. 探测 Android DNS ---
# Android 的 DNS 服务器只存在于系统属性 vendor.net.<iface>.dns1 中，
# 不存在 /etc/resolv.conf。musl 静态链接的 getaddrinfo 读不到这些属性，
# 因此必须显式把 DNS 写进 custom_dns，否则 agent 无法解析任何域名。
detect_dns() {
  for iface in wlan0 eth0 rmnet_data0 rmnet_data1 rmnet0 ccmni0; do
    dns="$(getprop "vendor.net.${iface}.dns1" 2>/dev/null)"
    if [ -n "$dns" ]; then
      printf '%s' "$dns"
      return 0
    fi
  done
  # 兜底：部分设备把 DNS 放在 net.<iface>.dns1
  for iface in wlan0 eth0 rmnet_data0 rmnet0; do
    dns="$(getprop "net.${iface}.dns1" 2>/dev/null)"
    if [ -n "$dns" ]; then
      printf '%s' "$dns"
      return 0
    fi
  done
  return 1
}

DNS_SERVER="$(detect_dns || true)"
if [ -n "$DNS_SERVER" ]; then
  ui_print "- 探测到 DNS: $DNS_SERVER"
else
  ui_print "! 未探测到系统 DNS，config.json 中 custom_dns 留空"
  ui_print "! 请手动填写 custom_dns，否则 agent 无法解析面板域名"
fi

# --- 3. 生成配置模板（不覆盖已有配置）---
if [ -f "$CONFIG_FILE" ]; then
  ui_print "- 已存在配置，保留: $CONFIG_FILE"
else
  cat > "$CONFIG_FILE" <<EOF
{
  "endpoint": "",
  "token": "",
  "interval": 3,
  "info_report_interval": 5,
  "protocol_version": 2,
  "disable_auto_update": false,
  "custom_dns": "${DNS_SERVER}",
  "month_rotate": 0,
  "debug_log": false
}
EOF
  chmod 0600 "$CONFIG_FILE"
  ui_print "- 已生成配置模板: $CONFIG_FILE"
  ui_print "  请编辑该文件填入 endpoint 与 token 后重启设备"
fi

ui_print "- 安装完成。重启设备后模块自动启动 agent。"

# 模块自身的可执行脚本（service.sh 等）由 Magisk 负责 chmod，
# 这里显式设置一次，避免某些打包方式丢失执行位。
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null
