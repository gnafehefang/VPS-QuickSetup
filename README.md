# VPS-QuickSetup

新装系统的 VPS 一键初始化脚本（Debian / Ubuntu），交互式菜单，每一步可重复执行，已经配置过的会自动跳过。

## 使用

以 root 登录新 VPS 后执行（非 root 会自动通过 sudo 重新运行）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh)
```

## 菜单

| 选项 | 功能 | 说明 |
|---|---|---|
| 1 | 系统更新 + 基础工具 | `apt update && apt upgrade`，安装 curl wget sudo 等 |
| 2 | 添加公钥 | 粘贴公钥，或从 `https://github.com/<用户名>.keys` 拉取；用 `ssh-keygen -l` 校验，重复的不加 |
| 3 | 创建 admin 用户 | 默认用户名 `admin`，复制 root 的公钥，加入 sudo 组，可选免密 sudo（`/etc/sudoers.d/90-<用户>`，visudo 校验） |
| 4 | 修改 SSH 端口 | 回车默认 6090；UFW 已启用时先放行新端口；过渡期同时保留旧端口，确认新端口能登录后再关闭旧端口（sshd + UFW）；自动处理 `ssh.socket` |
| 5 | 安装 UFW | 启用前自动放行当前 SSH 端口，默认拒绝入站 |
| 6 | 安装 fail2ban | `/etc/fail2ban/jail.d/sshd.local`：端口跟随 SSH，systemd 后端，10 分钟内失败 5 次封 1 小时 |
| 7 | 禁用密码登录 | 没有任何用户配置有效公钥时拒绝执行，并要求确认已测试密钥登录 |
| 8 | 禁用 root 登录 | 需要一个带公钥的 sudo 用户；写入 `PermitRootLogin no` + `AllowUsers <用户>`，可选锁定 root 密码 |
| 9 | 设置时区 | 回车默认 `Asia/Shanghai` |
| 10 | 设置 swap | 已有 swap 则跳过；内存 <2G 建 2G，2–4G 与内存相同，>4G 建 4G；`swappiness=10` |
| 11 | TCP 调优 | 开启 BBR + fq + `tcp_mtu_probing=1` |
| 12 | ALL | 按安全顺序：1 → 9 → 2 → 3 → 4 → 5 → 6 → 10 → 11 → **暂停，另开窗口测试新端口 + admin 登录** → 7 → 8 → 关闭旧端口 |
| 13 | 查看当前状态 | 端口、登录用户、UFW、fail2ban，并给出本机 `~/.ssh/config` 片段 |
| 0 | 退出 | |

## 防锁死设计

- SSH 配置统一写入 `/etc/ssh/sshd_config.d/00-quicksetup.conf`（必要时在主配置顶部补 `Include`），修改前备份到 `/root/quicksetup-backup/<时间>/`，`sshd -t` 校验失败自动回滚，不会重启 sshd。
- 改端口时新旧端口并存，确认新端口能登录后才关旧端口。
- 禁用密码 / 禁用 root 前都会检查公钥并要求确认已测试登录。
- **执行 7、8、关闭旧端口前，务必另开一个终端窗口测试登录成功，当前窗口不要关。**

## 生成的文件

- `/etc/ssh/sshd_config.d/00-quicksetup.conf`
- `/etc/fail2ban/jail.d/sshd.local`
- `/etc/sysctl.d/99-quicksetup-swap.conf`、`/etc/sysctl.d/99-quicksetup-tcp.conf`
- `/etc/modules-load.d/quicksetup-bbr.conf`
- `/etc/sudoers.d/90-<用户>`
- `/swapfile`

脚本里不包含任何密钥或密码，公钥在运行时输入。
