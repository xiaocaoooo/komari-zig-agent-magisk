#!/system/bin/sh
# Magisk late_start service 脚本：由 Magisk 在开机后执行。
#
# 职责：以守护方式启动 komari-agent，并在其退出后自动重启（带退避）。
# 设计要点：
#   - 用 PID 文件 + 进程存活检查避免重复启动
#   - 退出码 0（用户主动停止）不再重启
#   - 日志追加写入，带大小上限轮转

DATA_DIR=/data/adb/komari-agent
BIN="$DATA_DIR/bin/komari-agent"
CONFIG="$DATA_DIR/config.json"
LOG_DIR="$DATA_DIR/logs"
LOG="$LOG_DIR/agent.log"
PIDFILE="$DATA_DIR/agent.pid"
MAX_LOG_BYTES=1048576

# Magisk 提供 busybox，但 PATH 在不同版本下不一致，这里显式补上
[ -d /data/adb/magisk ] && PATH="/data/adb/magisk:$PATH"
export PATH

mkdir -p "$LOG_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "${size:-0}" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
  fi
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  # /proc/<pid>/cmdline 必须仍指向我们的二进制，避免 PID 复用误判
  [ -r "/proc/$pid/cmdline" ] || return 1
  case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
    *komari-agent*) return 0 ;;
    *) return 1 ;;
  esac
}

start_agent() {
  # 未配置 endpoint/token 时不启动，避免无意义重试刷日志
  if [ ! -f "$CONFIG" ]; then
    log "config not found: $CONFIG, skip start"
    return 1
  fi
  # Extract the endpoint value, then test it for emptiness.
  #
  # Two portability rules apply here, both learned from Android:
  #   1. /system/bin/grep is toybox and does NOT support the GNU BRE "\+"
  #      operator. A non-empty endpoint would look empty and the agent would
  #      never start.
  #   2. A plain "[^"]*" test cannot tell "" from "x", so the value has to be
  #      extracted before it can be compared against the empty string.
  # sed is POSIX and toybox supports both the script and the \1 backreference.
  endpoint_value=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -n 1)
  if [ -z "$endpoint_value" ]; then
    log "config endpoint is empty, skip start"
    return 1
  fi

  rotate_log
  log "starting agent: $BIN --config $CONFIG"
  # --config 由 agent 解析；setsid 让 agent 脱离本脚本会话
  nohup "$BIN" --config "$CONFIG" >> "$LOG" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$PIDFILE"
  log "agent started pid=$pid"
}

if is_running; then
  log "agent already running pid=$(cat "$PIDFILE" 2>/dev/null), skip"
  exit 0
fi

start_agent

# 看护循环：agent 意外退出则按 5/10/30/60 秒退避重启
backoff=5
while true; do
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      sleep 30
      backoff=5
      continue
    fi
  fi
  log "agent not running, restart in ${backoff}s"
  sleep "$backoff"
  case "$backoff" in
    5) backoff=10 ;;
    10) backoff=30 ;;
    30) backoff=60 ;;
    *) backoff=60 ;;
  esac
  if is_running; then
    continue
  fi
  start_agent
done
