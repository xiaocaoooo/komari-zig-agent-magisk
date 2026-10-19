# Android Shell Root 信息可达性分析（AVD 实测）

本文回答一个问题：**在 Magisk 根 shell（Android Shell Root）环境下，Komari Agent 需要的信息源能拿到什么、拿不到什么、拿不到的必须怎么补。**

结论先行：agent 的**采集类功能**在 Shell Root 下几乎全部真实可用；只有 **DNS 解析**与 **CPU 型号**两项存在真实缺口，且都能在模块层或极小的 Zig 改动内解决。

## 1. 测试环境与方法

| 项 | 值 |
| --- | --- |
| 设备 | Android Emulator `komari_avd`（AVD），`emulator-5554` |
| 系统镜像 | `system-images;android-35;google_apis;arm64-v8a`（userdebug） |
| 内核 | `6.6.30-android15-8-gdd9c02ccfe27-ab11987101-4k`（4K 页） |
| Android | 15，`ro.build.type=userdebug` |
| Root | `adb root` → `uid=0(root)`，`context=u:r:su:s0` |
| SELinux | `Enforcing`（另在 `Permissive` 的旧 AVD 上复测，结论一致） |
| Agent | `komari-zig-agent` ReleaseSmall，`aarch64-linux-musl` 静态，7,166,936 B |
| 方法 | 所有结论均来自 AVD 上真实执行，原始输出存于 `.narrafork/avd-probe/evidence/` |

探测脚本：[.narrafork/avd-probe/probe_shell_root.sh](.narrafork/avd-probe/probe_shell_root.sh)（环境）、
[.narrafork/avd-probe/probe_binary.sh](.narrafork/avd-probe/probe_binary.sh)（二进制能力）、
[.narrafork/avd-probe/pty_probe.zig](.narrafork/avd-probe/pty_probe.zig)（PTY 往返）。

## 2. 逐资源可达性矩阵

`OK` = agent 真实取到并已在上报载荷中确认；`缺口` = 实测失败，需修复。

### 2.1 CPU

| 数据 | 来源 | 结果 | 证据 |
| --- | --- | --- | --- |
| 核心数 | `/proc/stat` 的 `cpuN` 行 | OK，`cpu_cores: 4` | `probe_02_binary.txt` §I 同源；上报载荷 `cpu_cores: 4` |
| CPU 占用率 | `/proc/stat` 两次采样差分 | OK，真实值如 `37.89%`（非 0.001 兜底） | `evidence/report.jsonl` 第 2 条 |
| 负载 | `/proc/loadavg` | OK，`load1: 2.3 / load5: 2.14 / load15: 1.33` | `evidence/report.jsonl` |
| **CPU 型号** | `/proc/cpuinfo` | **缺口 → 上报 `"Unknown"`** | 见 §3.1 |
| 物理核数 | `/proc/cpuinfo` | 缺口，上报 `cpu_physical_cores: 0` | 同上 |

### 2.2 内存 / Swap

| 数据 | 来源 | 结果 | 证据 |
| --- | --- | --- | --- |
| 总内存 | `/proc/meminfo` `MemTotal` | OK，`2,592,759,808 B`（2472 MiB） | `probe_02_binary.txt` §I |
| 已用内存 | `MemFree/Cached/SReclaimable/Buffers/Shmem` 推导 | OK，真实非零 | `report.jsonl` |
| Swap | `SwapTotal/SwapFree/SwapCached` | OK，`1,944,563,712 B`（zram） | `report.jsonl` |
| 进程数 | 枚举 `/proc/<pid>` 数字目录 | OK，`process: 304` | `report.jsonl` |
| 运行时长 | `/proc/uptime` | OK，`uptime: 635` | `report.jsonl` |

### 2.3 磁盘

