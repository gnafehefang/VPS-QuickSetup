#!/usr/bin/env bash
# VPS-QuickSetup - 新 VPS 基础初始化脚本 (Debian / Ubuntu)
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh)
set -o pipefail

SCRIPT_URL="https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh"
QS_CONF="/etc/ssh/sshd_config.d/00-quicksetup.conf"
MAIN_CONF="/etc/ssh/sshd_config"
F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"
SWAP_SYSCTL="/etc/sysctl.d/99-quicksetup-swap.conf"
TCP_SYSCTL="/etc/sysctl.d/99-quicksetup-tcp.conf"
BACKUP_DIR="/root/quicksetup-backup/$(date +%Y%m%d-%H%M%S)"
DEFAULT_PORT=6090
DEFAULT_TZ="Asia/Shanghai"
DEFAULT_ADMIN="admin"
TTY=/dev/tty

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[36m'; c_off=$'\e[0m'
info() { echo "${c_blu}[信息]${c_off} $*"; }
ok()   { echo "${c_grn}[完成]${c_off} $*"; }
skip() { echo "${c_ylw}[跳过]${c_off} $*"; }
warn() { echo "${c_ylw}[注意]${c_off} $*"; }
err()  { echo "${c_red}[错误]${c_off} $*" >&2; }

# ---------- 交互输入 (从 /dev/tty 读, 兼容 bash <(curl ...)) ----------
ask() { # ask "提示" "默认值" -> 结果在 REPLY
  local prompt="$1" def="${2:-}"
  if [[ -n "$def" ]]; then prompt="$prompt [默认: $def]: "; else prompt="$prompt: "; fi
  REPLY=""
  read -r -p "$prompt" REPLY <"$TTY" || REPLY=""
  [[ -z "$REPLY" ]] && REPLY="$def"
  return 0
}
confirm() { # confirm "提示" y|n
  local def="${2:-n}" hint="[y/N]"
  [[ "$def" == y ]] && hint="[Y/n]"
  local ans=""
  read -r -p "$1 $hint: " ans <"$TTY" || ans=""
  [[ -z "$ans" ]] && ans="$def"
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}
pause() { local _x; read -r -p "按回车继续..." _x <"$TTY" || true; }

# ---------- 前置检查 ----------
need_root() {
  [[ $EUID -eq 0 ]] && return 0
  if command -v sudo >/dev/null 2>&1; then
    info "需要 root 权限, 通过 sudo 重新运行..."
    local tmp; tmp=$(mktemp /tmp/quicksetup.XXXXXX.sh)
    if [[ -r "$0" && -f "$0" ]]; then cp "$0" "$tmp"
    else curl -fsSL "$SCRIPT_URL" -o "$tmp" || { err "下载脚本失败"; exit 1; }
    fi
    exec sudo bash "$tmp" "$@"
  fi
  err "请用 root 运行本脚本"; exit 1
}
check_os() {
  [[ -r /etc/os-release ]] || { err "无法识别系统"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != debian && "${ID:-}" != ubuntu && "${ID_LIKE:-}" != *debian* ]]; then
    err "只支持 Debian / Ubuntu (当前: ${PRETTY_NAME:-unknown})"; exit 1
  fi
  [[ -e "$TTY" ]] || { err "没有可用的终端 (/dev/tty)"; exit 1; }
}

apt_install() { # apt_install pkg...
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  info "安装: ${missing[*]}"
  if [[ -z "$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -mmin -1440 2>/dev/null | head -1)" ]]; then
    apt-get update -q || true
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
}

# ---------- SSH 工具函数 ----------
ssh_svc() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1 && systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}
sshd_val() { mkdir -p /run/sshd; sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }
ssh_ports() { mkdir -p /run/sshd; sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un; }

