# Shadowsocks 多用户管理脚本

> Shadowsocks-Rust 多用户管理脚本 · 每用户独立端口 · 独立流量周期 · iptables 双向统计

一个用 Bash 写的 Shadowsocks-Rust 多用户管理工具。适合个人或小团队自建机场、给朋友分享节点使用。

- 每个用户独立端口
- 每个用户独立 30 天流量周期
- 支持"购买 N 个月，每月 X GB"的套餐模型
- 流量超限自动禁用，下个周期自动恢复
- 到期永久禁用，需续费才能恢复
- iptables 统计 TCP + UDP 双向流量
- iptables 重建不丢已统计流量
- 自动生成 `ss://` 导入链接（SIP002）
- 一键安装、更新、卸载 Shadowsocks-Rust

---

## 目录

- [特性](#特性)
- [环境要求](#环境要求)
- [安装](#安装)
- [使用](#使用)
- [套餐与状态机](#套餐与状态机)
- [流量统计](#流量统计)
- [数据存储](#数据存储)
- [命令行](#命令行)
- [兼容旧版本](#兼容旧版本)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [License](#license)

---

## 特性

### 用户管理

- 添加 / 删除用户
- 用户列表、用户详情
- 端口冲突检测：新建时若端口被占用，可选择删除旧用户
- 自动生成随机密码
- 自动分配下一个可用端口

### 套餐模型

- 每个用户独立设置：
  - **每月流量**（如 `200G`，`0` 表示不限）
  - **购买周期数**（每个周期 30 天）
- `created_at` 永久固定，不因重置 / 续费改变
- `expire = created_at + periods × 30 天`，独立存储
- 每个周期边界自动重置 `used`，若之前因超限被禁用则自动恢复

### 后台显示
https://github.com/SunMoonWithYou/ss_monitoring_panel

### 状态

| 状态 | 含义 | 触发 | 恢复方式 |
|---|---|---|---|
| `正常` | 可正常使用 | 创建 / 周期重置 / 续费 | — |
| `流量超限` | 本周期流量用尽 | `used >= limit` | 下个周期自动 / 手动重置 / 续费 |
| `已到期` | 总有效期结束 | `now >= expire` | 仅"续费"可恢复 |

### 流量统计

- 基于 iptables 自定义链，按**端口**统计
- **TCP + UDP**
- **上行 + 下行** 双向相加
- 使用增量模式（`last_ipt_tcp` / `last_ipt_udp`），iptables 重建、脚本重启都不会丢已统计流量

### 运维

- systemd 管理 `shadowsocks-rust` 服务
- Cron 每 5 分钟自动执行流量检查
- 自动获取服务器公网 IPv4
- 支持导出全部用户的 `ss://` 导入链接

---

## 环境要求

- **系统**：Debian / Ubuntu（推荐 Debian 11+ / Ubuntu 20.04+）
- **权限**：root
- **架构**：x86_64 / aarch64
- **依赖**（脚本会自动安装）：
  - `curl` `jq` `iptables` `tar` `xz-utils` `coreutils`
  - `python3`（推荐，用于中文宽度对齐；没有会退化为按字符数估算）
  - `systemd` `cron`

---

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/ss_manage/main/install.sh?$(date +%s))
```


首次运行会自动：

1. 安装依赖
2. 下载并安装 Shadowsocks-Rust（从 GitHub Releases 拉最新版）
3. 创建 systemd 服务
4. 创建 `/etc/cron.d/ss-manager`
5. 安装自身到 `/usr/local/bin/ss-manager`
6. 进入管理菜单

安装完成后，以后直接运行：

```bash
ss-manager
```

---

## 使用

运行 `ss-manager` 后进入主菜单：

```
┌────────────────────────── 用户管理 ──────────────────────────┐
  1) 添加用户                    2) 删除用户
  3) 用户列表                    4) 用户详情
├──────────────────────── 流量与套餐 ──────────────────────────┤
  5) 重置本周期流量              6) 续费（加周期）
  7) 重置全部用户流量
├────────────────────────── 链接导出 ──────────────────────────┤
  8) 导出全部 SS 导入链接
├──────────────────────── 服务与维护 ──────────────────────────┤
  9) 查看服务状态                10) 查看日志
  11) 更新 Shadowsocks-Rust       12) 手动流量检查
  13) 重建 iptables 规则          14) 卸载