| 数据 | 来源 | 结果 | 证据 |
| --- | --- | --- | --- |
| 容量/用量 | 原生 `statfs` 系统调用 | OK，`disk_total: 14,025,232,384 B` | `report.jsonl` |
| 挂载点枚举 | `/proc/mounts` | OK，141 条 | `probe_01_base.txt` §7 |
| 伪文件系统过滤 | `isPhysicalMount` | OK，apex/tmpfs/overlay 全部正确排除 | §4 复算验证 |

关键结论：磁盘**不依赖 `df`**。虽然 Android 有 `/bin/df`，但热路径走原生 `statfs`，即使无 `df` 也不降级。

### 2.4 网络

| 数据 | 来源 | 结果 | 证据 |
| --- | --- | --- | --- |
| 吞吐计数 | `/proc/net/dev` | OK，`totalUp/totalDown` 真实增长 | `report.jsonl` 多条对比 |
| 连接数 | `/proc/net/{tcp,tcp6,udp,udp6}` | OK，`tcp: 17, udp: 10` | `report.jsonl` |
| 网卡枚举 | `/proc/net/dev` | OK，`[dummy0 ifb0 … eth0 wlan0]` | `probe_02_binary.txt` §K |
| 本地 IPv4 | `ip route get`（`/bin/ip` 存在） | OK，`10.0.2.15` | `probe_01_base.txt` §9 |
| 本地 IPv6 | `ip -6 route get` | OK，`fec0::…` | 同上 |
| 公网 IP 探测 | 内置 provider 列表（HTTPS） | OK（DNS 正常时） | 见 §3.2 |

### 2.5 ICMP Ping

| 模式 | 结果 | 证据 |
| --- | --- | --- |
| `raw`（SOCK_RAW） | **OK**，回环 `0 ms`；网关 `2 ms` | `probe_02_binary.txt` §D/§G |
| `datagram`（SOCK_DGRAM） | **OK** | §F |
| `auto`（自动降级） | **OK** | §E |

结论：Android 上 ICMP 三种模式全部真实可用，无需 `ping` 命令，也无需 root 之外的额外权限。

### 2.6 终端 / Web SSH（PTY）

这是最需要确认的一项，因为 musl 静态二进制的 `forkpty` 在 Android 上并非显然可用。

| 检查 | 结果 |
| --- | --- |
| `/dev/ptmx` 存在且可打开 | OK（`crw-rw-rw- 5,2`） |
| `/dev/pts` devpts 已挂载 | OK（`ptmxmode=000`） |
| `forkpty` 返回 master fd | OK，`pid=4057 master_fd=3` |
| 子进程获得真实 tty | OK，`/dev/pts/0` |
| 从 master 读子进程输出 | OK，读到 `PTY_ROUNDTRIP_OK` / `0`（uid） |
| 向 master 写命令 | OK，回显 `echo WRITE_PATH_OK` |

原始输出：

```text
forkpty pid=4057 master_fd=3
READ[33] PTY_ROUNDTRIP_OK
0
/dev/pts/0

total_bytes=33
WRITE_ECHO[20] echo WRITE_PATH_OK
```

结论：**Web SSH / Terminal 在 Shell Root 下可真实工作**，无需改动 zigpty。

### 2.7 TLS / HTTPS

| 检查 | 结果 |
| --- | --- |
| `/etc/ssl/certs` | **不存在**（`/etc` → `/system/etc`） |
| Android CA 库 | `/system/etc/security/cacerts` 145 个，`/apex/com.android.conscrypt/cacerts` 145 个 |
| 带 `--custom-dns` 的 HTTPS 请求 | **OK**，真实完成 TLS 并拿到响应体 |
| 无 `--custom-dns` 的 HTTPS 请求 | **失败**（`NameServerFailure`），见 §3.2 |

关键区分：TLS **本身**在 Android 上可用（能完成握手并解析 JSON 响应），
失败的是它前面的 **DNS 解析**。`/etc/ssl` 缺失未阻止握手，说明 Zig 的 CA bundle 加载在 Android 上仍取得了可用根证书；
这一点在 §3.2 的 HTTPS 成功案例中已由真实请求间接证明。

