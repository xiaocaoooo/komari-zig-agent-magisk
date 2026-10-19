#!/system/bin/sh
# Magisk 模块卸载脚本：由 Magisk 在移除模块时执行。
# 只停止进程，保留 /data/adb/komari-agent 下的配置与日志，便于重装后继续使用。

DATA_DIR=/data/adb/komari-agent
PIDFILE="$DATA_DIR/agent.pid"

if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
      *komari-agent*) kill "$pid" 2>/dev/null || true ;;
    esac
  fi
  rm -f "$PIDFILE"
fi

# 兜底：按 exe 链接精确清理残留进程（不使用模式匹配，避免误杀）
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
  case "$exe" in
    "$DATA_DIR/bin/komari-agent") kill "$pid" 2>/dev/null || true ;;
  esac
done

# 配置与日志保留；如需彻底清除，用户可手动 rm -rf /data/adb/komari-agent
exit 0
