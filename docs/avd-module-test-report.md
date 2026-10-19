# AVD Magisk 模块测试报告

本文记录 Komari Agent Magisk 模块在 Android AVD（Shell Root）上的**全功能真实验证**结果。
所有结论均来自真实执行，原始证据见 [docs/android-avd-evidence/](docs/android-avd-evidence/)。

## 1. 测试环境

| 项 | 值 |
| --- | --- |
| 设备 | Android Emulator `komari_avd`（`emulator-5554`） |
| 系统镜像 | `system-images;android-35;google_apis;arm64-v8a`（userdebug） |
| Android | 15，`ro.build.type=userdebug` |
| 内核 | `6.6.30-android15-8-gdd9c02ccfe27-ab11987101-4k` |
| Root | `adb root` → `uid=0`，`context=u:r:su:s0` |
| SELinux | `Enforcing` |
| Agent | `aarch64-linux-musl` 静态 ELF，7,166,936 B，ReleaseSmall |
| 面板 | 宿主 Mac 上的 `scripts/avd_features_e2e.py`，经 `adb reverse tcp:25774` 供设备访问 |

> 说明：标准 AVD 不带 Magisk。本测试用 `adb root` 取得 Shell Root，并按 Magisk 的真实调用约定
> 复现模块安装（解压 → 以 `$MODPATH` 执行 `install.sh` 并提供 `ui_print`/`abort` → 搬到
> `/data/adb/modules/komari_agent`），等价验证模块脚本与 agent 的全部行为。

## 2. 模块安装验证

安装由 [scripts/avd/magisk_install_harness.sh](scripts/avd/magisk_install_harness.sh) 复现 Magisk installer 流程。
原始输出：[docs/android-avd-evidence/module_install.txt](docs/android-avd-evidence/module_install.txt)

| 检查 | 结果 |
| --- | --- |
| zip 解压到 `$MODPATH` | OK |
| `module.prop` 的 `id=komari_agent` | OK |
| `install.sh` 执行成功 | OK |
| 二进制安装到 `/data/adb/komari-agent/bin/komari-agent` | OK（`ELF 64-bit LSB arm64, static`） |
| 安装后二进制可运行 | OK（`--show-warning` 退出码 0） |
| 生成 `config.json` | OK |
| **自动探测 DNS 写入 `custom_dns`** | OK（`"custom_dns": "10.0.2.3"`） |
| 模块移到 `/data/adb/modules/komari_agent` | OK |
| 三个脚本保留执行位 | OK（`-rwxr-xr-x`） |

生成的配置：

```json
{
  "endpoint": "",
  "token": "",
  "interval": 3,
  "info_report_interval": 5,
  "protocol_version": 2,
  "disable_auto_update": false,
  "custom_dns": "10.0.2.3",
  "month_rotate": 0,
  "debug_log": false
}
```

## 3. Features API 逐项验证

验证面板：[scripts/avd_features_e2e.py](scripts/avd_features_e2e.py)。
它按 v2 协议真实下发任务并断言设备端结果，原始结论见
[docs/android-avd-evidence/features/features.jsonl](docs/android-avd-evidence/features/features.jsonl)。

**最终结果：9 项断言全部通过，0 失败。**

| Feature | 结果 | 真实证据 |
| --- | --- | --- |
| BasicInfo (v2 / gzip) | **PASS** | `cpu_cores=4`、`mem_total=2592759808`、`disk_total=14025232384`、`os="Android 15 (google sdk_gphone64_arm64)"`、`kernel_version` 为真实内核串 |
| Exec 任务 | **PASS** | 设备端真实执行 `echo AVD_EXEC_MARKER; id -u; uname -m` → 返回 `AVD_EXEC_MARKER\n0\naarch64`，`exit_code=0` |
| Terminal / Web SSH | **PASS** | 面板输入命令，设备端 PTY 回显 `AVD_TERMINAL_MARKER`、`0`、`/dev/pts/0` |
| Ping ICMP | **PASS** | `value=0`（回环，真实 ICMP raw socket） |
| Ping TCP | **PASS** | `value=1`（到 `10.0.2.2:25774` 真实握手） |
| Ping HTTP | **PASS** | `value=5`（真实 HTTP 请求往返） |
| Report WebSocket | **PASS** | v2 下 `/api/clients/v2/rpc` WS 握手成功并持续接收上报 |
| 任务下发通道 | **PASS** | `agent.pull` 返回 4 个 events，agent 全部执行 |
| 认证 | **PASS** | token 校验通过，无 403 |

