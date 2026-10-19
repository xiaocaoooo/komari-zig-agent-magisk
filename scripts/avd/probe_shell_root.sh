#!/system/bin/sh
# Komari Agent Shell Root 信息可达性探测（AVD userdebug + adb root）
# 输出分节，供 docs/android-shell-root-analysis.md 作为实测证据引用。
# 用法: sh /data/adb/komari-agent/probe/probe_shell_root.sh > /data/adb/komari-agent/probe/probe_out.txt 2>&1

S=/data/adb/komari-agent/probe

section() {
  printf '\n===== %s =====\n' "$1"
}

section "0. identity"
id
getenforce
getprop ro.build.type
getprop ro.build.version.release
cat /proc/sys/kernel/osrelease
getconf PAGE_SIZE 2>/dev/null || true

section "1. /proc files readable (per-resource)"
for f in stat meminfo loadavg uptime net/dev net/tcp net/tcp6 net/udp net/udp6 cpuinfo mounts sys/kernel/osrelease self/auxv self/mountinfo net/if_inet6; do
  if [ -r "/proc/$f" ]; then
    lines=$(wc -l < "/proc/$f" 2>/dev/null | tr -d ' ')
    printf 'OK   /proc/%-28s lines=%s\n' "$f" "${lines:-0}"
  else
    printf 'MISS /proc/%s\n' "$f"
  fi
done

section "2. /proc cpu sample (first 3 lines)"
head -n 3 /proc/stat

section "3. /proc cpuinfo (agent cpuName source)"
head -n 12 /proc/cpuinfo

section "4. /proc meminfo sample"
grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree" /proc/meminfo

section "5. /proc/net/dev"
cat /proc/net/dev

section "6. /proc/net/tcp{,6} udp{,6} line counts (connection counters)"
for f in net/tcp net/tcp6 net/udp net/udp6; do
  printf '%s lines=%s\n' "$f" "$(grep -c ' ' /proc/$f 2>/dev/null || echo 0)"
done

section "7. /proc/mounts (agent disk source)"
cat /proc/mounts

section "8. pid dirs count (processCount source)"
ls -d /proc/[0-9]* 2>/dev/null | wc -l

section "9. command availability (fallback command path)"
for c in df free ip ping nproc su toybox awk grep cat ls head date getprop logcat; do
  found=$(command -v "$c" 2>/dev/null || true)
  printf '%-8s %s\n' "$c" "${found:-MISSING}"
done
# safe_command_path 内是否存在这些命令（agent 的兜底 PATH）
for c in df free ip; do
  for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /opt/rocm/bin; do
    [ -x "$d/$c" ] && printf 'safe-path %s found at %s/%s\n' "$c" "$d" "$c"
  done
done

section "10. mount flags of /data, /data/adb, /system (noexec check)"
awk '{printf "%s | %s | %s\n", $5, $6, $11}' /proc/self/mountinfo | grep -E "^/(data|system|vendor|apex)" | head -n 30
cat /proc/mounts | grep -E " /data | /system | /vendor "

section "11. /dev nodes (pty source)"
ls -l /dev/ptmx 2>&1
mount | grep -E "pts|dev" | head -n 10
ls /dev/pts 2>&1 | head -n 3

section "12. CA / TLS (agent https support)"
ls /etc/ssl/cert.pem /etc/ssl/certs 2>&1
ls /system/etc/security/cacerts 2>/dev/null | head -n 3
printf 'cacerts count: %s\n' "$(ls /system/etc/security/cacerts 2>/dev/null | wc -l)"
ls /apex/com.android.conscrypt/cacerts 2>/dev/null | head -n 3

section "13. kernel/osrelease + virtualization"
cat /proc/sys/kernel/osrelease
grep -E "model name|hardware|Processor|CPU implementer|CPU part|Features" /proc/cpuinfo | head -n 8

section "14. toybox ping / ip applets"
toybox ping 2>&1 | head -n 2
toybox ip 2>&1 | head -n 2
which ping ip 2>&1

section "15. PATH / env in root shell"
printf 'PATH=%s\n' "$PATH"