backup_file() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}
ensure_include() {
  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
    backup_file "$MAIN_CONF"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN_CONF"
    info "已在 $MAIN_CONF 顶部加入 Include"
  fi
  [[ -f "$QS_CONF" ]] || { echo "# 由 VPS-QuickSetup 管理" >"$QS_CONF"; chmod 644 "$QS_CONF"; }
}
# 先备份 -> 修改 -> sshd -t 校验 -> 失败回滚
SNAP=""
sshd_snapshot() {
  SNAP=$(mktemp -d)
  cp -a /etc/ssh/sshd_config "$SNAP/main"
  cp -a /etc/ssh/sshd_config.d "$SNAP/d"
  backup_file "$MAIN_CONF"; backup_file "$QS_CONF"
}
sshd_validate_or_rollback() {
  mkdir -p /run/sshd
  if sshd -t; then rm -rf "$SNAP"; return 0; fi
  err "sshd 配置校验失败, 回滚"
  cp -a "$SNAP/main" /etc/ssh/sshd_config
  rm -rf /etc/ssh/sshd_config.d && cp -a "$SNAP/d" /etc/ssh/sshd_config.d
  rm -rf "$SNAP"; return 1
}
qs_set() { # qs_set Key "value"   (在 00-quicksetup.conf 里设置单值项)
  sed -i "/^[[:space:]]*$1[[:space:]]/Id" "$QS_CONF"
  echo "$1 $2" >>"$QS_CONF"
}
sshd_restart() {
  local svc; svc=$(ssh_svc)
  # Ubuntu 22.10+ 的 ssh.socket 会接管端口, 改为传统 ssh.service
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    info "检测到 ssh.socket, 切换为 ssh.service 管理端口"
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
  fi
  systemctl restart "$svc"
}
has_keys() { # has_keys user
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  [[ -n "$home" && -s "$home/.ssh/authorized_keys" ]] && ssh-keygen -l -f "$home/.ssh/authorized_keys" >/dev/null 2>&1
}
login_users_with_keys() {
  local u
  while IFS=: read -r u _ uid _ _ _ sh; do
    [[ "$uid" -eq 0 || "$uid" -ge 1000 ]] || continue
    [[ "$sh" == */nologin || "$sh" == */false ]] && continue
    has_keys "$u" && echo "$u"
  done </etc/passwd
}
sudo_users_with_keys() {
  local u
  for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    [[ "$u" != root ]] && has_keys "$u" && echo "$u"
  done
}

# ---------- 1. 系统更新 ----------
step_update() {
  info "更新系统并安装基础工具..."
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt_install curl wget sudo ca-certificates nano htop unzip
  ok "系统更新完成"
}

# ---------- 2. 添加公钥 ----------
add_key_lines() { # add_key_lines user  (从 stdin 读公钥)
  local user="$1" home grp line tmp
  home=$(getent passwd "$user" | cut -d: -f6); grp=$(id -gn "$user")
  install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  tmp=$(mktemp)
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s\n' "$line" >"$tmp"
    if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then warn "无效公钥, 已忽略: ${line:0:40}..."; continue; fi
    if grep -qxF "$line" "$home/.ssh/authorized_keys"; then skip "已存在: $(ssh-keygen -l -f "$tmp" | awk '{print $2, $NF}')"; continue; fi
    printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
    ok "已添加: $(ssh-keygen -l -f "$tmp" | awk '{print $2, $NF}')"
  done
  rm -f "$tmp"
  chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$grp" "$home/.ssh/authorized_keys"
}
step_pubkey() {
  ask "要给哪个用户添加公钥" "root"; local user="$REPLY"
  id "$user" >/dev/null 2>&1 || { err "用户 $user 不存在 (可先用菜单 3 创建)"; return 1; }
  echo "  1) 粘贴公钥内容 (例如 ssh-ed25519 AAAA... 本机 ~/.ssh/id_ed25519.pub 的内容)"
  echo "  2) 从 GitHub 拉取 (https://github.com/<用户名>.keys)"
  ask "选择" "1"
  case "$REPLY" in
    2) ask "GitHub 用户名" ""; [[ -z "$REPLY" ]] && { err "未输入"; return 1; }
       local keys; keys=$(curl -fsSL "https://github.com/$REPLY.keys") || { err "拉取失败"; return 1; }
       [[ -z "$keys" ]] && { err "该 GitHub 账号没有公钥"; return 1; }
       printf '%s\n' "$keys" | add_key_lines "$user" ;;
    *) ask "粘贴公钥 (一行)" ""; [[ -z "$REPLY" ]] && { err "未输入"; return 1; }
       printf '%s\n' "$REPLY" | add_key_lines "$user" ;;
  esac
  has_keys "$user" && ok "$user 的 authorized_keys 有效" || warn "$user 仍没有有效公钥"
}

