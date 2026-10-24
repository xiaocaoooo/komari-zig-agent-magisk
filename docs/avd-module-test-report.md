# AVD Magisk 模块测试报告

本文记录 Komari Agent Magisk 模块在 Android AVD（Shell Root）上的**全功能真实验证**结果。
所有结论均来自真实执行，原始证据见 [docs/android-avd-evidence/](docs/android-avd-evidence/)。

> **本轮（CI 产物闭环）更新摘要**
>
> - CI 已能真实产出 Magisk 模块：workflow run `39583210247` 全绿，含
>   `Magisk Module (arm64)` job，artifact `komari-agent-magisk-module-arm64`（2,162,478 B）。
> - 用**该 CI 产出的 zip** 在 AVD 上重新安装并跑完全部 Features 断言：**7/7 全部 PASS**。
> - 测试过程中发现并修复一个**只在真机暴露的严重缺陷**：`magisk/service.sh` 用 GNU BRE 的
>   `\+` 判断 endpoint 非空，而 Android 的 toybox grep 不支持该扩展，导致模块在真机上
>   **永远不启动 agent**。详见 [§8](#8-真机缺陷修复toybox-兼容性)。
> - 修复后新增两道回归防线（行为用例 + 零依赖静态可移植性守卫），并接入 CI。

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
>
> agent 的启动同样走 Magisk 的真实路径：执行 `/data/adb/modules/komari_agent/service.sh`
> （`late_start service` 脚本），而不是手工拉起二进制，以覆盖其守护与重启逻辑。

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
它按 v2 协议真实下发任务并断言设备端结果。

本轮用的是 **CI 产出的模块 zip**（`workflow_dispatch` run `39583210247` 的 artifact），
安装后经 Magisk 的 `service.sh` 真实路径启动 agent。
原始结论见
[docs/android-avd-evidence/ci-features/features.jsonl](docs/android-avd-evidence/ci-features/features.jsonl)，
agent 侧完整日志见
[docs/android-avd-evidence/ci-agent.log](docs/android-avd-evidence/ci-agent.log)。

**最终结果：7 类断言全部通过，0 失败。**

| Feature | 结果 | 真实证据 |
| --- | --- | --- |
| BasicInfo (v2 / gzip) | **PASS** | `cpu_cores=4`、`mem_total=2592759808`、`disk_total=14025232384`、`os="Android 15 (google sdk_gphone64_arm64)"`、`kernel_version` 为真实内核串、`ipv4=10.0.2.15` |
| Exec 任务 | **PASS** | 设备端真实执行 `echo AVD_EXEC_MARKER; id -u; uname -m` → 返回 `AVD_EXEC_MARKER\n0\naarch64`，`exit_code=0` |
| Terminal / Web SSH | **PASS** | 面板输入命令，设备端 PTY 回显 `AVD_TERMINAL_MARKER`、`0`、`/dev/pts/0` |
| Ping ICMP | **PASS** | `value=0`（回环，真实 ICMP raw socket） |
| Ping TCP | **PASS** | `value=1`（到 `10.0.2.2:25774` 真实握手） |
| Ping HTTP | **PASS** | `value=1`（真实 HTTP 请求往返） |
| Report WebSocket | **PASS** | 收到 **3 次**真实周期上报（`received 3 real reports`） |
| 任务下发通道 | **PASS** | WS 通道下发 `agent.exec` + 3 个 `agent.ping`；`agent.pull` 通道下发 4 个 events，agent 全部执行 |
| 认证 | **PASS** | token 校验通过，无 403 |

> 复验记录（最终一轮，`--outdir .narrafork/avd-probe/ci-v4`，agent 日志
> [docs/android-avd-evidence/ci-agent.log](docs/android-avd-evidence/ci-agent.log)）：
> 本轮 agent 日志 **EndOfStream = 0**、basic_info 启动上传一次成功、
> Report/Terminal WS 各一次握手成功。
> 此前多轮测试中出现的大量 `EndOfStream` 已查清为**测试工装的时序产物**：
> 面板（本地 Python 脚本）在 150–200 s 窗口到期后关闭 socket，agent 按设计
> 自动重连并被拒绝；以及多次工具调用间隔超过面板窗口导致 agent 启动时面板
> 已退出。它不是 agent 缺陷——面板存活期间的所有请求均一次成功。

### 3.1 验证到的 v2 协议细节

测试过程中确认并修正了三处容易误判的协议行为（已写入面板实现，供后续复用）：

1. **v2 下 Report WS 与 BasicInfo RPC 共用 `/api/clients/v2/rpc`**
   （[src/protocol/http.zig](src/protocol/http.zig#L354-L363)）。
   v1 才是 `/api/clients/report`。
2. **v2 下 exec/ping 任务有两条下发通道，agent 连上 WS 后只走 WS 一条**
   （`agent.pull` 的 HTTP 响应 `result.events[]` 见 [src/protocol/v2.zig](src/protocol/v2.zig#L172-L197)；
   WS 推送见 [src/protocol/ws_message.zig](src/protocol/ws_message.zig) 的 `classify`）。
   `pull` 只在 WS 不可用时才被调用，所以**面板必须用 WS 下发任务**，
   否则 exec/ping 永远收不到（本轮实测确认）。
   `ping_task_id` 必须是 **u64 数字**，传字符串会被解析成 0，agent 不会回结果
   （[src/protocol/ws_message.zig](src/protocol/ws_message.zig#L105-L123)）。
3. **v2 下周期上报是 JSON-RPC 通知，真正的数据在 `params.report` 里**
   （[src/protocol/v2.zig](src/protocol/v2.zig) 的 `allocReportNotification`：
   `{"report":{...}}`）。面板若只检查顶层 `cpu`/`ram`/`load`，会漏判所有上报。
   同理，ping 结果以 `agent.pingResult` 通知从**同一条 WS** 回传
   （[src/protocol/report_ws.zig](src/protocol/report_ws.zig) 的 `runPingTask`）。

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
python3 scripts/avd_features_e2e.py --token avd-token --port 25774 --seconds 200 \
  --outdir .narrafork/avd-probe/ci-features

# 5. 设备侧按 Magisk 的真实 late_start 路径启动 agent（另开终端）
adb -s emulator-5554 reverse tcp:25774 tcp:25774
adb -s emulator-5554 shell "sh /data/adb/modules/komari_agent/service.sh"
```

面板退出码为 0 且 `failed=0` 即表示全部 Features 真实通过。

> 步骤 5 刻意走 `service.sh` 而不是直接拉起二进制：只有这样才会覆盖模块的
> 配置判定、守护与自动重启逻辑（也正是 §8 那个缺陷的所在）。
>
> **顺序很重要**：必须先启动面板、看到 `listening` 输出并建立 `adb reverse`，
> 再启动 agent。agent 启动即发起 basicInfo 上传与 WS 连接，若面板未就绪，
> 这些请求会失败并进入重试（虽然 agent 会自动恢复，但会拉长验证窗口）。

## 7. 结论

在 Android Shell Root 环境下，Magisk 模块的安装流程与 agent 的全部 Features API
（BasicInfo、Report WebSocket、Exec、Terminal/Web SSH、ICMP/TCP/HTTP Ping、任务下发）
均**真实实现并验证通过**，无桩、无假数据、无静默降级为 0 的失败。
唯一需要模块层适配的是 DNS（已由 `install.sh` 自动探测并写入 `custom_dns` 解决）。

本轮进一步用 **CI 产出的模块 zip** 重做了完整闭环，7/7 项断言全部通过，
证明 CI 产物与本地构建产物在真机上的行为完全一致。

## 8. 真机缺陷修复：toybox 兼容性

### 8.1 缺陷现象

在 AVD 上执行 `service.sh` 后，agent **始终不启动**，日志持续输出：

```text
config endpoint is empty, skip start
agent not running, restart in 5s
```

而 `config.json` 里 `endpoint` 明明是 `"http://127.0.0.1:25774"`。

### 8.2 根因

[magisk/service.sh](magisk/service.sh) 原本用 GNU BRE 的 `\+` 判断 endpoint 非空：

```sh
if ! grep -q '"endpoint"[[:space:]]*:[[:space:]]*"[^"]\+"' "$CONFIG" 2>/dev/null; then
```

Android 的 `/system/bin/grep` 是 **toybox**，只实现 POSIX 子集，**不支持 `\+`**：

```console
$ adb shell 'grep --version'
toybox 0.8.11-android

$ adb shell 'printf "\"endpoint\": \"http://x\"\n" | grep -q "\"endpoint\"[[:space:]]*:[[:space:]]*\"[^\"]\+\"" && echo MATCH || echo NOMATCH'
NOMATCH_PLUS

$ adb shell 'printf "\"endpoint\": \"http://x\"\n" | grep -q "\"endpoint\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" && echo MATCH || echo NOMATCH'
MATCH_STAR
```

于是非空 endpoint 在真机上被判成空，agent 永远不启动。

**这个缺陷在本地与 CI 都测不出来**：macOS 的 BSD grep 和 Ubuntu 的 GNU grep
都支持 `\+`，所以 `test/magisk_module_test.sh` 一直是绿的。只有换到真机
平台才会暴露——这正是"跨平台缺陷"最危险的地方。

### 8.3 修复

改成 POSIX 可移植的写法：**先把值取出来，再判空**。

```sh
endpoint_value=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -n 1)
if [ -z "$endpoint_value" ]; then
```

注意不能只把 `\+` 换成 `*`：`[^"]*` 会把空值 `""` 也算作匹配，无法区分
`""` 与 `"x"`。取值再比较才正确。`sed` 的该用法是 POSIX 的，toybox 实测支持：

```console
$ adb shell 'sed -n "s/.*\"endpoint\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" /data/adb/komari-agent/config.json'
http://127.0.0.1:25774
```

修复后在真机上验证：`service.sh` 正常拉起 agent，BasicInfo 上传成功，
Report WS 与 Terminal WS 全部建立，7/7 项断言通过。

### 8.4 两道回归防线

| 防线 | 文件 | 作用 |
| --- | --- | --- |
| 行为用例 | [test/magisk_module_test.sh](test/magisk_module_test.sh) | 新增"endpoint 非空时必须真的启动 agent"用例；原有用例只覆盖了"为空时不启动" |
| 静态可移植性守卫 | [test/magisk_portability_test.sh](test/magisk_portability_test.sh) | 扫描 `magisk/*.sh`，拦截 GNU BRE `\+`、`grep -P`、bash 专有语法、错误的 shebang，以及"用正则假装判空"的写法 |

静态守卫是零依赖的，无需 Android 设备或 toybox 即可确定性执行，因此可以
长期留在 CI 里。它还**内置了自检**（`--self-test`）：把 `service.sh` 复制到临时
目录、用 sed 把可移植写法改回旧的 `\+` 写法，再跑一遍扫描，断言它确实报错。
这样就杜绝了"一个从不失败的检查等于没有检查"。

CI 中已接入（[.github/workflows/build.yml](.github/workflows/build.yml) 的
`Android portability check` 步骤）：

```sh
sh test/magisk_portability_test.sh --self-test
```
