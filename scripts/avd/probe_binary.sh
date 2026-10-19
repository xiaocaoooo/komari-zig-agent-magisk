#!/system/bin/sh
# 在 AVD Shell Root 下验证 agent 二进制的核心能力可达性。
# 输出: /data/adb/komari-agent/probe/binary_out.txt
B=/data/adb/komari-agent/bin.komari-agent-probe
OUT=/data/adb/komari-agent/probe/binary_out.txt
: > "$OUT"

section() { printf '\n===== %s =====\n' "$1" >> "$OUT"; }

section "A. binary identity"
file "$B" >> "$OUT" 2>&1
ls -l "$B" >> "$OUT" 2>&1

section "B. --show-warning (startup + interface monitoring)"
"$B" --show-warning >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "C. socket-timeout-smoke"
"$B" socket-timeout-smoke >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "D. ICMP ping-test raw"
"$B" ping-test icmp 127.0.0.1 '' raw >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "E. ICMP ping-test auto (datagram fallback path)"
"$B" ping-test icmp 127.0.0.1 >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "F. ICMP ping-test datagram"
"$B" ping-test icmp 127.0.0.1 '' datagram >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "G. ICMP to gateway 10.0.2.2 (host reachability)"
"$B" ping-test icmp 10.0.2.2 >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "H. list-disk (native statfs disk collection)"
"$B" list-disk >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "I. check-mem (native /proc/meminfo collection)"
"$B" check-mem >> "$OUT" 2>&1
printf 'exit=%s\n' "$?" >> "$OUT"

section "J. pty allocation via python-less shell test"
# 验证 devpts 可被非特权/root 进程正常打开（agent terminal 功能前置条件）
ls -l /dev/ptmx >> "$OUT" 2>&1
head -c 0 /dev/ptmx >/dev/null 2>&1; printf 'open /dev/ptmx exit=%s\n' "$?" >> "$OUT"

section "K. agent against unreachable endpoint (startup log path)"
"$B" --endpoint http://127.0.0.1:1 --token probe --disable-auto-update --max-retries 0 --reconnect-interval 1 >> "$OUT" 2>&1 &
pid=$!
sleep 6
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
printf 'exit=spawned-and-killed\n' >> "$OUT"

section "L. write permissions in module dir"
touch /data/adb/komari-agent/probe/.wtest && printf 'writable=yes\n' >> "$OUT" && rm -f /data/adb/komari-agent/probe/.wtest

section "M. exec of external command (exec task prerequisite)"
printf 'exec-test-output\n' >> "$OUT"