# ---------- 3. 创建 admin ----------
ADMIN_USER=""
step_admin() {
  ask "管理员用户名" "$DEFAULT_ADMIN"; local u="$REPLY"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$u" != root ]] || { err "用户名不合法"; return 1; }
  apt_install sudo
  if id "$u" >/dev/null 2>&1; then skip "用户 $u 已存在"
  else useradd -m -s /bin/bash "$u" && ok "已创建用户 $u"; fi
  if id -nG "$u" | tr ' ' '\n' | grep -qx sudo; then skip "$u 已在 sudo 组"
  else usermod -aG sudo "$u" && ok "已加入 sudo 组"; fi
  if has_keys root; then
    grep -v '^[[:space:]]*$' /root/.ssh/authorized_keys | add_key_lines "$u"
  fi
  has_keys "$u" || { warn "$u 还没有公钥, 现在添加"; ask "粘贴 $u 的公钥 (一行, 回车跳过)" ""; [[ -n "$REPLY" ]] && printf '%s\n' "$REPLY" | add_key_lines "$u"; }
  local sf="/etc/sudoers.d/90-$u"
  if [[ -f "$sf" ]] && grep -q NOPASSWD "$sf"; then skip "$sf 已配置免密 sudo"
  elif confirm "sudo 是否免密 (NOPASSWD)?" y; then
    echo "$u ALL=(ALL) NOPASSWD:ALL" >"$sf.tmp"; chmod 440 "$sf.tmp"
    if visudo -cf "$sf.tmp" >/dev/null; then mv "$sf.tmp" "$sf"; ok "已写入 $sf"
    else rm -f "$sf.tmp"; err "sudoers 校验失败, 未写入"; fi
  else
    if passwd -S "$u" 2>/dev/null | awk '{exit !($2=="P")}'; then skip "$u 已有密码"
    else info "请为 $u 设置密码 (sudo 时要用)"; passwd "$u" <"$TTY" >"$TTY" 2>&1 || warn "未设置密码"; fi
  fi
  ADMIN_USER="$u"
  has_keys "$u" && ok "$u 可用密钥登录 (公钥已就绪)"
}

# ---------- 4. 修改 SSH 端口 ----------
PENDING_OLD_PORTS=""
SELECTED_SSH_PORT=""
remove_old_ports() { # remove_old_ports "p1 p2" keep
  local olds="$1" keep="$2" p
  [[ -z "$olds" ]] && return 0
  [[ -n "$keep" && " $olds " != *" $keep "* ]] || { err "保留端口不能为空或同时属于旧端口"; return 1; }
  sshd_snapshot; ensure_include
  sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF"; echo "Port $keep" >>"$QS_CONF"
  sshd_validate_or_rollback || return 1
  sshd_restart
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for p in $olds; do ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p" >/dev/null 2>&1; done
    [[ " $olds " == *" 22 "* ]] && ufw delete allow OpenSSH >/dev/null 2>&1
  fi
  f2b_refresh
  PENDING_OLD_PORTS=""
  ok "已关闭旧端口: $olds, 现在只监听 $keep"
}
step_port() { # step_port [defer]
  local defer="${1:-}" cur new p olds=""
  SELECTED_SSH_PORT=""
  cur=$(ssh_ports | tr '\n' ' '); cur="${cur% }"
  info "当前 SSH 端口: $cur"
  ask "新的 SSH 端口" "$DEFAULT_PORT"; new="$REPLY"
  [[ "$new" =~ ^[0-9]+$ && "$new" -ge 1 && "$new" -le 65535 ]] || { err "端口不合法"; return 1; }
  for p in $cur; do [[ "$p" != "$new" ]] && olds="$olds $p"; done; olds="${olds# }"
  if [[ "$cur" == "$new" ]]; then SELECTED_SSH_PORT="$new"; skip "SSH 已经只监听 $new"; return 0; fi
  if ss -ltnH "( sport = :$new )" 2>/dev/null | grep -q . && [[ " $cur " != *" $new "* ]]; then err "端口 $new 已被其他程序占用"; return 1; fi
  if command -v ufw >/dev/null; then
    local status
    status=$(LC_ALL=C ufw status) || { err "无法读取 UFW 状态, 停止修改 SSH 端口"; return 1; }
    if [[ "$status" == *"Status: active"* ]]; then ufw_allow_ssh "$new" || return 1; fi
  fi
  sshd_snapshot; ensure_include
  # 注释掉其他位置的 Port, 统一由 00-quicksetup.conf 管理
  local f
  for f in "$MAIN_CONF" /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" && "$f" != "$QS_CONF" ]] || continue
    grep -Eq '^[[:space:]]*Port[[:space:]]' "$f" && sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$f"
  done
  sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF"
  for p in $olds $new; do echo "Port $p" >>"$QS_CONF"; done
  sshd_validate_or_rollback || return 1
  sshd_restart
  sleep 1
  if ss -ltnH "( sport = :$new )" | grep -q .; then ok "sshd 已在 $new 监听 (过渡期同时保留: ${olds:-无})"
  else err "sshd 没有监听 $new, 请检查"; return 1; fi
  SELECTED_SSH_PORT="$new"
  f2b_refresh
  [[ -z "$olds" ]] && return 0
  PENDING_OLD_PORTS="$olds"
  if [[ "$defer" == defer ]]; then info "旧端口 $olds 先保留, 最后再关闭"; return 0; fi
  warn "请另开一个窗口测试:  ssh -p $new <用户>@<服务器IP>"
  if confirm "新端口 $new 登录测试成功了吗? 成功则关闭旧端口 $olds" n; then
    remove_old_ports "$olds" "$new"
  else
    warn "旧端口 $olds 仍保留, 测试成功后可再次运行菜单 4 (输入 $new) 来关闭"
  fi
}