└──────────────────────────────────────────────────────────────┘
  0) 退出
```

### 添加用户

按提示输入：

- **用户名**：唯一
- **端口**：默认自动分配下一个可用端口
- **密码**：留空自动生成 24 位随机密码
- **加密方式**：默认 `aes-256-gcm`
- **每月流量**：如 `200G`、`100M`、`1T`，`0` 表示不限
- **购买周期数**：每个周期 30 天，如 `3` 表示 3 个月

### 用户列表

```
用户名              端口      已使用          每月流量        到期时间              状态
──────────────────────────────────────────────────────────────────────────────────────
test                 20842     36.28 MB        100.00 GB       2026-10-21 15:34:47   正常
```

### 用户详情

显示端口、密码、加密、本周期流量、累计流量、周期数、到期时间、剩余时间、状态，以及 `ss://` 导入链接。

### 重置本周期流量

- 只清空当前周期的 `used`
- 不改 `limit`、`periods`、`expire`、`created_at`
- 若用户当前是"流量超限"，会恢复为"正常"
- 若用户已"到期"，会拒绝，提示使用"续费"

### 续费

- 输入要增加的周期数
- 从 `max(now, expire)` 起算：
  - 未过期：从原到期日往后加
  - 已过期：从今天往后加（不浪费已过期的时间）
- 重置本周期 `used`
- 若用户是"流量超限"或"已到期"，会恢复为"正常"

---

## 套餐与状态机

### 字段说明

| 字段 | 说明 |
|---|---|
| `created_at` | 创建时间，**永久固定** |
| `expire` | 到期时间，初始 = `created_at + periods × 30d`，`renew` 会修改 |
| `periods` | 已购买周期数（展示用） |
| `limit` | 每周期流量上限（字节），`0` = 不限 |
| `used` | 本周期已用流量（字节） |
| `used_total` | 历史累计流量（字节，仅展示） |
| `last_cycle_index` | 上次处理到的周期序号 |
| `last_ipt_tcp` / `last_ipt_udp` | 上次读到的 iptables 计数 |
| `enabled` | 是否启用 |
| `disabled_reason` | `""` / `traffic` / `expired` |

### 状态转换

```
                  ┌──────────────────────────────────┐
   创建 ──────► 正常 ──used >= limit──► 流量超限
                  │  ▲                     │
                  │  └──新周期自动恢复─────┘
                  │
                  └──now >= expire──► 已到期（仅续费可恢复）
```

### 周期计算

- 每个周期固定 30 天
- 周期边界从 `created_at` 往后推，**不依赖 cron 执行时间**
- 即使服务器关机、cron 漏跑，恢复后也能正确重置

公式：

```
cycle_index = floor((now - created_at) / (30 × 86400))
```

当 `cycle_index > last_cycle_index` 时，执行周期推进。

---

## 流量统计

### 原理

给每个用户的端口建立两条 iptables 自定义链：

```
ss-<port>-in   挂在 INPUT  --dport <port>
ss-<port>-out  挂在 OUTPUT --sport <port>
```

- `in`：客户端 → 服务器（**用户上传**）
- `out`：服务器 → 客户端（**用户下载**）
- TCP + UDP 都统计
- `used = in + out`（**上下行相加**）

### 增量累加

为避免 iptables 计数器因重建 / 重启归零导致流量丢失，使用增量模式：

1. 记录上次读到的 `last_ipt_tcp` / `last_ipt_udp`
2. 每次检查时读取当前值，计算差值
3. 差值累加到 `used`
4. 更新 `last_ipt_*` 为当前值

若 `cur < last`（说明 iptables 重建过），则把 `cur` 当作增量。

### 加密开销

统计的是 **SS 加密后的字节数**，比用户实际看到的明文流量略大（协议开销，通常 1%~5%）。这是 iptables 统计方案的共性。

---

## 数据存储

```
/etc/shadowsocks-rust/
├── users.json       # 用户数据（权限 600）
├── config.json      # Shadowsocks-Rust 配置（权限 600）
└── manager.log      # cron 运行日志（权限 600）

/usr/local/bin/ss-manager
/etc/systemd/system/shadowsocks-rust.service
/etc/cron.d/ss-manager
```

### users.json 示例

