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
| 2 | 设置时区 | 回车默认 `Asia/Singapore` |
| 3 | 添加公钥 | 粘贴公钥，或从 `https://github.com/<用户名>.keys` 拉取；确认用户、主目录和目标路径后用 `ssh-keygen -l` 校验；重复的不加，写入或权限设置失败不报成功，全部无效时返回失败 |
| 4 | 创建 admin 用户 | 默认用户名 `admin`，已有同名组时复用；复制 root 的公钥，加入 sudo 组，可选免密 sudo（`/etc/sudoers.d/90-<用户>`，visudo 校验）；账户、公钥或 sudo 配置失败立即停止本步骤，不标记为可用管理员 |
| 5 | 修改 SSH 端口 | 回车默认 6090；UFW 已启用时先放行新端口；过渡期同时保留旧端口，确认新端口能登录后再关闭旧端口（sshd + UFW）；自动处理 `ssh.socket` |
| 6 | 安装 UFW | 启用前自动放行当前 SSH 端口，默认拒绝入站 |
| 7 | 安装 fail2ban | `/etc/fail2ban/jail.d/sshd.local`：端口跟随 SSH，systemd 后端，10 分钟内失败 5 次封 1 小时 |
| 8 | 设置 swap | 已有 swap 则跳过；内存 <2G 建 2G，2–4G 与内存相同，>4G 建 4G；`swappiness=10` |
| 9 | TCP 调优 | 开启 BBR + fq + `tcp_mtu_probing=1` |
| 10 | 禁用密码登录 | 没有任何用户配置有效公钥时拒绝执行，并要求确认已测试密钥登录 |
| 11 | 禁用 root 登录 | 需要一个带公钥的 sudo 用户；写入 `PermitRootLogin no` + `AllowUsers <用户>`，可选锁定 root 密码 |
| 12 | 修改 hostname | 输入新主机名；回车默认 `Host` + 当天系统日期（`YYYYMMDD`），如 `Host20261029`；保留大小写，允许 1-63 位字母、数字和连字符，首尾不能是连字符 |
| 13 | ALL | 按安全顺序：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → **暂停，另开窗口测试新端口 + admin 登录** → 10 → 11 → 关闭旧端口 → 12 |
| 14 | 查看当前状态 | 端口、登录用户、UFW、fail2ban，并给出本机 `~/.ssh/config` 片段 |
| 0 | 退出 | |

## 防锁死设计

- SSH 配置统一写入 `/etc/ssh/sshd_config.d/00-quicksetup.conf`，在主配置第一行直接 `Include` 该文件以保证单值配置优先级；保留原有其他配置。修改前备份到 `/root/quicksetup-backup/<时间>/`，`sshd -t` 校验失败自动回滚，不会重启 sshd。
- 改端口时新旧端口并存，确认新端口能登录后才关旧端口。
- SSH 重启 / 重载后检查服务状态和预期监听端口，通过后才清理快照、关闭旧防火墙入口；失败则恢复原配置并尝试重新启动，恢复失败时保留快照供人工处理。
- 切换 `ssh.socket` 时同时备份和处理 Ubuntu 遗留的 `00-socket.conf` / `addresses.conf`，重新加载 systemd；失败时恢复文件和原 socket 启用、运行状态。
- 临时快照、配置复制或持久备份失败时拒绝修改 SSH；同一轮运行保留每个文件的首份持久备份。恢复时先在目标文件系统完整暂存，再替换配置，暂存失败不删除现有目录；缺失目录会按原状态恢复。未完成恢复的快照不会被下一次操作覆盖。受管主配置或目录使用符号链接时需人工处理。
- 禁用密码 / 禁用 root 前都会检查公钥并要求确认已测试登录。
- 收紧登录前用 `sshd -T` 和当前连接参数对应的 `sshd -T -C` 核对 root、带公钥用户的有效策略；若存在 `Match` 或非标准 `Include`，拒绝自动收紧，需先人工审查。已有其他 `AllowUsers` 条目导致“只允许所选用户”无法成立时也会回滚。
- **执行 10、11、关闭旧端口前，务必另开一个终端窗口测试登录成功，当前窗口不要关。**

## 生成的文件

- `/etc/ssh/sshd_config.d/00-quicksetup.conf`
- `/etc/fail2ban/jail.d/sshd.local`
- `/etc/sysctl.d/99-quicksetup-swap.conf`、`/etc/sysctl.d/99-quicksetup-tcp.conf`
- `/etc/modules-load.d/quicksetup-bbr.conf`
- `/etc/sudoers.d/90-<用户>`
- `/swapfile`
- `/etc/hostname`（更新静态和当前主机名）、`/etc/hosts`（维护一条带标记的本机解析记录，保留原有记录）

修改 hostname 前会备份配置；设置或校验失败时尝试恢复。默认日期在进入该步骤时读取，按 VPS 当前时区计算，不是脚本发布时的固定日期。

脚本里不包含任何密钥或密码，公钥在运行时输入。

## 回归测试

```bash
bash -n setup.sh
bash tests/regression.sh
```

测试通过临时目录和命令模拟验证失败处理，不安装软件、不改动真实 SSH / UFW / systemd 配置。实际 VPS 上仍需另开窗口测试登录。