# ---------- 5. UFW ----------
ufw_allow_ssh() {
  LC_ALL=C ufw allow "$1/tcp" comment SSH >/dev/null || { err "UFW 放行 $1/tcp 失败"; return 1; }
  ok "UFW 已放行 $1/tcp"
}
step_ufw() {
  apt_install ufw || { err "UFW 安装失败"; return 1; }
  local ports status p
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法确认 SSH 端口, 拒绝启用 UFW"; return 1; }
  for p in $ports; do
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ && "$p" -le 65535 ]] || { err "无效 SSH 端口: $p"; return 1; }
  done
  status=$(LC_ALL=C ufw status) || { err "无法读取 UFW 状态"; return 1; }
  # UFW 自身会跳过重复规则, 不把同端口的 DENY 或受限规则误判成已放行。
  for p in $ports; do ufw_allow_ssh "$p" || return 1; done
  if [[ "$status" == *"Status: active"* ]]; then skip "UFW 已启用"
  else
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1
    ufw --force enable || { err "UFW 启用失败"; return 1; }
    ok "UFW 已启用"
  fi
  ufw status
}

# ---------- 6. fail2ban ----------
f2b_content() {
  local ports; ports=$(ssh_ports | paste -sd, -)
  cat <<EOT
# 由 VPS-QuickSetup 管理
[sshd]
enabled  = true
port     = $ports
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOT
}
f2b_refresh() { # 端口变化后同步 jail
  [[ -f "$F2B_JAIL" ]] || return 0
  local new; new=$(f2b_content)
  [[ "$new" == "$(cat "$F2B_JAIL")" ]] && return 0
  printf '%s\n' "$new" >"$F2B_JAIL"
  systemctl restart fail2ban && info "fail2ban 端口已同步: $(ssh_ports | paste -sd, -)"
}
step_fail2ban() {
  apt_install fail2ban python3-systemd
  local new; new=$(f2b_content)
  if [[ -f "$F2B_JAIL" && "$new" == "$(cat "$F2B_JAIL")" ]] && systemctl is-active fail2ban >/dev/null; then
    skip "fail2ban 已配置并运行"
  else
    backup_file "$F2B_JAIL"
    printf '%s\n' "$new" >"$F2B_JAIL"
    systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban
    sleep 2; ok "fail2ban 已配置"
  fi
  fail2ban-client status sshd 2>/dev/null || warn "fail2ban sshd jail 未就绪, 请检查: journalctl -u fail2ban"
}

# ---------- 7. 禁用密码登录 ----------
step_nopass() {
  if [[ "$(sshd_val passwordauthentication)" == no && "$(sshd_val kbdinteractiveauthentication)" == no ]]; then
    skip "密码登录已禁用"; return 0; fi
  local users; users=$(login_users_with_keys | tr '\n' ' ')
  [[ -z "$users" ]] && { err "没有任何用户配置了有效公钥, 拒绝禁用密码登录 (先用菜单 2)"; return 1; }
  info "已配置公钥的用户: $users"
  confirm "你确认已经用密钥成功登录过吗?" n || { warn "已取消"; return 1; }
  sshd_snapshot; ensure_include
  qs_set PubkeyAuthentication yes
  qs_set PasswordAuthentication no
  qs_set KbdInteractiveAuthentication no
  sshd_validate_or_rollback || return 1
  systemctl reload "$(ssh_svc)" && ok "已禁用密码登录 (仅允许密钥)"
}