```json
[
  {
    "name": "Pan",
    "port": 20842,
    "password": "xxxxxxxxxxxxxxxxxxxxxxxx",
    "method": "aes-256-gcm",
    "limit": 214748364800,
    "used": 38035456,
    "used_total": 1320000000,
    "created_at": 1758536087,
    "expire": 1790072087,
    "periods": 3,
    "last_cycle_index": 0,
    "last_ipt_tcp": 12345678,
    "last_ipt_udp": 2345678,
    "next_reset": 1761128087,
    "last_reset": 0,
    "enabled": true,
    "disabled_reason": ""
  }
]
```

---

## 命令行

除了菜单，也支持命令行调用：

| 命令 | 说明 |
|---|---|
| `ss-manager` | 进入管理菜单 |
| `ss-manager traffic-check` | 执行一次流量检查（cron 调用） |
| `ss-manager add` | 添加用户 |
| `ss-manager list` | 用户列表 |
| `ss-manager status` | 查看服务状态 |
| `ss-manager logs` | 查看日志 |
| `ss-manager update` | 更新 Shadowsocks-Rust |
| `ss-manager uninstall` | 卸载 |

### Cron

安装时自动写入 `/etc/cron.d/ss-manager`：

```
*/5 * * * * root /usr/local/bin/ss-manager traffic-check >> /etc/shadowsocks-rust/manager.log 2>&1
```

---

## 兼容旧版本

脚本启动时会自动执行 `migrate_users`，为旧的 `users.json` 补齐新字段：

| 新字段 | 补齐规则 |
|---|---|
| `periods` | 从 `(expire - created_at) / 30d` 反推，最小 1 |
| `last_cycle_index` | `(now - created_at) / 30d` |
| `last_ipt_tcp` / `last_ipt_udp` | 默认 0 |
| `used_total` | 默认等于 `used` |

**升级前请先备份**：

```bash
cp -a /etc/shadowsocks-rust /etc/shadowsocks-rust.bak.$(date +%s)
```

迁移是幂等的，已迁移的字段不会被覆盖。

---

## 常见问题

### Q: 流量统计为什么比客户端显示的多？

A: 统计的是 SS 加密后的字节数，包含协议开销，通常比明文流量多 1%~5%。上下行相加，所以上传 + 下载都计费。

### Q: 用户可以自己改密码吗？

A: 目前只能通过重新添加用户或直接编辑 `users.json` 后执行 `ss-manager update` 或重启服务。后续版本可能加入"修改用户"功能。

### Q: 支持 IPv6 吗？

A: 目前 `ss://` 链接和公网 IP 获取只处理 IPv4。

### Q: 为什么每 5 分钟才更新一次流量？

A: Cron 周期。如需更实时，可改 `/etc/cron.d/ss-manager` 里的 `*/5`。但不建议低于 `*/1`，避免频繁操作 iptables。

### Q: 用户列表中文对齐错位怎么办？

A: 脚本优先使用 `python3` + `unicodedata` 计算显示宽度。确认：

```bash
command -v python3 && python3 -c 'import unicodedata; print("ok")'
```

没有 `python3` 时会退化为按字符数估算，中文会错位。

### Q: 到期用户手动重置流量能恢复吗？

A: 不能。`reset` 对已到期用户会拒绝。到期用户只能用菜单 6「续费」恢复。

### Q: 服务器公网 IP 获取失败怎么办？

A: 脚本按顺序尝试 `api.ipify.org` → `ifconfig.me/ip` → `ipv4.icanhazip.com`。都失败时，`ss://` 链接不会显示，但用户仍可通过其他方式连接。

### Q: 修改了 `users.json` 后需要做什么？

A: 执行一次：

```bash
ss-manager traffic-check
```

或重启服务：

```bash
systemctl restart shadowsocks-rust
```

### Q: 会和其他代理软件冲突吗？

A: 只要不占用相同端口、不操作相同 iptables 链名（`ss-<port>-in` / `ss-<port>-out`）即可。链名是按端口生成的，基本不会冲突。

---

## 卸载

菜单选择 `14) 卸载`，或：

```bash
ss-manager uninstall
```

会删除：

- Shadowsocks-Rust 二进制
- systemd 服务
- Cron
- iptables 规则
- `/etc/shadowsocks-rust/` 整个目录
- `/usr/local/bin/ss-manager`

**卸载不可恢复，请提前备份 `users.json`。**

---

## License

MIT

---

## 致谢

- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
