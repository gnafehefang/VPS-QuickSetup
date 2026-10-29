#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

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
c_title=$'\e[1;96m'
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
    exec sudo bash "$QUICKSETUP_ROOT/setup.sh" "$@"
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

backup_file() {
  [[ -e "$1" || -L "$1" ]] || return 0
  mkdir -p "$BACKUP_DIR" || return 1
  local dst="$BACKUP_DIR/${1//\//_}"
  [[ -e "$dst" || -L "$dst" ]] && return 0
  cp -a "$1" "$dst"
}

public_ip() {
  local ip; ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-<服务器IP>}"
}