### 2.8 可执行命令

`/bin -> /system/bin`、`/etc -> /system/etc` 这两个符号链接是关键：agent 的
`safe_command_path`（`/usr/local/sbin:…:/sbin:/bin:/opt/rocm/bin`）在 Android 上实际命中 `/bin/*`。

| 命令 | safe_command_path 命中 | 用途 |
| --- | --- | --- |
| `df` | `/bin/df` | 磁盘兜底（未使用，走 statfs） |
| `free` | `/bin/free` | 内存兜底（仅 `check-mem` 诊断） |
| `ip` | `/bin/ip` | IP 探测（**实际使用**） |
| `getprop` | `/bin/getprop` | Android 识别（**实际使用**） |
| `ping` / `nproc` | `/bin/ping` / `/bin/nproc` | 未使用（原生实现） |

### 2.9 写入与执行权限

| 检查 | 结果 |
| --- | --- |
| `/data/adb` 可写 | OK |
| 在 `/data/adb` 放置并执行静态 ELF | OK（`--show-warning`、`socket-timeout-smoke` 均 exit=0） |
| `/data` 挂载 | `rw,nosuid,nodev,noatime` — **无 noexec**，可直接执行 |

结论：模块把二进制放 `/data/adb/...` 并直接执行是可行的，不需要 linker 转发兜底。

### 2.10 Android 识别

| 检查 | 结果 |
| --- | --- |
| `getprop ro.build.version.release` | `15` |
| 上报 `os` 字段 | `Android 15 (google sdk_gphone64_arm64)` — 已正确识别 |

说明 `detectAndroid` 在 AVD 上真实生效。

## 3. 两个真实缺口

### 3.1 CPU 型号为 `Unknown`

**现象**：上报 `cpu_name: "Unknown"`。

**根因**：AVD 的 `/proc/cpuinfo` 只有 `CPU implementer: 0x61` 与 `CPU part: 0x000`，
没有 `model name` / `Model` / `Hardware` / `Processor` 任一字段。agent 的
`parseCpuNameFromCpuInfo` 会尝试用 ARM implementer+part 映射出型号，但 `part=0x000` 不在映射表中。

```text
CPU implementer : 0x61
CPU part        : 0x000     ← 不在 armCpuNameFromIds 映射表内
```

**影响**：面板显示 `Unknown`。仅影响展示，不影响任何监控数值。

**修复选项**（按侵入性排序）：
1. 模块层：无解（cpuinfo 由内核提供，模块无法改）。
2. 读取 Android 属性 `ro.soc.model` / `ro.board.platform` / `ro.hardware` 作为补充来源。
   这是 Android 上唯一可靠的 SoC 名称来源，真机普遍有值。
3. 扩充 `armCpuNameFromIds` 的 implementer/part 表。

本仓库的模块方案采用 **2**（见 `docs/avd-module-test-report.md` 的实现说明），
因为它在真机与 AVD 上都成立，且不需要维护庞大的 part 表。

### 3.2 默认 DNS 解析失败（最重要）

**现象**：不带 `--custom-dns` 时，agent 所有域名解析失败：

```text
[debug] report websocket connect attempt 1 failed: NameServerFailure
[debug] public IP lookup (ipv4) failed via https://www.visa.cn/cdn-cgi/trace: NameServerFailure
[debug] public IP lookup (ipv4) exhausted all providers
```

**根因**：Android 没有 `/etc/resolv.conf`（`/etc` → `/system/etc`，其中无此文件）。
DNS 服务器只存在于系统属性里：

```text
[vendor.net.wlan0.dns1]: [10.0.2.3]
```

agent 的默认路径 `dns.resolveHost` 在 `custom_dns` 为空时走 `net.resolveAll`
（即 libc `getaddrinfo`）。musl **静态链接**的 `getaddrinfo` 在 Android 上没有 bionic 的
netd socket 通道，读不到系统属性，因此解析必然失败。