# ---------- 8. 禁用 root 登录 ----------
step_noroot() {
  if [[ "$(sshd_val permitrootlogin)" == no ]]; then skip "root 登录已禁用"; return 0; fi
  local cands; cands=$(sudo_users_with_keys | tr '\n' ' '); cands="${cands% }"
  [[ -z "$cands" ]] && { err "没有带公钥的 sudo 用户, 拒绝禁用 root (先用菜单 3)"; return 1; }
  local def="${ADMIN_USER:-${cands%% *}}"
  info "可用的 sudo 用户: $cands"
  ask "保留登录的用户 (将写入 AllowUsers)" "$def"; local u="$REPLY"
  [[ " $cands " == *" $u "* ]] || { err "$u 不是带公钥的 sudo 用户"; return 1; }
  warn "请另开窗口测试:  ssh -p $(ssh_ports | head -1) $u@<服务器IP>  然后执行 sudo -i"
  confirm "$u 密钥登录并 sudo 成功了吗?" n || { warn "已取消"; return 1; }
  sshd_snapshot; ensure_include
  qs_set PermitRootLogin no
  qs_set AllowUsers "$u"
  sshd_validate_or_rollback || return 1
  systemctl reload "$(ssh_svc)" && ok "已禁用 root 登录, 只允许 $u"
  if passwd -S root 2>/dev/null | awk '{exit !($2=="L")}'; then skip "root 密码已锁定"
  elif confirm "是否同时锁定 root 密码 (passwd -l root)?" y; then passwd -l root >/dev/null && ok "root 密码已锁定"; fi
}

# ---------- 9. 时区 ----------
step_tz() {
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
  info "当前时区: ${cur:-未知}"
  ask "时区" "$DEFAULT_TZ"; local tz="$REPLY"
  [[ -f "/usr/share/zoneinfo/$tz" ]] || { err "无效时区: $tz"; return 1; }
  [[ "$cur" == "$tz" ]] && { skip "时区已是 $tz"; return 0; }
  timedatectl set-timezone "$tz" 2>/dev/null || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "$tz" >/etc/timezone; }
  ok "时区已设为 $tz ($(date '+%F %T %Z'))"
}

# ---------- 10. swap ----------
step_swap() {
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    skip "已有 swap:"; swapon --show
  else
    local mem_mb size_mb free_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if   (( mem_mb < 2048 )); then size_mb=2048
    elif (( mem_mb <= 4096 )); then size_mb=$mem_mb
    else size_mb=4096; fi
    free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    if (( free_mb < size_mb + 1024 )); then err "磁盘剩余 ${free_mb}M, 不足以创建 ${size_mb}M swap"; return 1; fi
    info "内存 ${mem_mb}M, 创建 ${size_mb}M /swapfile"
    fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
    chmod 600 /swapfile
    if ! { mkswap /swapfile >/dev/null && swapon /swapfile; }; then
      warn "fallocate 文件不可用, 改用 dd"; swapoff /swapfile 2>/dev/null; rm -f /swapfile
      dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; chmod 600 /swapfile
      mkswap /swapfile >/dev/null && swapon /swapfile || { err "swap 创建失败"; rm -f /swapfile; return 1; }
    fi
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "swap 已启用"; swapon --show
  fi
  if [[ "$(sysctl -n vm.swappiness)" == 10 && -f "$SWAP_SYSCTL" ]]; then skip "swappiness 已是 10"
  else echo "vm.swappiness = 10" >"$SWAP_SYSCTL"; sysctl -q -p "$SWAP_SYSCTL" && ok "swappiness = 10"; fi
}

