#!/usr/bin/env bash
# VPS-QuickSetup - 新 VPS 基础初始化脚本 (Debian / Ubuntu)
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh)
set -o pipefail

SCRIPT_URL="https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh"
QS_CONF="/etc/ssh/sshd_config.d/00-quicksetup.conf"
MAIN_CONF="/etc/ssh/sshd_config"
SSH_CONF_DIR="/etc/ssh/sshd_config.d"
SSHD_RUN_DIR="/run/sshd"
SSH_SERVICE_DROPIN="/etc/systemd/system/ssh.service.d/00-socket.conf"
SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/addresses.conf"
F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"
SWAP_SYSCTL="/etc/sysctl.d/99-quicksetup-swap.conf"
TCP_SYSCTL="/etc/sysctl.d/99-quicksetup-tcp.conf"
HOSTNAME_FILE="/etc/hostname"
HOSTS_FILE="/etc/hosts"
SUDOERS_DIR="/etc/sudoers.d"
BACKUP_DIR="/root/quicksetup-backup/$(date +%Y%m%d-%H%M%S)"
SSH_RANDOM_PORT_MIN=49152
SSH_RANDOM_PORT_MAX=65535
DEFAULT_TZ="Asia/Singapore"
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
sshd_dump_val() { # 保留多值顺序, 相同值只显示一次, 不丢弃不同用户或端口。
  awk -v k="${2,,}" '$1==k{for(i=2;i<=NF;i++) if(!seen[$i]++) print $i}' <<<"$1" | paste -sd' ' -
}
sshd_val() {
  local dump
  mkdir -p "$SSHD_RUN_DIR" && dump=$(sshd -T 2>/dev/null) || return 1
  sshd_dump_val "$dump" "$1"
}
ssh_ports() { mkdir -p "$SSHD_RUN_DIR"; sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un; }

