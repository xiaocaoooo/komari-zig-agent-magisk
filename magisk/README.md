# Komari Agent (Zig) — Magisk 模块

把 [komari-zig-agent](https://github.com/luodaoyi/komari-zig-agent) 以 Magisk 模块形式常驻在 Android 上。
agent 是单个静态链接的 `aarch64-linux-musl` 二进制，无需 Termux、无需 Python、无常驻 Java 进程。

## 支持范围

| 项 | 说明 |
| --- | --- |
| 架构 | `arm64-v8a`（aarch64） |
| Magisk | ≥ 24.0 |
| Android | 8.0+（实测 Android 15） |
| 根方案 | Magisk（KernelSU/APatch 兼容，走标准模块目录） |

## 安装

1. 从 Release 下载 `komari-agent-magisk-module-arm64.zip`。
2. Magisk App → 模块 → 从本地安装 → 选择该 zip → 重启。

首次安装会在 `/data/adb/komari-agent/` 下生成：

```text
/data/adb/komari-agent/
├── bin/komari-agent      # agent 二进制
├── config.json           # 配置（已自动写入 custom_dns）
└── logs/agent.log        # 运行日志
```

## 配置

编辑 `/data/adb/komari-agent/config.json`，至少填入 `endpoint` 与 `token`：

```json
{
  "endpoint": "https://komari.example.com",
  "token": "your-token",
  "interval": 3,
  "info_report_interval": 5,
  "protocol_version": 2,
  "custom_dns": "10.0.2.3",
  "month_rotate": 0,
  "debug_log": false
}
```

改完后重启设备，或手动重启进程：

```sh
su -c 'kill "$(cat /data/adb/komari-agent/agent.pid)"'
su -c 'sh /data/adb/modules/komari_agent/service.sh &'
```

### 关于 `custom_dns`（重要）

Android **没有** `/etc/resolv.conf`，DNS 服务器只存在于系统属性
`vendor.net.<iface>.dns1` 中。本模块的静态 musl 二进制使用 libc `getaddrinfo`
时读不到这些属性，因此**必须**通过 `custom_dns` 指定 DNS，否则无法解析面板域名。

模块的 `install.sh` 会自动探测并写入该值。若你的设备使用了私有 DNS（DoT）或
DNS 位于非常规属性，请手动填入可用 DNS，例如：

```json
"custom_dns": "223.5.5.5"
```

`custom_dns` 支持逗号分隔多个服务器，也支持 IPv6（会自动补 `[addr]:53`）。

### 其他常用配置

| 字段 | 说明 |
| --- | --- |
| `include_nics` / `exclude_nics` | 只统计/排除指定网卡，支持 `*` 通配 |
| `include_mountpoints` | 只统计指定挂载点，分号分隔 |
| `month_rotate` | 月流量重置日（0 = 关闭） |
| `disable_web_ssh` | 关闭 Web SSH |
| `disable_auto_update` | 关闭自更新 |
| `enable_gpu` | 采集 GPU 信息 |
| `debug_log` | 输出调试日志 |

完整字段见上游 README。

## 验证

```sh
# 进程是否在跑
su -c 'cat /data/adb/komari-agent/agent.pid; ps -A | grep komari'

# 查看日志
su -c 'tail -n 50 /data/adb/komari-agent/logs/agent.log'

# 二进制自检
su -c '/data/adb/komari-agent/bin/komari-agent --show-warning'
su -c '/data/adb/komari-agent/bin/komari-agent socket-timeout-smoke'

# ICMP 连通性（raw / datagram / auto）
su -c '/data/adb/komari-agent/bin/komari-agent ping-test icmp 1.1.1.1'
```

日志中看到以下两行说明采集正常：

```text
Monitoring Mountpoints: [...]
Monitoring Interfaces: [...]
```

## 卸载

Magisk App 中移除模块并重启。`/data/adb/komari-agent/` 下的配置与日志会保留，
如需彻底清除：

```sh
su -c 'rm -rf /data/adb/komari-agent'
```

## 已知限制

- **CPU 型号**：AVD 的 `/proc/cpuinfo` 不含型号字段，会显示 `Unknown`；真机通常可从
  `ro.soc.model` 等属性取得。
- **公网 IP 探测**：依赖 `custom_dns` 正确配置。
- **自更新**：同样依赖 DNS；若面板在内网，请设 `disable_auto_update: true`。
- 模块不修改 `/system`，不注入 Zygisk，纯用户态进程。