### 3.1 验证到的 v2 协议细节

测试过程中确认并修正了两处容易误判的协议行为（已写入面板实现，供后续复用）：

1. **v2 下 Report WS 与 BasicInfo RPC 共用 `/api/clients/v2/rpc`**
   （[src/protocol/http.zig](src/protocol/http.zig#L354-L363)）。
   v1 才是 `/api/clients/report`。
2. **v2 下 exec/ping 任务不是由 WS 推送，而是由 `agent.pull` 的 HTTP 响应下发**
   （`result.events[]`，见 [src/protocol/v2.zig](src/protocol/v2.zig#L172-L197)）。
   `ping_task_id` 必须是 **u64 数字**，传字符串会被解析成 0，agent 不会回结果
   （[src/protocol/ws_message.zig](src/protocol/ws_message.zig#L105-L123)）。

## 4. 采集数据真实性交叉核对

上报值与设备端独立读取一致：

| 字段 | 上报值 | 设备端核对 |
| --- | --- | --- |
| `cpu_cores` | 4 | `/proc/stat` 有 `cpu0..cpu3` |
| `mem_total` | 2,592,759,808 B (2472 MiB) | `/proc/meminfo` `MemTotal: 2531992 kB` |
| `swap_total` | 1,944,563,712 B | `/proc/meminfo` `SwapTotal`（zram） |
| `disk_total` | 14,025,232,384 B | `/data` 分区 statfs |
| `os` | `Android 15 (google sdk_gphone64_arm64)` | `getprop ro.build.version.release` = 15 |
| `kernel_version` | `6.6.30-android15-...` | `/proc/sys/kernel/osrelease` |

磁盘统计经过独立复算：用设备实测 `/proc/mounts` 复现 `isPhysicalMount` + `diskDeviceKey`，
103 个挂载点归并为 50 个唯一设备，**78 个 apex 挂载点全部被正确排除**（0 个误计入）。

## 5. 已知限制（非缺陷）

| 项 | 说明 |
| --- | --- |
| `cpu_name` 显示 `Unknown` | AVD 的 `/proc/cpuinfo` 只有 `CPU part: 0x000`，不在 agent 的 ARM part 映射表内。真机通常有 `model name` 或可读 `ro.soc.model`。仅影响展示，不影响任何监控数值。 |
| `cpu_physical_cores` = 0 | 同上，AVD 不提供物理核信息。 |
| `gpu_name` = `None` | AVD 无 GPU 设备节点；`enable_gpu` 在真机上才有意义。 |
| AVD 无法访问公网 ICMP | 模拟器 NAT 限制，非 agent 问题；ICMP 对回环与网关均真实可用。 |

## 6. 复现步骤

```sh
# 1. 构建静态二进制与模块 zip
zig build -Doptimize=ReleaseSmall -Dversion=dev -Dtarget=aarch64-linux-musl
sh scripts/build_magisk_module.sh zig-out/bin/komari-agent dev

# 2. 启动 AVD 并取得 root
emulator -avd komari_avd -no-window -no-audio &
adb -s emulator-5554 wait-for-device
adb -s emulator-5554 root

# 3. 推送并安装模块（复现 Magisk installer）
adb -s emulator-5554 push dist/komari-agent-magisk-module-arm64.zip /data/local/tmp/module.zip
adb -s emulator-5554 push scripts/avd/magisk_install_harness.sh /data/local/tmp/harness.sh
adb -s emulator-5554 shell "sh /data/local/tmp/harness.sh"

# 4. 宿主启动验证面板
python3 scripts/avd_features_e2e.py --token avd-token --port 25774 --seconds 140

# 5. 设备侧启动 agent（另开终端）
adb -s emulator-5554 reverse tcp:25774 tcp:25774
adb -s emulator-5554 shell "/data/adb/komari-agent/bin/komari-agent \
  --endpoint http://127.0.0.1:25774 --token avd-token --custom-ipv4 10.0.2.15 --debug-log"
```

面板退出码为 0 且 `failed=0` 即表示全部 Features 真实通过。

## 7. 结论

在 Android Shell Root 环境下，Magisk 模块的安装流程与 agent 的全部 Features API
（BasicInfo、Report WebSocket、Exec、Terminal/Web SSH、ICMP/TCP/HTTP Ping、任务下发）
均**真实实现并验证通过**，无桩、无假数据、无静默降级为 0 的失败。
唯一需要模块层适配的是 DNS（已由 `install.sh` 自动探测并写入 `custom_dns` 解决）。