backup_file() {
  [[ -e "$1" || -L "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR" || return 1
  local dst="$BACKUP_DIR/${1//\//_}"
  [[ -e "$dst" || -L "$dst" ]] && return 0
  cp -a "$1" "$dst"
}
ensure_include() {
  mkdir -p "$SSH_CONF_DIR" || return 1
  [[ -f "$QS_CONF" ]] || { echo "# 由 VPS-QuickSetup 管理" >"$QS_CONF" && chmod 644 "$QS_CONF"; } || return 1
  local tmp
  tmp=$(mktemp "$MAIN_CONF.quicksetup.XXXXXX") || return 1
  if ! { cp -a "$MAIN_CONF" "$tmp" && awk -v managed="$QS_CONF" '
    BEGIN { print "Include " managed }
    tolower($1) == "include" && $2 == managed && (NF == 2 || $3 ~ /^#/) { next }
    { print }
  ' "$MAIN_CONF" >"$tmp" && mv -f -- "$tmp" "$MAIN_CONF"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}
# 先备份 -> 修改 -> sshd -t 校验 -> 失败回滚
SNAP=""
sshd_snapshot() {
  [[ -z "$SNAP" ]] || { err "上次快照尚未清理, 请先检查: $SNAP"; return 1; }
  [[ -f "$MAIN_CONF" && ! -L "$MAIN_CONF" && ! -L "$SSH_CONF_DIR" && ! -L "$QS_CONF" ]] \
    || { err "SSH 配置不存在或受管路径是符号链接, 拒绝自动修改"; return 1; }
  local dir failed=no
  dir=$(mktemp -d) || { err "无法创建 SSH 快照目录"; return 1; }
  cp -a "$MAIN_CONF" "$dir/main" || failed=yes
  if [[ -d "$SSH_CONF_DIR" ]]; then cp -a "$SSH_CONF_DIR" "$dir/d" || failed=yes
  elif [[ -e "$SSH_CONF_DIR" ]]; then failed=yes
  else : >"$dir/d.absent" || failed=yes; fi
  if [[ "$failed" == no ]] && backup_file "$MAIN_CONF" && backup_file "$QS_CONF" && touch "$dir/complete"; then
    SNAP="$dir"
    return 0
  fi
  err "SSH 备份不完整, 未修改配置"
  rm -rf -- "$dir" || warn "临时快照清理失败: $dir"
  return 1
}
sshd_discard_snapshot() {
  [[ -n "$SNAP" ]] || return 0
  [[ -f "$SNAP/complete" ]] || { err "拒绝删除不完整快照: $SNAP"; return 1; }
  rm -rf -- "$SNAP" || return 1
  SNAP=""
}
sshd_restore() {
  [[ -n "$SNAP" && -f "$SNAP/complete" && -f "$SNAP/main" \
      && ( -d "$SNAP/d" || -f "$SNAP/d.absent" ) && ! -L "$SSH_CONF_DIR" ]] \
    || { err "快照不完整或目标路径异常, 不替换现有配置: $SNAP"; return 1; }
  local stage
  stage=$(mktemp -d "$(dirname "$SSH_CONF_DIR")/.quicksetup-restore.XXXXXX") || return 1
  if ! cp -a "$SNAP/main" "$stage/main" \
      || { [[ -d "$SNAP/d" ]] && ! cp -a "$SNAP/d" "$stage/d"; }; then
    rm -rf -- "$stage"
    err "快照暂存失败, 现有配置未被替换"
    return 1
  fi
  # 暂存和目标处于同一文件系统, 先保留现目录, 完成恢复后才清理。
  if [[ -e "$SSH_CONF_DIR" ]] && ! mv -T -- "$SSH_CONF_DIR" "$stage/displaced"; then
    err "无法暂存现有目录, 保留恢复文件: $stage"
    return 1
  fi
  if [[ -d "$stage/d" ]] && ! mv -T -- "$stage/d" "$SSH_CONF_DIR"; then
    if [[ -e "$stage/displaced" ]]; then mv -T -- "$stage/displaced" "$SSH_CONF_DIR" || true; fi
    err "目录恢复失败, 保留恢复文件: $stage"
    return 1
  fi
  if ! mv -Tf -- "$stage/main" "$MAIN_CONF"; then
    if [[ -e "$SSH_CONF_DIR" ]]; then mv -T -- "$SSH_CONF_DIR" "$stage/restored" || return 1; fi
    if [[ -e "$stage/displaced" ]]; then mv -T -- "$stage/displaced" "$SSH_CONF_DIR" || true; fi
    err "主配置恢复失败, 保留恢复文件: $stage"
    return 1
  fi
  rm -rf -- "$stage" || warn "恢复成功, 暂存目录清理失败: $stage"
  return 0
}
sshd_abort_change() {
  if sshd_restore; then sshd_discard_snapshot || warn "快照清理失败: $SNAP"
  else err "恢复失败, 请保留当前连接并检查快照: $SNAP"; fi
  return 1
}
sshd_begin_change() {
  sshd_snapshot || return 1
  ensure_include || { err "准备 SSH 配置失败"; sshd_abort_change; return 1; }
}
sshd_validate_or_rollback() {
  if mkdir -p "$SSHD_RUN_DIR" && sshd -t; then return 0; fi
  err "sshd 配置校验失败, 回滚"
  sshd_abort_change
}
sshd_wait_ready() { # sshd_wait_ready service "port ..."
  local svc="$1" ports="$2" _attempt p ready
  [[ -n "$ports" ]] || return 1
  for _attempt in 1 2 3 4 5; do
    ready=yes
    systemctl is-active --quiet "$svc" || ready=no
    for p in $ports; do ss -ltnH "( sport = :$p )" | grep -q . || ready=no; done
    [[ "$ready" == yes ]] && return 0
    sleep 1
  done
  return 1
}
sshd_policy_layout_supported() {
  local f
  for f in "$MAIN_CONF" "$SSH_CONF_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    awk -v managed="$QS_CONF" -v pattern="$SSH_CONF_DIR/*.conf" '
      tolower($1) == "match" { exit 1 }
      tolower($1) == "include" {
        if (($2 != managed && $2 != pattern) || (NF > 2 && $3 !~ /^#/)) exit 1
      }
    ' "$f" || { err "存在 Match 或非标准 Include, 无法保证所有连接的安全策略, 请人工检查: $f"; return 1; }
  done
}
sshd_expect_settings() { # sshd_expect_settings dump Key value ...
  local dump="$1" key expected actual
  shift
  while (( $# >= 2 )); do
    key="${1,,}"; expected="$2"; shift 2
    actual=$(awk -v k="$key" '$1 == k {for (i=2; i<=NF; i++) print $i}' <<<"$dump" | sort -u | paste -sd' ' -)
    [[ "$actual" == "$expected" ]] || { err "SSH 有效配置不符合预期: $key=$actual (预期 $expected)"; return 1; }
  done
}
sshd_verify_policy() { # sshd_verify_policy Key value ...
  [[ $# -gt 0 ]] || return 0
  sshd_policy_layout_supported || return 1
  local dump u client_ip _client_port server_ip server_port
  dump=$(sshd -T) && sshd_expect_settings "$dump" "$@" || return 1
  read -r client_ip _client_port server_ip server_port <<<"${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
  for u in root $(login_users_with_keys); do
    dump=$(sshd -T -C "user=$u,addr=$client_ip,host=$client_ip,laddr=$server_ip,lport=$server_port") \
      && sshd_expect_settings "$dump" "$@" || return 1
  done
}
sshd_apply() { # sshd_apply restart|reload [Key value ...]
  local action="$1" svc ports activated=no
  shift
  sshd_validate_or_rollback || return 1
  if ! sshd_verify_policy "$@"; then
    err "安全策略未生效, 恢复原配置且不重载 SSH"
    sshd_abort_change
    return 1
  fi
  svc=$(ssh_svc)
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法读取预期 SSH 端口"; sshd_abort_change; return 1; }
  if [[ "$action" == restart ]]; then sshd_restart && activated=yes
  else systemctl reload "$svc" && activated=yes; fi
  if [[ "$activated" == yes ]] && sshd_wait_ready "$svc" "$ports"; then
    sshd_discard_snapshot || warn "配置已生效, 快照清理失败: $SNAP"
    return 0
  fi
  err "SSH $action 或监听检查失败, 恢复原配置"
  if sshd_restore && sshd_socket_restore "$svc" && systemctl restart "$svc" && sshd_wait_ready "$svc" "$(ssh_ports)"; then
    sshd_discard_snapshot || warn "快照清理失败: $SNAP"
    warn "已恢复原 SSH 配置, 未关闭旧防火墙入口"
  else
    err "自动恢复未完成, 请保留当前连接并检查快照: $SNAP"
  fi
  return 1
}
qs_set() { # qs_set Key "value"   (在 00-quicksetup.conf 里设置单值项)
  sed -i "/^[[:space:]]*$1[[:space:]]/Id" "$QS_CONF" || return 1
  echo "$1 $2" >>"$QS_CONF"
}
sshd_socket_snapshot() {
  local svc="$1" socket_enabled service_enabled active=no
  [[ -n "$SNAP" && -f "$SNAP/complete" ]] || { err "切换 ssh.socket 前必须有完整 SSH 快照"; return 1; }
  [[ -f "$SNAP/socket.saved" ]] && return 0
  if [[ -e "$SSH_SERVICE_DROPIN" ]]; then
    cp -a "$SSH_SERVICE_DROPIN" "$SNAP/service-dropin" && backup_file "$SSH_SERVICE_DROPIN" || return 1
  fi
  if [[ -e "$SSH_SOCKET_DROPIN" ]]; then
    cp -a "$SSH_SOCKET_DROPIN" "$SNAP/socket-dropin" && backup_file "$SSH_SOCKET_DROPIN" || return 1
  fi
  socket_enabled=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
  service_enabled=$(systemctl is-enabled "$svc" 2>/dev/null) || true
  [[ -n "$socket_enabled" && -n "$service_enabled" ]] || { err "无法备份 systemd 启用状态"; return 1; }
  systemctl is-active --quiet ssh.socket && active=yes
  printf '%s\n' "$socket_enabled" >"$SNAP/socket.enabled" \
    && printf '%s\n' "$service_enabled" >"$SNAP/service.enabled" \
    && printf '%s\n' "$active" >"$SNAP/socket.active" && touch "$SNAP/socket.saved"
}
restore_unit_enablement() {
  case "$2" in
    enabled) systemctl enable "$1" >/dev/null 2>&1 ;;
    enabled-runtime) systemctl enable --runtime "$1" >/dev/null 2>&1 ;;
    disabled) systemctl disable "$1" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}
sshd_socket_restore() {
  local svc="$1" src dst
  [[ -f "$SNAP/socket.changed" ]] || return 0
  [[ -f "$SNAP/socket.saved" && -s "$SNAP/socket.enabled" && -s "$SNAP/service.enabled" && -s "$SNAP/socket.active" ]] || return 1
  for src in service-dropin socket-dropin; do
    if [[ "$src" == service-dropin ]]; then dst="$SSH_SERVICE_DROPIN"; else dst="$SSH_SOCKET_DROPIN"; fi
    if [[ -e "$SNAP/$src" ]]; then
      mkdir -p "$(dirname "$dst")" && cp -a "$SNAP/$src" "$dst" || return 1
    else rm -f -- "$dst" || return 1; fi
  done
  systemctl daemon-reload || return 1
  restore_unit_enablement ssh.socket "$(cat "$SNAP/socket.enabled")" || return 1
  restore_unit_enablement "$svc" "$(cat "$SNAP/service.enabled")" || return 1
  if [[ "$(cat "$SNAP/socket.active")" == yes ]]; then systemctl start ssh.socket
  else systemctl stop ssh.socket; fi
}
sshd_restart() {
  local svc enabled active=no
  svc=$(ssh_svc)
  enabled=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
  systemctl is-active --quiet ssh.socket && active=yes
  # Ubuntu 迁移遗留的 drop-in 也会重新拉起 socket, 必须一起处理。
  if [[ "$enabled" == enabled || "$enabled" == enabled-runtime || "$active" == yes \
        || -e "$SSH_SERVICE_DROPIN" || -e "$SSH_SOCKET_DROPIN" ]]; then
    info "检测到 ssh.socket, 切换为 ssh.service 管理端口"
    sshd_socket_snapshot "$svc" || return 1
    touch "$SNAP/socket.changed" || return 1
    systemctl disable --now ssh.socket || return 1
    rm -f -- "$SSH_SERVICE_DROPIN" "$SSH_SOCKET_DROPIN" || return 1
    systemctl daemon-reload || return 1
    systemctl enable "$svc" || return 1
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

# ---------- 3. 添加公钥 ----------
add_key_lines() { # add_key_lines user  (从 stdin 读公钥)
  local user="$1" home grp key_file line tmp fingerprint status last valid=0
  id "$user" >/dev/null 2>&1 || { err "用户 $user 不存在, 不写入公钥"; return 1; }
  home=$(getent passwd "$user" | cut -d: -f6) \
    && grp=$(id -gn "$user") && [[ -n "$grp" && "$home" == /* && "$home" != / && -d "$home" ]] \
    || { err "无法确认 $user 的主目录和用户组, 不写入公钥"; return 1; }
  key_file="$home/.ssh/authorized_keys"
  [[ ! -L "$home" && ! -L "$home/.ssh" && ! -L "$key_file" \
      && ( ! -e "$key_file" || -f "$key_file" ) ]] \
    || { err "公钥目标路径异常或是符号链接, 请人工检查: $key_file"; return 1; }
  tmp=$(mktemp) || { err "无法创建公钥校验临时文件"; return 1; }
  if ! { install -d -m 700 -o "$user" -g "$grp" "$home/.ssh" \
      && touch "$key_file" && chmod 600 "$key_file" && chown "$user:$grp" "$key_file"; }; then
    rm -f -- "$tmp"; err "准备 $user 的公钥文件或权限失败"; return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s\n' "$line" >"$tmp" || { rm -f -- "$tmp"; err "暂存公钥失败"; return 1; }
    if ! fingerprint=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then warn "无效公钥, 已忽略: ${line:0:40}..."; continue; fi
    ((valid+=1))
    if grep -qxF -- "$line" "$key_file"; then skip "公钥已存在"; continue
    else
      status=$?
      [[ "$status" == 1 ]] || { rm -f -- "$tmp"; err "读取现有公钥失败"; return 1; }
    fi
    if [[ -s "$key_file" ]]; then
      last=$(tail -c 1 "$key_file") || { rm -f -- "$tmp"; err "读取公钥文件末尾失败"; return 1; }
      if [[ -n "$last" ]]; then
        printf '\n' >>"$key_file" || { rm -f -- "$tmp"; err "写入公钥分隔换行失败"; return 1; }
      fi
    fi
    printf '%s\n' "$line" >>"$key_file" || { rm -f -- "$tmp"; err "写入公钥失败: $key_file"; return 1; }
    ok "已添加: $(awk '{print $2, $NF}' <<<"$fingerprint")"
  done
  rm -f -- "$tmp"
  [[ "$valid" -gt 0 ]] && has_keys "$user" || { err "本次未提供有效公钥或写入后校验失败"; return 1; }
}
step_pubkey() {
  ask "要给哪个用户添加公钥" "root"; local user="$REPLY" default_method=1 keys=""
  id "$user" >/dev/null 2>&1 || { err "用户 $user 不存在 (可先用菜单 4 创建)"; return 1; }
  if has_keys "$user"; then
    info "$user 已有有效公钥"
    echo "  0) 保留现有公钥, 跳过添加"
    default_method=0
  fi
  echo "  1) 粘贴公钥内容 (例如 ssh-ed25519 AAAA... 本机 ~/.ssh/id_ed25519.pub 的内容)"
  echo "  2) 从 GitHub 拉取 (https://github.com/<用户名>.keys)"
  ask "选择" "$default_method"
  case "$REPLY" in
    0) ;;
    2) ask "GitHub 用户名 (已有有效公钥时可回车跳过)" ""
       if [[ -n "$REPLY" ]]; then
         keys=$(curl -fsSL "https://github.com/$REPLY.keys") || { err "拉取失败"; return 1; }
         [[ -n "$keys" ]] || { err "该 GitHub 账号没有公钥"; return 1; }
       fi ;;
    *) ask "粘贴公钥 (一行, 已有有效公钥时可回车跳过)" ""; keys="$REPLY" ;;
  esac
  if [[ -z "$keys" ]]; then
    has_keys "$user" || { err "未输入公钥, 且 $user 没有有效公钥, 不能跳过"; return 1; }
    skip "保留 $user 的现有有效公钥"
    return 0
  fi
  printf '%s\n' "$keys" | add_key_lines "$user" || return 1
  has_keys "$user" || { err "$user 仍没有有效公钥"; return 1; }
  ok "$user 的 authorized_keys 有效"
}

# ---------- 4. 创建 admin ----------
ADMIN_USER=""
step_admin() {
  ADMIN_USER=""
  ask "管理员用户名" "$DEFAULT_ADMIN"; local u="$REPLY"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$u" != root ]] || { err "用户名不合法"; return 1; }
  apt_install sudo || { err "sudo 安装失败, 停止创建管理员"; return 1; }
  if id "$u" >/dev/null 2>&1; then skip "用户 $u 已存在"
  else
    if getent group "$u" >/dev/null; then
      useradd -m -s /bin/bash -g "$u" "$u" || { err "创建用户 $u 失败, 停止后续配置"; return 1; }
    else
      useradd -m -s /bin/bash -U "$u" || { err "创建用户 $u 失败, 停止后续配置"; return 1; }
    fi
    ok "已创建用户 $u"
  fi
  local entry found uid home sh groups root_home
  entry=$(getent passwd "$u") || { err "无法读取新用户 $u, 停止后续配置"; return 1; }
  IFS=: read -r found _ uid _ _ home sh <<<"$entry"
  [[ "$found" == "$u" && "$uid" =~ ^[0-9]+$ && "$uid" -ne 0 \
      && "$home" == /* && "$home" != / && "$sh" != */nologin && "$sh" != */false ]] \
    || { err "$u 不是可用的非 root 登录用户, 请检查 UID、主目录和 shell"; return 1; }
  groups=$(id -nG "$u") || { err "无法读取 $u 的用户组"; return 1; }
  if [[ " $groups " == *' sudo '* ]]; then skip "$u 已在 sudo 组"
  else
    usermod -aG sudo "$u" || { err "$u 加入 sudo 组失败"; return 1; }
    groups=$(id -nG "$u") && [[ " $groups " == *' sudo '* ]] || { err "$u 的 sudo 组成员身份未生效"; return 1; }
    ok "已加入 sudo 组"
  fi
  if has_keys root; then
    root_home=$(getent passwd root | cut -d: -f6) && [[ "$root_home" == /* && "$root_home" != / ]] \
      || { err "无法读取 root 的公钥目录"; return 1; }
    add_key_lines "$u" <"$root_home/.ssh/authorized_keys" || { err "复制 root 公钥失败, 停止管理员配置"; return 1; }
  fi
  if ! has_keys "$u"; then
    warn "$u 还没有公钥, 现在添加"
    ask "粘贴 $u 的公钥 (一行, 回车取消管理员配置)" ""
    [[ -n "$REPLY" ]] && printf '%s\n' "$REPLY" | add_key_lines "$u" \
      || { err "$u 未完成公钥配置, 停止后续操作"; return 1; }
  fi
  has_keys "$u" || { err "$u 仍没有有效公钥, 不标记为可用管理员"; return 1; }
  local sf="$SUDOERS_DIR/90-$u" tmp
  mkdir -p "$SUDOERS_DIR" || { err "无法准备 sudoers 目录"; return 1; }
  if [[ -f "$sf" ]] && grep -q NOPASSWD "$sf"; then
    visudo -cf "$sf" >/dev/null || { err "现有 sudoers 配置无效: $sf"; return 1; }
    skip "$sf 已配置免密 sudo"
  elif confirm "sudo 是否免密 (NOPASSWD)?" y; then
    tmp=$(mktemp "$SUDOERS_DIR/.quicksetup-$u.XXXXXX") || { err "无法暂存 sudoers 配置"; return 1; }
    if printf '%s\n' "$u ALL=(ALL) NOPASSWD:ALL" >"$tmp" && chmod 440 "$tmp" \
        && visudo -cf "$tmp" >/dev/null && backup_file "$sf" && mv -f -- "$tmp" "$sf"; then
      ok "已写入 $sf"
    else
      rm -f -- "$tmp"; err "sudoers 写入或校验失败, 未完成管理员配置"; return 1
    fi
  else
    if passwd -S "$u" 2>/dev/null | awk '{exit !($2=="P")}'; then skip "$u 已有密码"
    else
      info "请为 $u 设置密码 (sudo 时要用)"
      passwd "$u" <"$TTY" >"$TTY" 2>&1 || { err "未设置 sudo 所需密码, 管理员配置未完成"; return 1; }
    fi
  fi
  ADMIN_USER="$u"
  ok "$u 的账户、公钥和 sudo 配置已就绪, 仍需另开窗口测试登录"
}

admin_login_ready() {
  local user="${1:-}" uid groups
  [[ -n "$user" && "$user" != root ]] || { err "未确认非 root 管理员, 请先完成菜单 4"; return 1; }
  uid=$(id -u "$user") && [[ "$uid" =~ ^[0-9]+$ && "$uid" -ne 0 ]] && has_keys "$user" \
    || { err "管理员 $user 不存在、UID 无效或没有有效公钥, 停止后续操作"; return 1; }
  groups=$(id -nG "$user") && [[ " $groups " == *' sudo '* ]] \
    || { err "管理员 $user 不在 sudo 组, 停止后续操作"; return 1; }
}

# ---------- 5. 修改 SSH 端口 ----------
PENDING_OLD_PORTS=""
SELECTED_SSH_PORT=""
random_ssh_port() { # random_ssh_port "当前 SSH 端口", 同时避开已有 TCP 连接占用的本地端口。
  local current="${1:-}" sockets used candidates port
  sockets=$(ss -tanH 2>/dev/null) || { err "无法读取 TCP 端口占用情况, 不自动选择端口"; return 1; }
  used=$(awk '{p=$4; sub(/^.*:/,"",p); if(p~/^[0-9]+$/) print p}' <<<"$sockets" | paste -sd' ' -)
  current=${current//$'\n'/ }
  candidates=$(shuf -i "$SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX") \
    || { err "无法生成随机端口候选"; return 1; }
  for port in $candidates; do
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -ge "$SSH_RANDOM_PORT_MIN" && "$port" -le "$SSH_RANDOM_PORT_MAX" ]] || continue
    [[ " $current $used " != *" $port "* ]] || continue
    printf '%s\n' "$port"; return 0
  done
  err "随机范围 $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX 内没有可用端口"; return 1
}
remove_old_ports() { # remove_old_ports "p1 p2" keep
  local olds="$1" keep="$2" p
  [[ -z "$olds" ]] && return 0
  [[ "$keep" =~ ^[1-9][0-9]{0,4}$ && "$keep" -le 65535 && " $olds " != *" $keep "* ]] \
    || { err "保留端口无效或同时属于旧端口"; return 1; }
  sshd_begin_change || return 1
  if ! { sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF" && echo "Port $keep" >>"$QS_CONF"; }; then
    sshd_abort_change; return 1
  fi
  sshd_apply restart || return 1
  if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q "Status: active"; then
    for p in $olds; do ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p" >/dev/null 2>&1; done
    [[ " $olds " == *" 22 "* ]] && ufw delete allow OpenSSH >/dev/null 2>&1
  fi
  f2b_refresh
  PENDING_OLD_PORTS=""
  ok "已关闭旧端口: $olds, 现在只监听 $keep"
}
step_port() { # step_port [defer]
  local defer="${1:-}" cur new suggested sockets p olds=""
  SELECTED_SSH_PORT=""
  cur=$(ssh_ports) && [[ -n "$cur" ]] || { err "无法确认当前 SSH 端口, 停止修改"; return 1; }
  cur=${cur//$'\n'/ }
  info "当前 SSH 端口: $cur"
  if suggested=$(random_ssh_port "$cur"); then
    ask "新的 SSH 端口 [随机范围: $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX, 回车使用: $suggested]" ""
  else
    suggested=""
    warn "随机默认端口不可用, 请手动输入"
    ask "新的 SSH 端口 [随机范围: $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX, 需手动输入]" ""
  fi
  new="${REPLY:-$suggested}"
  [[ "$new" =~ ^[1-9][0-9]{0,4}$ && "$new" -le 65535 ]] || { err "端口不合法, 请输入 1-65535 且不要加前导零"; return 1; }
  for p in $cur; do [[ "$p" != "$new" ]] && olds="$olds $p"; done; olds="${olds# }"
  if [[ "$cur" == "$new" ]]; then SELECTED_SSH_PORT="$new"; skip "SSH 已经只监听 $new"; return 0; fi
  sockets=$(ss -tanH "( sport = :$new )" 2>/dev/null) || { err "无法复核 TCP 端口占用情况, 停止修改"; return 1; }
  if [[ -n "$sockets" && " $cur " != *" $new "* ]]; then err "端口 $new 已被其他程序或 TCP 连接占用"; return 1; fi
  if command -v ufw >/dev/null; then
    local status
    status=$(LC_ALL=C ufw status) || { err "无法读取 UFW 状态, 停止修改 SSH 端口"; return 1; }
    if [[ "$status" == *"Status: active"* ]]; then ufw_allow_ssh "$new" || return 1; fi
  fi
  sshd_begin_change || return 1
  # 注释掉其他位置的 Port, 统一由 00-quicksetup.conf 管理
  local f
  for f in "$MAIN_CONF" "$SSH_CONF_DIR"/*.conf; do
    [[ -f "$f" && "$f" != "$QS_CONF" ]] || continue
    if grep -Eiq '^[[:space:]]*Port[[:space:]]' "$f"; then
      sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$f" || { sshd_abort_change; return 1; }
    else
      [[ $? -eq 1 ]] || { sshd_abort_change; return 1; }
    fi
  done
  sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF" || { sshd_abort_change; return 1; }
  for p in $olds $new; do echo "Port $p" >>"$QS_CONF" || { sshd_abort_change; return 1; }; done
  sshd_apply restart || return 1
  ok "sshd 已在 $new 监听 (过渡期同时保留: ${olds:-无})"
  SELECTED_SSH_PORT="$new"
  f2b_refresh
  [[ -z "$olds" ]] && return 0
  PENDING_OLD_PORTS="$olds"
  if [[ "$defer" == defer ]]; then info "旧端口 $olds 先保留, 最后再关闭"; return 0; fi
  warn "请另开一个窗口测试:  ssh -p $new <用户>@<服务器IP>"
  if confirm "新端口 $new 登录测试成功了吗? 成功则关闭旧端口 $olds" n; then
    remove_old_ports "$olds" "$new"
  else
    warn "旧端口 $olds 仍保留, 测试成功后可再次运行菜单 5 (输入 $new) 来关闭"
  fi
}

# ---------- 6. UFW ----------
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

# ---------- 7. fail2ban ----------
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

# ---------- 10. 禁用密码登录 ----------
ssh_login_test_port() {
  local ports port _client_ip _client_port _server_ip server_port
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法确认 SSH 端口, 停止登录测试"; return 1; }
  ports=$(tr '\n' ' ' <<<"$ports")
  read -r _client_ip _client_port _server_ip server_port <<<"${SSH_CONNECTION:-}"
  for port in "${SELECTED_SSH_PORT:-}" "${server_port:-}" $ports; do
    if [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 && " $ports " == *" $port "* ]]; then
      printf '%s\n' "$port"; return 0
    fi
  done
  err "没有可用的 SSH 测试端口"; return 1
}
confirm_admin_login() { # user port [本轮已确认的 user port]
  local user="$1" port="$2" ip
  admin_login_ready "$user" || return 1
  if [[ "$user" == "${3:-}" && "$port" == "${4:-}" ]]; then
    info "沿用本轮已确认的 $user / 端口 $port 密钥登录与 sudo 测试"
    return 0
  fi
  ip=$(public_ip)
  [[ -n "$ip" && "$ip" != '<服务器IP>' ]] || { err "无法确定服务器地址, 请核对网络后重新测试"; return 1; }
  warn "请另开窗口测试:  ssh -o PreferredAuthentications=publickey -p $port $user@$ip   并执行 sudo -i"
  confirm "$user 已用密钥登录该端口并 sudo 成功, 继续?" n || { warn "已取消"; return 1; }
}
step_nopass() { # [本轮已确认的 user port]; 单独运行不复用登录确认
  local tested_user="${1:-}" tested_port="${2:-}"
  if [[ "$(sshd_val passwordauthentication)" == no && "$(sshd_val kbdinteractiveauthentication)" == no \
        && "$(sshd_val pubkeyauthentication)" == yes ]]; then
    sshd_verify_policy PubkeyAuthentication yes PasswordAuthentication no KbdInteractiveAuthentication no || return 1
    skip "密码登录已禁用"; return 0; fi
  local users; users=$(login_users_with_keys | tr '\n' ' ')
  [[ -z "$users" ]] && { err "没有任何用户配置了有效公钥, 拒绝禁用密码登录 (先用菜单 3)"; return 1; }
  info "已配置公钥的用户: $users"
  if [[ -n "$tested_user" && -n "$tested_port" ]]; then
    local port; port=$(ssh_login_test_port) || return 1
    [[ "$port" == "$tested_port" ]] || { err "SSH 目标端口已变化, 请重新测试后再禁用密码登录"; return 1; }
    confirm_admin_login "$tested_user" "$port" "$tested_user" "$tested_port" || return 1
  else
    confirm "你确认已经用密钥成功登录过吗?" n || { warn "已取消"; return 1; }
  fi
  sshd_begin_change || return 1
  if ! { qs_set PubkeyAuthentication yes && qs_set PasswordAuthentication no && qs_set KbdInteractiveAuthentication no; }; then
    sshd_abort_change; return 1
  fi
  sshd_apply reload PubkeyAuthentication yes PasswordAuthentication no KbdInteractiveAuthentication no || return 1
  ok "已禁用密码登录 (仅允许密钥)"
}

# ---------- 11. 禁用 root 登录 ----------
step_noroot() { # [本轮已确认的 user port]; 换用户或端口必须重新确认
  local cands; cands=$(sudo_users_with_keys | tr '\n' ' '); cands="${cands% }"
  [[ -z "$cands" ]] && { err "没有带公钥的 sudo 用户, 拒绝禁用 root (先用菜单 4)"; return 1; }
  local def="${ADMIN_USER:-${cands%% *}}"
  if [[ " $cands " == *" $def "* && "$(sshd_val permitrootlogin)" == no \
      && "$(sshd_val allowusers)" == "$def" ]]; then
    sshd_verify_policy PermitRootLogin no AllowUsers "$def" || return 1
    ADMIN_USER="$def"
    skip "root 登录已禁用, 只允许 $def"; return 0
  fi
  info "可用的 sudo 用户: $cands"
  ask "保留登录的用户 (将写入 AllowUsers)" "$def"; local u="$REPLY"
  [[ " $cands " == *" $u "* ]] || { err "$u 不是带公钥的 sudo 用户"; return 1; }
  local port; port=$(ssh_login_test_port) || return 1
  confirm_admin_login "$u" "$port" "${1:-}" "${2:-}" || return 1
  sshd_begin_change || return 1
  if ! { qs_set PermitRootLogin no && qs_set AllowUsers "$u"; }; then sshd_abort_change; return 1; fi
  sshd_apply reload PermitRootLogin no AllowUsers "$u" || return 1
  ADMIN_USER="$u"
  ok "已禁用 root 登录, 只允许 $u"
  if passwd -S root 2>/dev/null | awk '{exit !($2=="L")}'; then skip "root 密码已锁定"
  elif confirm "是否同时锁定 root 密码 (passwd -l root)?" y; then passwd -l root >/dev/null && ok "root 密码已锁定"; fi
}

# ---------- 2. 时区 ----------
step_tz() {
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
  info "当前时区: ${cur:-未知}"
  ask "时区" "$DEFAULT_TZ"; local tz="$REPLY"
  [[ -f "/usr/share/zoneinfo/$tz" ]] || { err "无效时区: $tz"; return 1; }
  [[ "$cur" == "$tz" ]] && { skip "时区已是 $tz"; return 0; }
  timedatectl set-timezone "$tz" 2>/dev/null || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "$tz" >/etc/timezone; }
  ok "时区已设为 $tz ($(date '+%F %T %Z'))"
}

# ---------- 8. swap ----------
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

# ---------- 9. TCP 调优 ----------
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

# ---------- 12. 修改 hostname ----------
step_hostname() {
  local day name cur static tmp
  day=$(date +%Y%m%d) || { err "无法读取当前日期"; return 1; }
  ask "新的 hostname" "Host$day"; name="$REPLY"
  local LC_ALL=C
  [[ ${#name} -le 63 && "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
    || { err "hostname 不合法: 请用 1-63 位英文字母、数字或连字符, 首尾不能是连字符"; return 1; }
  cur=$(hostname) && static=$(hostnamectl --static) \
    || { err "无法读取当前 hostname, 未修改配置"; return 1; }
  [[ -f "$HOSTS_FILE" && ! -L "$HOSTS_FILE" && ! -L "$HOSTNAME_FILE" \
      && ( ! -e "$HOSTNAME_FILE" || -f "$HOSTNAME_FILE" ) ]] \
    || { err "hostname 或 hosts 文件类型异常, 请人工检查"; return 1; }
  tmp=$(mktemp -d) || { err "无法创建 hostname 暂存目录"; return 1; }
  # 只替换本脚本管理的解析记录, 保留原有地址、别名和注释。
  if ! { cp -a "$HOSTS_FILE" "$tmp/hosts" && awk -v name="$name" '
    $0 !~ /[[:space:]]# VPS-QuickSetup hostname$/ { print }
    END { printf "127.0.1.1\t%s # VPS-QuickSetup hostname\n", name }
  ' "$HOSTS_FILE" >"$tmp/hosts.new"; }; then
    rm -rf -- "$tmp"; err "准备 hostname 配置失败, 未修改系统"; return 1
  fi
  if [[ "$cur" == "$name" && "$static" == "$name" ]] && cmp -s "$HOSTS_FILE" "$tmp/hosts.new"; then
    rm -rf -- "$tmp"; skip "hostname 已是 $name"; return 0
  fi
  if ! { backup_file "$HOSTNAME_FILE" && backup_file "$HOSTS_FILE"; }; then
    rm -rf -- "$tmp"; err "hostname 配置备份失败, 未修改系统"; return 1
  fi
  if ! cat "$tmp/hosts.new" >"$HOSTS_FILE"; then
    cat "$tmp/hosts" >"$HOSTS_FILE" || err "hosts 恢复失败, 请检查备份: $BACKUP_DIR"
    rm -rf -- "$tmp"; err "写入 hosts 失败, 未设置 hostname"; return 1
  fi
  # 显式选择 static/transient, 不让 pretty hostname 简化用户输入。
  if hostnamectl --static --transient set-hostname "$name" \
      && [[ "$(hostname)" == "$name" && "$(hostnamectl --static)" == "$name" ]]; then
    rm -rf -- "$tmp"; ok "hostname 已设为 $name"; return 0
  fi
  err "设置或校验 hostname 失败, 尝试恢复原配置"
  local restored=yes
  cat "$tmp/hosts" >"$HOSTS_FILE" || restored=no
  hostnamectl --static set-hostname "$static" || restored=no
  hostname "$cur" || restored=no
  if [[ "$restored" == yes ]]; then
    warn "已恢复原 hostname 和 hosts"
  else
    err "自动恢复未完成, 请检查备份: $BACKUP_DIR"
  fi
  rm -rf -- "$tmp"
  return 1
}

# ---------- 13. ALL ----------
run_step() { echo; echo "${c_blu}========== $1 ==========${c_off}"; shift; "$@" || { warn "该步骤未完成"; return 1; }; }
step_all() {
  ADMIN_USER=""
  PENDING_OLD_PORTS=""
  SELECTED_SSH_PORT=""
  run_step "1. 系统更新" step_update
  run_step "2. 时区" step_tz
  run_step "3. 添加公钥" step_pubkey || return 1
  run_step "4. 创建管理员" step_admin || { ADMIN_USER=""; return 1; }
  admin_login_ready "$ADMIN_USER" || { ADMIN_USER=""; return 1; }
  run_step "5. 修改 SSH 端口" step_port defer || return 1
  run_step "6. UFW" step_ufw || return 1
  run_step "7. fail2ban" step_fail2ban
  run_step "8. swap" step_swap
  run_step "9. TCP 调优" step_tcp
  local port="$SELECTED_SSH_PORT" u="$ADMIN_USER"
  [[ -n "$port" ]] || { err "未确认目标 SSH 端口, 停止后续收紧操作"; return 1; }
  admin_login_ready "$u" || { ADMIN_USER=""; return 1; }
  echo
  warn "接下来会禁用密码登录、禁用 root、关闭旧端口。"
  if ! confirm_admin_login "$u" "$port"; then warn "已停止。测试通过后可单独运行 10 / 11 / 5"; summary; return 0; fi
  run_step "10. 禁用密码登录" step_nopass "$u" "$port" || return 1
  run_step "11. 禁用 root 登录" step_noroot "$u" "$port" || return 1
  if [[ -n "$PENDING_OLD_PORTS" ]]; then
    echo; run_step "关闭旧端口" remove_old_ports "$PENDING_OLD_PORTS" "$port"
  fi
  run_step "12. 修改 hostname" step_hostname || return 1
  summary
}

# ---------- 总结 ----------
public_ip() {
  local ip; ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-<服务器IP>}"
}
summary_login_user() { # 仅为简单、可核对的密钥认证策略生成示例, 不猜测复杂准入规则。
  local dump="$1" allow candidate entry found uid home sh key
  [[ -n "$dump" && "$(sshd_dump_val "$dump" pubkeyauthentication)" == yes ]] || return 1
  sshd_policy_layout_supported >/dev/null 2>&1 || return 1
  for key in denyusers allowgroups denygroups; do
    [[ -z "$(sshd_dump_val "$dump" "$key")" ]] || return 1
  done
  case "$(sshd_dump_val "$dump" authenticationmethods)" in ''|any|publickey) ;; *) return 1 ;; esac
  allow=$(sshd_dump_val "$dump" allowusers)
  [[ -z "$allow" || "$allow" =~ ^[a-zA-Z0-9_\ -]+$ ]] || return 1
  for candidate in "${ADMIN_USER:-}" "$DEFAULT_ADMIN" "${SUDO_USER:-}" $(sudo_users_with_keys) $(login_users_with_keys); do
    [[ "$candidate" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || continue
    [[ -z "$allow" || " $allow " == *" $candidate "* ]] || continue
    entry=$(getent passwd "$candidate") || continue
    IFS=: read -r found _ uid _ _ home sh <<<"$entry"
    [[ "$found" == "$candidate" && "$uid" =~ ^[0-9]+$ && "$home" == /* && "$home" != / \
        && -n "$sh" && "$sh" != */nologin && "$sh" != */false ]] || continue
    if [[ "$uid" == 0 ]]; then
      [[ "$candidate" == root ]] || continue
      case "$(sshd_dump_val "$dump" permitrootlogin)" in yes|prohibit-password|without-password) ;; *) continue ;; esac
    fi
    has_keys "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
summary_accounts() {
  local accounts displayed="" entry u uid home sh file key_dump prints fingerprints fingerprint issues count uncertain=no
  accounts=$(getent passwd) && [[ -n "$accounts" ]] || { warn "账号清单读取失败, 不能判断是否存在其他账号"; return 1; }
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    IFS=: read -r u _ uid _ _ home sh <<<"$entry"
    case "${sh##*/}" in
      nologin|false|sync|true)
        if [[ ! "$uid" =~ ^0+$ ]]; then
          [[ "$home" == /* && "$home" != / ]] || continue
          [[ -s "$home/.ssh/authorized_keys" || -L "$home/.ssh/authorized_keys" \
            || -s "$home/.ssh/authorized_keys2" || -L "$home/.ssh/authorized_keys2" ]] || continue
        fi ;;
    esac
    displayed+="$entry"$'\n'
  done <<<"$accounts"
  displayed=${displayed%$'\n'}
  printf '系统账号总数: %s\n' "$(awk 'NF{n++} END{print n+0}' <<<"$accounts")"
  printf '登录及带公钥账号: %s\n' "$(awk 'NF{n++} END{print n+0}' <<<"$displayed")"
  [[ -n "$displayed" ]] || return 0
  while IFS=: read -r u _ uid _ _ home _; do
    fingerprints=""; issues=no
    if [[ "$home" != /* || "$home" == / || -L "$home" || -L "$home/.ssh" ]]; then
      issues=yes
    else
      for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
          issues=yes; continue
        fi
        [[ -s "$file" ]] || continue
        if ! key_dump=$(ssh-keygen -l -E sha256 -f "$file" 2>/dev/null); then
          issues=yes; continue
        fi
        prints=$(awk '$1~/^[0-9]+$/ && $2~/^SHA256:[A-Za-z0-9+\/=]+$/ && $NF~/^\([A-Za-z0-9_-]+\)$/ {print $2}' <<<"$key_dump")
        if [[ -z "$prints" ]]; then
          issues=yes; continue
        fi
        fingerprints+="$prints"$'\n'
      done
    fi
    fingerprints=$(sort -u <<<"$fingerprints" | awk 'NF')
    count=$(awk 'NF{n++} END{print n+0}' <<<"$fingerprints")
    if [[ "$issues" == yes ]]; then count+='+?'; uncertain=yes; fi
    printf '%s: %s 把密钥\n' "$u" "$count"
    if [[ -n "$fingerprints" ]]; then
      while IFS= read -r fingerprint; do
        fingerprint=${fingerprint#SHA256:}
        if (( ${#fingerprint} > 12 )); then
          printf '    SHA256:%s********%s\n' "${fingerprint:0:6}" "${fingerprint: -6}"
        else
          printf '    SHA256:********\n'
        fi
      done <<<"$fingerprints"
    fi
    if [[ "$uid" =~ ^0+$ && "$u" != root ]]; then err "$u 也是 UID 0 账号, 必须人工核查"; fi
  done <<<"$displayed"
  [[ "$uncertain" == no ]] || warn "+? 表示部分密钥来源未能读取或校验, 数量可能不完整"
  return 0
}
summary_section() { printf '\n%s========== %s ==========%s\n' "$c_blu" "$1" "$c_off"; }
summary_status() { # summary_status label actual expected
  local value="${2:-未知 (读取失败)}" color="$c_red"
  [[ -n "${2:-}" && "$2" == "$3" ]] && color="$c_grn"
  printf '%s: %s%s%s\n' "$1" "$color" "$value" "$c_off"
}
summary() {
  local port user ip dump="" ports allow allow_color="$c_red" ufw_dump f2b_dump
  if ! { mkdir -p "$SSHD_RUN_DIR" && dump=$(sshd -T 2>/dev/null); }; then
    dump=""
    warn "无法读取 SSH 有效配置, 不生成登录示例"
  fi
  ports=$(sshd_dump_val "$dump" port)
  read -r port _ <<<"$ports"
  user=$(summary_login_user "$dump") || user=""
  allow=$(sshd_dump_val "$dump" allowusers)
  if [[ -n "$allow" && -n "$user" && "$user" != root && "$allow" == "$user" ]]; then allow_color="$c_grn"; fi
  if [[ -z "$dump" ]]; then allow="未知 (读取失败)"
  elif [[ -z "$allow" ]]; then allow="未设置 (没有用户名白名单, 不代表仅允许 admin)"; fi
  ip=$(public_ip)
  summary_section "当前状态"
  echo "主机名         : $(hostname)"
  echo "时区           : $(timedatectl show -p Timezone --value 2>/dev/null)"
  echo "swap           : $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | paste -sd' ' -)"
  echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  summary_section "SSH 全局策略"
  echo "SSH 端口       : ${ports:-未知}"
  summary_status "root 登录      " "$(sshd_dump_val "$dump" permitrootlogin)" no
  summary_status "密码登录       " "$(sshd_dump_val "$dump" passwordauthentication)" no
  summary_status "密钥登录       " "$(sshd_dump_val "$dump" pubkeyauthentication)" yes
  summary_status "键盘交互认证   " "$(sshd_dump_val "$dump" kbdinteractiveauthentication)" no
  printf 'AllowUsers     : %s%s%s\n' "$allow_color" "$allow" "$c_off"
  echo "以上为全局有效配置, Match 等规则可能按用户或来源另行限制; 启用密钥认证不代表已验证登录。"
  summary_section "账号与公钥"
  summary_accounts || true
  summary_section "TCP / UDP 监听"
  if command -v ss >/dev/null; then ss -lntup || warn "读取监听端口失败"
  else warn "ss 未安装, 无法显示实际监听"; fi
  echo "以上包含回环和系统服务监听, 不是公网可达性测试。"
  summary_section "UFW 防火墙"
  if command -v ufw >/dev/null; then
    if ufw_dump=$(LC_ALL=C ufw status numbered); then
      case "$ufw_dump" in
        *'Status: active'*) summary_status "UFW 已启用     " yes yes ;;
        *'Status: inactive'*) summary_status "UFW 已启用     " no yes ;;
        *) summary_status "UFW 已启用     " "" yes ;;
      esac
      printf '%s\n' "$ufw_dump"
    else summary_status "UFW 已启用     " "" yes; warn "无法读取 UFW 规则"; fi
  else summary_status "UFW 已启用     " no yes; echo "未安装"; fi
  echo "保留既有规则, 不自动清空; 放行端口不等于有进程监听, UFW 也不代表云防火墙或全部 netfilter 规则。"
  summary_section "fail2ban"
  if command -v fail2ban-client >/dev/null; then
    if f2b_dump=$(fail2ban-client status sshd 2>/dev/null); then
      summary_status "sshd jail 就绪 " yes yes
      printf '%s\n' "$f2b_dump"
    else summary_status "sshd jail 就绪 " "" yes; echo "查询失败或 sshd jail 未运行"; fi
  else summary_status "sshd jail 就绪 " no yes; echo "未安装"; fi
  summary_section "本机 ~/.ssh/config 可添加"
  if [[ -n "$user" && -n "$port" ]]; then
    cat <<EOT
Host $(hostname)
    HostName $ip
    Port $port
    User $user
    IdentityFile ~/.ssh/id_ed25519
EOT
  else
    warn "未确认可用的密钥登录用户或端口, 不猜测 User root; 请核对账户、公钥及 SSH 准入规则"
  fi
  if [[ -d "$BACKUP_DIR" ]]; then summary_section "配置备份"; echo "$BACKUP_DIR"; fi
  return 0
}

menu() {
  cat <<EOT

${c_grn}======= VPS-QuickSetup =======${c_off}
 1. 系统更新 + 基础工具
 2. 设置时区 (默认 $DEFAULT_TZ)
 3. 添加公钥 (启用密钥登录)
 4. 创建 admin 用户
 5. 修改 SSH 端口 (默认随机 $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX)
 6. 安装 UFW
 7. 安装 fail2ban
 8. 设置 swap
 9. TCP 调优 (BBR)
10. 禁用密码登录
11. 禁用 root 登录
12. 修改 hostname
13. ALL (按安全顺序执行)
14. 查看当前状态
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
      1) step_update ;;  2) step_tz ;;      3) step_pubkey ;;  4) step_admin ;;
      5) step_port ;;    6) step_ufw ;;     7) step_fail2ban ;; 8) step_swap ;;
      9) step_tcp ;;    10) step_nopass ;; 11) step_noroot ;; 12) step_hostname ;;
      13) step_all ;;   14) summary ;;     0|q|Q) echo "再见"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