# ---------- 11. TCP 调优 ----------
step_tcp() {
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    err "内核不支持 BBR ($(uname -r))"; return 1; fi
  if [[ -f "$TCP_SYSCTL" && "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr \
        && "$(sysctl -n net.core.default_qdisc)" == fq && "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 1 ]]; then
    skip "BBR + fq 已启用"; return 0; fi
  cat >"$TCP_SYSCTL" <<EOT
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOT
  echo tcp_bbr >/etc/modules-load.d/quicksetup-bbr.conf
  sysctl -q -p "$TCP_SYSCTL" && ok "已启用 BBR: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}

# ---------- 12. ALL ----------
run_step() { echo; echo "${c_blu}========== $1 ==========${c_off}"; shift; "$@" || { warn "该步骤未完成"; return 1; }; }
step_all() {
  PENDING_OLD_PORTS=""
  SELECTED_SSH_PORT=""
  run_step "1. 系统更新" step_update
  run_step "9. 时区" step_tz
  run_step "2. 添加公钥" step_pubkey
  run_step "3. 创建管理员" step_admin
  run_step "4. 修改 SSH 端口" step_port defer || return 1
  run_step "5. UFW" step_ufw || return 1
  run_step "6. fail2ban" step_fail2ban
  run_step "10. swap" step_swap
  run_step "11. TCP 调优" step_tcp
  local port="$SELECTED_SSH_PORT" u="${ADMIN_USER:-root}"
  [[ -n "$port" ]] || { err "未确认目标 SSH 端口, 停止后续收紧操作"; return 1; }
  echo
  warn "接下来会禁用密码登录、禁用 root、关闭旧端口。"
  warn "请先另开一个窗口测试:  ssh -p $port $u@$(public_ip)   并执行 sudo -i"
  if ! confirm "测试成功, 继续?" n; then warn "已停止。测试通过后可单独运行 7 / 8 / 4"; summary; return 0; fi
  run_step "7. 禁用密码登录" step_nopass
  run_step "8. 禁用 root 登录" step_noroot
  if [[ -n "$PENDING_OLD_PORTS" ]]; then
    echo; run_step "关闭旧端口" remove_old_ports "$PENDING_OLD_PORTS" "$port"
  fi
  summary
}

# ---------- 总结 ----------
public_ip() {
  local ip; ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-<服务器IP>}"
}
summary() {
  local port user ip
  port=$(ssh_ports | head -1)
  user=$(sshd_val allowusers); [[ -z "$user" ]] && user=root
  ip=$(public_ip)
  echo; echo "${c_grn}================ 当前状态 ================${c_off}"
  echo "主机名         : $(hostname)"
  echo "SSH 端口       : $(ssh_ports | paste -sd' ' -)"
  echo "root 登录      : $(sshd_val permitrootlogin)"
  echo "密码登录       : $(sshd_val passwordauthentication)"
  echo "AllowUsers     : $(sshd_val allowusers)"
  echo "带公钥的用户   : $(login_users_with_keys | paste -sd' ' -)"
  echo "时区           : $(timedatectl show -p Timezone --value 2>/dev/null)"
  echo "swap           : $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | paste -sd' ' -)"
  echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  echo "--- UFW ---"
  if command -v ufw >/dev/null; then ufw status; else echo "未安装"; fi
  echo "--- fail2ban ---"
  if command -v fail2ban-client >/dev/null; then fail2ban-client status sshd 2>/dev/null || echo "sshd jail 未运行"; else echo "未安装"; fi
  echo; echo "本机 ~/.ssh/config 可添加:"
  cat <<EOT
Host $(hostname)
    HostName $ip
    Port $port
    User $user
    IdentityFile ~/.ssh/id_ed25519
EOT
  [[ -d "$BACKUP_DIR" ]] && echo "配置备份目录: $BACKUP_DIR"
}

menu() {
  cat <<EOT

${c_grn}======= VPS-QuickSetup =======${c_off}
 1. 系统更新 + 基础工具
 2. 添加公钥 (启用密钥登录)
 3. 创建 admin 用户
 4. 修改 SSH 端口 (默认 $DEFAULT_PORT)
 5. 安装 UFW
 6. 安装 fail2ban
 7. 禁用密码登录
 8. 禁用 root 登录
 9. 设置时区 (默认 $DEFAULT_TZ)
10. 设置 swap
11. TCP 调优 (BBR)
12. ALL (按安全顺序执行)
13. 查看当前状态
 0. 退出
EOT
}

main() {
  need_root "$@"
  # 通过 sudo 重新运行时留下的临时副本, bash 已打开文件, 可直接删除
  [[ "$0" == /tmp/quicksetup.*.sh ]] && rm -f "$0"
  check_os
  while true; do
    menu
    ask "请选择" ""
    case "$REPLY" in
      1) step_update ;;  2) step_pubkey ;;  3) step_admin ;;   4) step_port ;;
      5) step_ufw ;;     6) step_fail2ban ;; 7) step_nopass ;;  8) step_noroot ;;
      9) step_tz ;;     10) step_swap ;;    11) step_tcp ;;    12) step_all ;;
      13) summary ;;     0|q|Q) echo "再见"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