**为什么 `--custom-dns` 能绕过**：指定后走 agent 自带的**内置 UDP DNS 客户端**
（`queryServer` → 直接发 DNS 报文），完全不经过 libc。实测 `--custom-dns 1.1.1.1`
与 `--custom-dns 10.0.2.3` 都成功：

```text
[debug] tcp connect established via 198.18.0.250:443
[debug] public IP lookup (ipv4) resolved via https://www.visa.cn/cdn-cgi/trace: 223.104.84.120
[debug] websocket transport connected host=api.github.com port=443
```

**结论**：这不是 TLS 问题，也不是网络问题，而是**解析器选择**问题。

**修复方案**：模块在生成 `config.json` 时自动探测 Android DNS 并写入 `custom_dns`：

```sh
# 优先取 wlan0 / eth0 / rmnet* 的 dns1 属性
for iface in wlan0 eth0 rmnet_data0 rmnet0; do
  dns=$(getprop "vendor.net.${iface}.dns1" 2>/dev/null)
  [ -n "$dns" ] && break
done
```

该方案在 AVD（`vendor.net.wlan0.dns1=10.0.2.3`）与真机（`vendor.net.rmnet_data0.dns1=…`）上均成立，
且复用 agent 已有的内置 DNS 客户端，无需改 Zig。

## 4. 磁盘过滤逻辑复算

用 AVD 实测的 `/proc/mounts` 复现 `isPhysicalMount` + `diskDeviceKey`：

- 103 个挂载点 → 50 个唯一设备
- **78 个 apex 挂载点中，0 个被误判为物理设备**（正确排除）
- 最终计入：`/`、`/data`、`/metadata`、`/vendor`、`/product`、`/mnt/scratch` 等真实分区
- 上报 `disk_total: 14,025,232,384 B` ≈ 13.06 GiB，与 `/data` 分区量级一致

## 5. 功能逐项结论

| 功能 | Shell Root 下 | 依据 |
| --- | --- | --- |
| BasicInfo (v1/v2, gzip) | 真实可用 | `v2_rpc.jsonl`：370 B，gzip，`agent.basicInfo` |
| Report WebSocket | 真实可用 | `report.jsonl`：21 条真实载荷 |
| CPU / 内存 / Swap / 负载 / 磁盘 / 网络 / 连接数 | 真实可用 | 见 §2 |
| 任务执行 (exec) | 真实可用 | 静态 ELF 可执行、`/data` 无 noexec |
| Terminal / Web SSH | 真实可用 | §2.6 PTY 往返 |
| ICMP Ping（raw/datagram/auto） | 真实可用 | §2.5 |
| 公网 IP 探测 | 需 DNS 正常 | §3.2 |
| 自更新 | 需 DNS 正常 | 依赖 GitHub HTTPS |
| Android 识别 | 真实可用 | `Android 15 (google sdk_gphone64_arm64)` |
| CPU 型号 | **缺口** | §3.1 |
| 默认 DNS | **缺口** | §3.2 |

## 6. 对模块设计的硬性要求

由上述实测直接导出：

1. **必须**在 `config.json` 中写入 `custom_dns`（从 `vendor.net.<iface>.dns1` 探测），否则 agent 无法连任何面板。
2. **应当**补 CPU 型号：从 `ro.soc.model` / `ro.board.platform` / `ro.hardware` 取，作为 `cpu_name` 的补充。
3. 二进制放 `/data/adb/...` 直接执行即可，**不需要** linker 转发或 noexec 兜底。
4. **不需要**为 PTY/Web SSH 做任何 Android 特殊处理。
5. **不需要**依赖 `df` / `free` / `ping` 命令，热路径均为原生实现。
6. `--show-warning`、`socket-timeout-smoke`、`ping-test` 可直接用作模块安装后的健康检查。
