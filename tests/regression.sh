#!/usr/bin/env bash
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
source "$ROOT/setup.sh"
TEST_TMP=$(mktemp -d) || exit 1
export TMPDIR="$TEST_TMP"
trap 'command rm -rf -- "$TEST_TMP"' EXIT

info() { :; }
ok() { :; }
skip() { :; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; }

make_admin_fixture() {
  local dir
  dir=$(mktemp -d "$TEST_TMP/admin.XXXXXX") || return 1
  ADMIN_TEST_HOME="$dir/admin"
  ADMIN_TEST_ROOT_HOME="$dir/root"
  SUDOERS_DIR="$dir/sudoers.d"
  BACKUP_DIR="$dir/backups"
  TTY="$dir/tty"
  mkdir -p "$ADMIN_TEST_ROOT_HOME/.ssh" "$ADMIN_TEST_HOME" "$SUDOERS_DIR" || return 1
  printf 'fixture-public-key\n' >"$ADMIN_TEST_ROOT_HOME/.ssh/authorized_keys"
  : >"$TTY"
  ADMIN_TEST_EXISTS=no
  ADMIN_TEST_GROUP_EXISTS=yes
  ADMIN_TEST_SUDO=no
  ADMIN_TEST_USERADD_FAIL=no
  ADMIN_TEST_CREATE_SILENT=no
  ADMIN_TEST_USERMOD_FAIL=no
  ADMIN_TEST_COPY_FAIL=no
  ADMIN_TEST_VISUDO_FAIL=no
  ADMIN_TEST_PASSWORD_FAIL=no
  ADMIN_TEST_UID=1000
  ADMIN_TEST_SHELL=/bin/bash
  ADMIN_TEST_USERADD_ARGS=''
  ADMIN_TEST_USERMOD_CALLS=0
  ADMIN_USER=stale
  apt_install() { return 0; }
  ask() { [[ "$1" == 管理员用户名 ]] && REPLY='admin' || REPLY="${ADMIN_TEST_MANUAL_KEY:-}"; }
  getent() {
    case "$1:$2" in
      group:admin) [[ "$ADMIN_TEST_GROUP_EXISTS" == yes ]] && printf 'admin:x:1000:\n' ;;
      passwd:admin)
        [[ "$ADMIN_TEST_EXISTS" == yes ]] || return 2
        printf 'admin:x:%s:1000::%s:%s\n' "$ADMIN_TEST_UID" "$ADMIN_TEST_HOME" "$ADMIN_TEST_SHELL" ;;
      passwd:root) printf 'root:x:0:0::%s:/bin/bash\n' "$ADMIN_TEST_ROOT_HOME" ;;
      *) return 2 ;;
    esac
  }
  id() {
    [[ "$ADMIN_TEST_EXISTS" == yes ]] || return 1
    case "$*" in
      admin) return 0 ;;
      '-nG admin') printf 'admin'; [[ "$ADMIN_TEST_SUDO" == yes ]] && printf ' sudo'; printf '\n' ;;
      *) return 1 ;;
    esac
  }
  useradd() {
    ADMIN_TEST_USERADD_ARGS="$*"
    [[ "$ADMIN_TEST_USERADD_FAIL" == no ]] || return 1
    [[ "$ADMIN_TEST_CREATE_SILENT" == yes ]] || ADMIN_TEST_EXISTS=yes
  }
  usermod() {
    ((ADMIN_TEST_USERMOD_CALLS+=1))
    [[ "$ADMIN_TEST_USERMOD_FAIL" == no ]] || return 1
    ADMIN_TEST_SUDO=yes
  }
  has_keys() {
    local key_home="$ADMIN_TEST_HOME"
    [[ "$1" == root ]] && key_home="$ADMIN_TEST_ROOT_HOME"
    [[ -s "$key_home/.ssh/authorized_keys" ]]
  }
  add_key_lines() {
    [[ "$ADMIN_TEST_COPY_FAIL" == no && "$ADMIN_TEST_EXISTS" == yes && "$1" == admin ]] || return 1
    mkdir -p "$ADMIN_TEST_HOME/.ssh" && cat >"$ADMIN_TEST_HOME/.ssh/authorized_keys"
  }
  confirm() { return 0; }
  visudo() { [[ "$ADMIN_TEST_VISUDO_FAIL" == no ]]; }
  passwd() {
    if [[ "$1" == -S ]]; then printf 'admin L\n'
    else [[ "$ADMIN_TEST_PASSWORD_FAIL" == no ]]; fi
  }
}

test_admin_reuses_existing_same_name_group() (
  make_admin_fixture || return 1
  step_admin || return 1
  [[ "$ADMIN_TEST_USERADD_ARGS" == '-m -s /bin/bash -g admin admin' \
    && "$ADMIN_TEST_EXISTS" == yes && "$ADMIN_TEST_SUDO" == yes && "$ADMIN_USER" == admin ]] \
    && grep -qx 'admin ALL=(ALL) NOPASSWD:ALL' "$SUDOERS_DIR/90-admin"
)

test_admin_creates_private_group_when_missing() (
  make_admin_fixture || return 1
  ADMIN_TEST_GROUP_EXISTS=no
  step_admin || return 1
  [[ "$ADMIN_TEST_USERADD_ARGS" == '-m -s /bin/bash -U admin' && "$ADMIN_USER" == admin ]]
)

test_admin_useradd_failure_stops_all_followup() (
  make_admin_fixture || return 1
  ADMIN_TEST_USERADD_FAIL=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && "$ADMIN_TEST_USERMOD_CALLS" == 0 \
    && ! -e "$ADMIN_TEST_HOME/.ssh" && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_missing_account_after_useradd_stops() (
  make_admin_fixture || return 1
  ADMIN_TEST_CREATE_SILENT=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && "$ADMIN_TEST_USERMOD_CALLS" == 0 && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_sudo_install_failure_prevents_useradd() (
  make_admin_fixture || return 1
  apt_install() { return 1; }
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && -z "$ADMIN_TEST_USERADD_ARGS" ]]
)

test_admin_usermod_failure_stops_before_keys_and_sudoers() (
  make_admin_fixture || return 1
  ADMIN_TEST_USERMOD_FAIL=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && ! -e "$ADMIN_TEST_HOME/.ssh" && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_copy_failure_does_not_publish_or_write_sudoers() (
  make_admin_fixture || return 1
  ADMIN_TEST_COPY_FAIL=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_missing_key_cancels_without_sudoers() (
  make_admin_fixture || return 1
  rm -f -- "$ADMIN_TEST_ROOT_HOME/.ssh/authorized_keys"
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_visudo_failure_preserves_existing_policy() (
  make_admin_fixture || return 1
  printf 'admin ALL=(ALL) ALL\n' >"$SUDOERS_DIR/90-admin"
  ADMIN_TEST_VISUDO_FAIL=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" ]] && grep -qx 'admin ALL=(ALL) ALL' "$SUDOERS_DIR/90-admin"
)

test_admin_password_failure_does_not_publish_user() (
  make_admin_fixture || return 1
  confirm() { return 1; }
  ADMIN_TEST_PASSWORD_FAIL=yes
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && ! -e "$SUDOERS_DIR/90-admin" ]]
)

test_admin_existing_account_is_reusable() (
  make_admin_fixture || return 1
  ADMIN_TEST_EXISTS=yes
  step_admin || return 1
  [[ -z "$ADMIN_TEST_USERADD_ARGS" && "$ADMIN_USER" == admin ]]
)

test_admin_rejects_root_uid_and_nonlogin_shell() (
  make_admin_fixture || return 1
  ADMIN_TEST_UID=0
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && "$ADMIN_TEST_USERMOD_CALLS" == 0 ]] || return 1
  ADMIN_TEST_UID=1000
  ADMIN_TEST_SHELL=/usr/sbin/nologin
  if step_admin; then return 1; fi
  [[ -z "$ADMIN_USER" && "$ADMIN_TEST_USERMOD_CALLS" == 0 ]]
)

test_timezone_default_and_menu_match() (
  [[ "$DEFAULT_TZ" == Asia/Singapore ]] \
    && menu | grep -qF '设置时区 (默认 Asia/Singapore)'
)

test_timezone_enter_uses_default() (
  TTY=$(mktemp) || return 1
  printf '\n' >"$TTY"
  ask "时区" "$DEFAULT_TZ" || return 1
  [[ "$REPLY" == Asia/Singapore ]]
)

test_timezone_step_uses_configured_default() (
  DEFAULT_TZ=UTC
  timedatectl() { printf 'UTC\n'; }
  ask() { [[ "$1" == 时区 && "$2" == "$DEFAULT_TZ" ]]; exit "$?"; }
  step_tz
  return 1
)

make_hostname_fixture() {
  local dir
  dir=$(mktemp -d "$TEST_TMP/hostname.XXXXXX") || return 1
  HOSTNAME_FILE="$dir/hostname"
  HOSTS_FILE="$dir/hosts"
  BACKUP_DIR="$dir/backups"
  HOSTNAME_RUNTIME=OldRuntime
  HOSTNAME_STATIC=OldStatic
  HOSTNAME_SET_CALLS=0
  HOSTNAME_TEST_DAY=20261029
  HOSTNAME_SET_FAIL=no
  HOSTNAME_VERIFY_FAIL=no
  printf '%s\n' "$HOSTNAME_STATIC" >"$HOSTNAME_FILE"
  printf '127.0.0.1 localhost\n127.0.1.1 OldStatic alias # keep\n::1 localhost ip6-localhost\n' >"$HOSTS_FILE"
  date() { [[ "$1" == +%Y%m%d ]] && printf '%s\n' "$HOSTNAME_TEST_DAY"; }
  hostname() {
    if [[ $# == 0 ]]; then printf '%s\n' "$HOSTNAME_RUNTIME"
    else HOSTNAME_RUNTIME="$1"; fi
  }
  hostnamectl() {
    case "$*" in
      --static) printf '%s\n' "$HOSTNAME_STATIC" ;;
      '--static --transient set-hostname '*)
        ((HOSTNAME_SET_CALLS+=1))
        HOSTNAME_STATIC="$4"; HOSTNAME_RUNTIME="$4"
        printf '%s\n' "$HOSTNAME_STATIC" >"$HOSTNAME_FILE"
        [[ "$HOSTNAME_VERIFY_FAIL" == yes ]] && HOSTNAME_RUNTIME=unexpected
        [[ "$HOSTNAME_SET_FAIL" == no ]] ;;
      '--static set-hostname '*)
        HOSTNAME_STATIC="$3"
        if [[ -n "$HOSTNAME_STATIC" ]]; then printf '%s\n' "$HOSTNAME_STATIC" >"$HOSTNAME_FILE"
        else rm -f -- "$HOSTNAME_FILE"; fi ;;
      *) printf 'unexpected hostnamectl: %s\n' "$*" >&2; return 1 ;;
    esac
  }
}

test_hostname_enter_uses_today_with_uppercase_prefix() (
  make_hostname_fixture || return 1
  TTY=$(mktemp) || return 1
  printf '\n' >"$TTY"
  step_hostname || return 1
  [[ "$HOSTNAME_RUNTIME" == Host20261029 && "$HOSTNAME_STATIC" == Host20261029 ]] \
    && grep -qx 'Host20261029' "$HOSTNAME_FILE" \
    && grep -qx $'127.0.1.1\tHost20261029 # VPS-QuickSetup hostname' "$HOSTS_FILE"
)

test_hostname_default_date_is_read_for_each_run() (
  make_hostname_fixture || return 1
  TTY=$(mktemp) || return 1
  printf '\n' >"$TTY"
  step_hostname || return 1
  HOSTNAME_TEST_DAY=20261030
  step_hostname || return 1
  [[ "$HOSTNAME_RUNTIME" == Host20261030 && "$HOSTNAME_STATIC" == Host20261030 ]]
)

test_hostname_custom_name_preserves_aliases_and_first_backup() (
  make_hostname_fixture || return 1
  local original_hosts
  original_hosts=$(<"$HOSTS_FILE")
  ask() { REPLY=My-VPS-01; }
  step_hostname || return 1
  ask() { REPLY=My-VPS-02; }
  step_hostname || return 1
  [[ "$HOSTNAME_RUNTIME" == My-VPS-02 && "$HOSTNAME_STATIC" == My-VPS-02 \
    && "$(<"$BACKUP_DIR/${HOSTS_FILE//\//_}")" == "$original_hosts" ]] \
    && grep -qx 'OldStatic' "$BACKUP_DIR/${HOSTNAME_FILE//\//_}" \
    && grep -qx '127.0.1.1 OldStatic alias # keep' "$HOSTS_FILE" \
    && grep -qx '::1 localhost ip6-localhost' "$HOSTS_FILE" \
    && [[ "$(grep -c '# VPS-QuickSetup hostname$' "$HOSTS_FILE")" == 1 ]] \
    && ! grep -q 'My-VPS-01' "$HOSTS_FILE"
)

test_hostname_repeat_is_idempotent() (
  make_hostname_fixture || return 1
  ask() { REPLY=My-VPS; }
  step_hostname && step_hostname || return 1
  [[ "$HOSTNAME_SET_CALLS" == 1 && "$(grep -c '# VPS-QuickSetup hostname$' "$HOSTS_FILE")" == 1 ]]
)

test_hostname_rejects_invalid_input_before_system_changes() (
  make_hostname_fixture || return 1
  hostnamectl() { printf 'unexpected hostname change\n' >&2; exit 99; }
  backup_file() { printf 'unexpected backup\n' >&2; exit 99; }
  local invalid long
  printf -v long '%064d' 0
  for invalid in '' '-bad' 'bad-' 'bad_name' 'two names' 'name.example' '$(id)' $'bad\nname' '主机' "$long"; do
    ask() { REPLY="$invalid"; }
    if step_hostname; then return 1; fi
  done
  [[ "$HOSTNAME_SET_CALLS" == 0 ]] && grep -qx 'OldStatic' "$HOSTNAME_FILE"
)

test_hostname_accepts_63_character_name() (
  make_hostname_fixture || return 1
  local long_name
  printf -v long_name '%063d' 0
  ask() { REPLY="$long_name"; }
  step_hostname || return 1
  [[ "$HOSTNAME_RUNTIME" == "$long_name" && ${#HOSTNAME_RUNTIME} == 63 ]]
)

test_hostname_backup_failure_prevents_changes() (
  make_hostname_fixture || return 1
  local original_hosts
  original_hosts=$(<"$HOSTS_FILE")
  ask() { REPLY=NewHost; }
  backup_file() { return 1; }
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_SET_CALLS" == 0 && "$(<"$HOSTS_FILE")" == "$original_hosts" ]] \
    && grep -qx 'OldStatic' "$HOSTNAME_FILE"
)

test_hostname_partial_failure_restores_static_runtime_and_hosts() (
  make_hostname_fixture || return 1
  local original_hosts
  original_hosts=$(<"$HOSTS_FILE")
  ask() { REPLY=NewHost; }
  HOSTNAME_SET_FAIL=yes
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_STATIC" == OldStatic && "$HOSTNAME_RUNTIME" == OldRuntime \
    && "$(<"$HOSTS_FILE")" == "$original_hosts" ]] && grep -qx 'OldStatic' "$HOSTNAME_FILE"
)

test_hostname_effective_value_mismatch_triggers_restore() (
  make_hostname_fixture || return 1
  ask() { REPLY=NewHost; }
  HOSTNAME_VERIFY_FAIL=yes
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_STATIC" == OldStatic && "$HOSTNAME_RUNTIME" == OldRuntime ]] \
    && ! grep -q '# VPS-QuickSetup hostname$' "$HOSTS_FILE"
)

test_hostname_hosts_write_failure_preserves_old_name() (
  make_hostname_fixture || return 1
  local original_hosts
  original_hosts=$(<"$HOSTS_FILE")
  ask() { REPLY=NewHost; }
  cat() { [[ "$1" == */hosts.new ]] && return 1; command cat "$@"; }
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_SET_CALLS" == 0 && "$(<"$HOSTS_FILE")" == "$original_hosts" \
    && "$HOSTNAME_STATIC" == OldStatic && "$HOSTNAME_RUNTIME" == OldRuntime ]]
)

test_hostname_restore_failure_does_not_skip_runtime_recovery() (
  make_hostname_fixture || return 1
  ask() { REPLY=NewHost; }
  HOSTNAME_SET_FAIL=yes
  cat() { [[ "$1" == */hosts ]] && return 1; command cat "$@"; }
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_STATIC" == OldStatic && "$HOSTNAME_RUNTIME" == OldRuntime ]]
)

test_hostname_staging_failure_prevents_changes() (
  make_hostname_fixture || return 1
  local original_hosts
  original_hosts=$(<"$HOSTS_FILE")
  ask() { REPLY=NewHost; }
  awk() { return 1; }
  if step_hostname; then return 1; fi
  [[ "$HOSTNAME_SET_CALLS" == 0 && "$(<"$HOSTS_FILE")" == "$original_hosts" ]]
)

test_hostname_failure_restores_absent_static_hostname() (
  make_hostname_fixture || return 1
  HOSTNAME_STATIC=''
  rm -f -- "$HOSTNAME_FILE"
  ask() { REPLY=NewHost; }
  HOSTNAME_SET_FAIL=yes
  if step_hostname; then return 1; fi
  [[ -z "$HOSTNAME_STATIC" && ! -e "$HOSTNAME_FILE" && "$HOSTNAME_RUNTIME" == OldRuntime ]]
)

mock_setup_steps() {
  step_update() { calls+='1 '; }
  step_tz() { calls+='2 '; }
  step_pubkey() { calls+='3 '; }
  step_admin() { calls+='4 '; ADMIN_USER='admin'; }
  step_port() { calls+='5 '; port_mode="${1:-}"; SELECTED_SSH_PORT=6090; PENDING_OLD_PORTS=22; }
  step_ufw() { calls+='6 '; }
  step_fail2ban() { calls+='7 '; }
  step_swap() { calls+='8 '; }
  step_tcp() { calls+='9 '; }
  step_nopass() { calls+='10 '; }
  step_noroot() { calls+='11 '; }
  step_hostname() { calls+='12 '; }
  summary() { calls+='14 '; }
}

test_menu_displays_safe_order() (
  local actual expected
  actual=$(menu | sed -n 's/^ *\([0-9][0-9]*\. .*\)$/\1/p')
  expected=$(printf '%s\n' \
    '1. 系统更新 + 基础工具' \
    "2. 设置时区 (默认 $DEFAULT_TZ)" \
    '3. 添加公钥 (启用密钥登录)' \
    '4. 创建 admin 用户' \
    "5. 修改 SSH 端口 (默认 $DEFAULT_PORT)" \
    '6. 安装 UFW' \
    '7. 安装 fail2ban' \
    '8. 设置 swap' \
    '9. TCP 调优 (BBR)' \
    '10. 禁用密码登录' \
    '11. 禁用 root 登录' \
    '12. 修改 hostname' \
    '13. ALL (按安全顺序执行)' \
    '14. 查看当前状态' \
    '0. 退出')
  [[ "$actual" == "$expected" ]]
)

test_menu_dispatch_matches_safe_order() (
  mock_setup_steps
  step_all() { calls+='13 '; }
  need_root() { :; }
  check_os() { :; }
  menu() { :; }
  local choice
  for choice in {1..14}; do
    (
      local calls='' asked=no port_mode=''
      ask() {
        if [[ "$asked" == no ]]; then REPLY="$choice"; asked=yes
        else [[ "$calls" == "$choice " ]]; exit "$?"; fi
      }
      main >/dev/null
    ) || return 1
  done
)

test_all_numbers_and_pause_match_safe_order() (
  local calls='' labels='' port_mode=''
  mock_setup_steps
  public_ip() { printf '192.0.2.1\n'; }
  confirm() { calls+='pause '; [[ "$2" == n ]]; }
  run_step() { labels+="${1%%.*} "; shift; "$@"; }
  remove_old_ports() { calls+='close '; [[ "$1" == 22 && "$2" == 6090 ]]; }
  step_all >/dev/null || return 1
  [[ "$calls" == '1 2 3 4 5 6 7 8 9 pause 10 11 close 12 14 ' \
    && "$labels" == '1 2 3 4 5 6 7 8 9 10 11 关闭旧端口 12 ' \
    && "$port_mode" == defer ]]
)

test_all_cancel_preserves_login_and_old_ports() (
  local calls='' port_mode='' warnings=''
  mock_setup_steps
  public_ip() { printf '192.0.2.1\n'; }
  confirm() { calls+='pause '; return 1; }
  warn() { warnings+="$*"; }
  remove_old_ports() { calls+='close '; }
  step_all >/dev/null || return 1
  [[ "$calls" == '1 2 3 4 5 6 7 8 9 pause 14 ' \
    && "$warnings" == *'10 / 11 / 5'* \
    && "$PENDING_OLD_PORTS" == 22 && "$port_mode" == defer ]]
)

make_ssh_fixture() {
  local dir
  dir=$(mktemp -d "$TEST_TMP/ssh.XXXXXX") || return 1
  MAIN_CONF="$dir/sshd_config"
  SSH_CONF_DIR="$dir/sshd_config.d"
  QS_CONF="$SSH_CONF_DIR/00-quicksetup.conf"
  SSHD_RUN_DIR="$dir/run"
  BACKUP_DIR="$dir/backups"
  SSH_SERVICE_DROPIN="$dir/systemd/ssh.service.d/00-socket.conf"
  SSH_SOCKET_DROPIN="$dir/systemd/ssh.socket.d/addresses.conf"
  mkdir -p "$SSH_CONF_DIR" || return 1
  printf 'Port 22\n' >"$MAIN_CONF"
  printf 'Port 22\n' >"$QS_CONF"
}

test_all_keeps_selected_lower_port() (
  step_update() { :; }
  step_tz() { :; }
  step_pubkey() { :; }
  step_admin() { ADMIN_USER='admin'; }
  step_port() { PENDING_OLD_PORTS=22222; SELECTED_SSH_PORT=6090; }
  step_ufw() { :; }
  step_fail2ban() { :; }
  step_swap() { :; }
  step_tcp() { :; }
  step_nopass() { :; }
  step_noroot() { :; }
  step_hostname() { :; }
  ssh_ports() { printf '6090\n22222\n'; }
  public_ip() { printf '192.0.2.1\n'; }
  confirm() { return 0; }
  summary() { :; }
  local removed='' kept=''
  remove_old_ports() { removed="$1"; kept="$2"; }
  step_all >/dev/null || return 1
  [[ "$removed" == 22222 && "$kept" == 6090 ]]
)

test_same_port_records_selection() (
  ssh_ports() { printf '6090\n'; }
  ask() { REPLY=6090; }
  step_port || return 1
  [[ "$SELECTED_SSH_PORT" == 6090 ]]
)

test_rejects_removing_kept_port() (
  sshd_snapshot() { printf 'unexpected snapshot\n' >&2; exit 99; }
  ! remove_old_ports '22 6090' 6090
)

test_ufw_rejects_missing_ports() (
  apt_install() { return 0; }
  ssh_ports() { return 1; }
  ufw() { printf 'unexpected UFW change\n' >&2; exit 99; }
  ! step_ufw
)

test_ufw_rejects_empty_ports() (
  apt_install() { return 0; }
  ssh_ports() { return 0; }
  ufw() { printf 'unexpected UFW change\n' >&2; exit 99; }
  ! step_ufw
)

test_ufw_stops_after_failed_allow() (
  apt_install() { return 0; }
  ssh_ports() { printf '22\n6090\n'; }
  local enabled=no
  ufw() {
    case "$1" in
      status) printf 'Status: inactive\n' ;;
      allow) [[ "$2" != 6090/tcp ]] ;;
      --force) enabled=yes ;;
    esac
  }
  if step_ufw; then return 1; fi
  [[ "$enabled" == no ]]
)

test_ufw_allows_all_ports_before_enable() (
  apt_install() { return 0; }
  ssh_ports() { printf '22\n6090\n'; }
  local allowed='' enabled=no
  ufw() {
    case "$1" in
      status) printf 'Status: inactive\n' ;;
      allow) allowed+=" $2" ;;
      --force) [[ "$allowed" == ' 22/tcp 6090/tcp' ]] || return 1; enabled=yes ;;
    esac
  }
  step_ufw >/dev/null || return 1
  [[ "$enabled" == yes ]]
)

test_run_step_preserves_failure() (
  fails() { return 1; }
  ! run_step failure fails >/dev/null
)

test_failed_restart_preserves_firewall_and_restores_config() (
  make_ssh_fixture || return 1
  ensure_include() { :; }
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { awk '$1 == "Port" {print $2}' "$QS_CONF"; }
  local restarts=0 deleted=no
  sshd_restart() { ((restarts+=1)); [[ "$restarts" -gt 1 ]]; }
  systemctl() { ((restarts+=1)); return 0; }
  sshd_wait_ready() { return 0; }
  ufw() { [[ "$1" == delete ]] && deleted=yes; return 0; }
  if remove_old_ports 22 6090; then return 1; fi
  [[ "$deleted" == no && "$restarts" == 2 ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_missing_listener_rolls_back() (
  make_ssh_fixture || return 1
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { printf '22\n'; }
  sshd_snapshot || return 1
  printf 'Port 6090\n' >"$QS_CONF"
  local checks=0 restarts=0
  sshd_restart() { ((restarts+=1)); return 0; }
  systemctl() { ((restarts+=1)); return 0; }
  sshd_wait_ready() { ((checks+=1)); [[ "$checks" -gt 1 ]]; }
  if sshd_apply restart; then return 1; fi
  [[ "$restarts" == 2 ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_failed_reload_rolls_back() (
  make_ssh_fixture || return 1
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { printf '22\n'; }
  sshd_snapshot || return 1
  printf 'PasswordAuthentication no\n' >"$QS_CONF"
  local recovered=no
  systemctl() { [[ "$1" == reload ]] && return 1; recovered=yes; }
  sshd_wait_ready() { return 0; }
  if sshd_apply reload; then return 1; fi
  [[ "$recovered" == yes ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_successful_apply_discards_snapshot_after_health_check() (
  make_ssh_fixture || return 1
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { printf '22\n'; }
  sshd_snapshot || return 1
  local saved="$SNAP" checked=no
  sshd_restart() { return 0; }
  sshd_wait_ready() { [[ -d "$saved" ]] || return 1; checked=yes; }
  sshd_apply restart || return 1
  [[ "$checked" == yes && -z "$SNAP" && ! -e "$saved" ]]
)

test_unready_service_is_rejected() (
  systemctl() { return 1; }
  ss() { printf 'LISTEN\n'; }
  sleep() { :; }
  ! sshd_wait_ready ssh '22 6090'
)

mock_socket_systemctl() {
  case "$1" in
    is-enabled)
      if [[ "$2" == ssh.socket ]]; then printf '%s\n' "$SOCKET_ENABLED"
      else printf '%s\n' "$SERVICE_ENABLED"; fi ;;
    is-active) [[ "$SOCKET_ACTIVE" == yes ]] ;;
    disable)
      if [[ "$*" == *ssh.socket ]]; then SOCKET_ENABLED=disabled
        [[ "$*" == *--now* ]] && SOCKET_ACTIVE=no
      else SERVICE_ENABLED=disabled; fi
      return 0 ;;
    enable)
      if [[ "$*" == *ssh.socket ]]; then SOCKET_ENABLED=enabled; else SERVICE_ENABLED=enabled; fi ;;
    start) SOCKET_ACTIVE=yes ;;
    stop) SOCKET_ACTIVE=no ;;
    daemon-reload) RELOADED=yes ;;
    restart) [[ "$RELOADED" == yes ]] ;;
  esac
}

test_socket_switch_removes_dropins_before_reload() (
  make_ssh_fixture || return 1
  mkdir -p "$(dirname "$SSH_SERVICE_DROPIN")" "$(dirname "$SSH_SOCKET_DROPIN")"
  printf '[Unit]\nRequires=ssh.socket\n' >"$SSH_SERVICE_DROPIN"
  printf '[Socket]\nListenStream=22222\n' >"$SSH_SOCKET_DROPIN"
  ssh_svc() { printf 'ssh\n'; }
  local SOCKET_ENABLED=enabled SOCKET_ACTIVE=yes SERVICE_ENABLED=disabled RELOADED=no
  systemctl() {
    if [[ "$1" == daemon-reload ]]; then
      [[ ! -e "$SSH_SERVICE_DROPIN" && ! -e "$SSH_SOCKET_DROPIN" ]] || return 1
    fi
    mock_socket_systemctl "$@"
  }
  sshd_snapshot || return 1
  sshd_restart || return 1
  [[ "$SOCKET_ACTIVE" == no && "$SOCKET_ENABLED" == disabled && "$SERVICE_ENABLED" == enabled && "$RELOADED" == yes ]]
)

test_socket_switch_failure_restores_files_and_state() (
  make_ssh_fixture || return 1
  mkdir -p "$(dirname "$SSH_SERVICE_DROPIN")" "$(dirname "$SSH_SOCKET_DROPIN")"
  printf '[Unit]\nRequires=ssh.socket\n' >"$SSH_SERVICE_DROPIN"
  printf '[Socket]\nListenStream=22\n' >"$SSH_SOCKET_DROPIN"
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { printf '22\n'; }
  sshd_wait_ready() { return 0; }
  local SOCKET_ENABLED=enabled SOCKET_ACTIVE=yes SERVICE_ENABLED=disabled RELOADED=no restarts=0
  systemctl() {
    if [[ "$1" == restart ]]; then ((restarts+=1)); [[ "$restarts" -gt 1 ]]; return; fi
    mock_socket_systemctl "$@"
  }
  sshd_snapshot || return 1
  if sshd_apply restart; then return 1; fi
  [[ "$SOCKET_ACTIVE" == yes && "$SOCKET_ENABLED" == enabled && "$SERVICE_ENABLED" == disabled ]] \
    && grep -qx 'Requires=ssh.socket' "$SSH_SERVICE_DROPIN" \
    && grep -qx 'ListenStream=22' "$SSH_SOCKET_DROPIN"
)

test_socket_disabled_but_dropin_present_still_switches() (
  make_ssh_fixture || return 1
  mkdir -p "$(dirname "$SSH_SERVICE_DROPIN")"
  printf '[Unit]\nRequires=ssh.socket\n' >"$SSH_SERVICE_DROPIN"
  ssh_svc() { printf 'ssh\n'; }
  local SOCKET_ENABLED=disabled SOCKET_ACTIVE=no SERVICE_ENABLED=enabled RELOADED=no
  systemctl() { mock_socket_systemctl "$@"; }
  sshd_snapshot || return 1
  sshd_restart || return 1
  [[ "$RELOADED" == yes && ! -e "$SSH_SERVICE_DROPIN" ]]
)

test_managed_include_is_first_and_idempotent() (
  make_ssh_fixture || return 1
  printf 'PasswordAuthentication yes\nInclude %s/*.conf\n' "$SSH_CONF_DIR" >"$MAIN_CONF"
  ensure_include && ensure_include || return 1
  [[ "$(head -n 1 "$MAIN_CONF")" == "Include $QS_CONF" ]] \
    && [[ "$(grep -cFx "Include $QS_CONF" "$MAIN_CONF")" == 1 ]] \
    && grep -qxF "Include $SSH_CONF_DIR/*.conf" "$MAIN_CONF"
)

test_effective_policy_conflict_rolls_back_before_reload() (
  make_ssh_fixture || return 1
  sshd() { [[ "$1" == -T ]] && printf 'passwordauthentication yes\n'; return 0; }
  systemctl() { printf 'unexpected service operation\n' >&2; exit 99; }
  sshd_snapshot || return 1
  printf 'PasswordAuthentication no\n' >"$QS_CONF"
  if sshd_apply reload PasswordAuthentication no; then return 1; fi
  grep -qx 'Port 22' "$QS_CONF"
)

test_match_policy_requires_manual_review() (
  make_ssh_fixture || return 1
  printf 'Match Address 192.0.2.0/24\n    PasswordAuthentication yes\n' >>"$MAIN_CONF"
  ! sshd_verify_policy PasswordAuthentication no
)

test_external_include_requires_manual_review() (
  make_ssh_fixture || return 1
  printf 'Include /opt/custom-ssh.conf\n' >>"$MAIN_CONF"
  ! sshd_verify_policy PasswordAuthentication no
)

test_connection_context_is_verified() (
  make_ssh_fixture || return 1
  login_users_with_keys() { printf 'admin\n'; }
  sshd() {
    if [[ "$*" == *user=admin* ]]; then printf 'passwordauthentication yes\n'
    else printf 'passwordauthentication no\n'; fi
  }
  ! sshd_verify_policy PasswordAuthentication no
)

test_additional_allowusers_is_rejected() (
  ! sshd_expect_settings $'permitrootlogin no\nallowusers admin\nallowusers other' PermitRootLogin no AllowUsers admin
)

test_duplicate_allowusers_does_not_cause_false_conflict() (
  sshd_expect_settings $'permitrootlogin no\nallowusers admin\nallowusers admin' PermitRootLogin no AllowUsers admin
)

test_failed_snapshot_copy_blocks_port_changes() (
  make_ssh_fixture || return 1
  local original
  original=$(<"$MAIN_CONF")
  ssh_ports() { printf '22\n'; }
  ask() { REPLY=6090; }
  ss() { return 0; }
  cp() { [[ "$2" == "$SSH_CONF_DIR" ]] && return 1; command cp "$@"; }
  if step_port; then return 1; fi
  [[ -z "$SNAP" && "$(<"$MAIN_CONF")" == "$original" ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_failed_mktemp_blocks_snapshot() (
  make_ssh_fixture || return 1
  mktemp() { return 1; }
  if sshd_snapshot; then return 1; fi
  [[ -z "$SNAP" ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_persistent_backup_failure_blocks_snapshot() (
  make_ssh_fixture || return 1
  printf 'blocker\n' >"$BACKUP_DIR"
  if sshd_snapshot; then return 1; fi
  [[ -z "$SNAP" ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_incomplete_snapshot_does_not_replace_config() (
  make_ssh_fixture || return 1
  SNAP=$(mktemp -d)
  printf 'Port 22\n' >"$SNAP/main"
  if sshd_restore; then return 1; fi
  grep -qx 'Port 22' "$QS_CONF"
)

test_failed_restore_staging_preserves_current_directory() (
  make_ssh_fixture || return 1
  sshd_snapshot || return 1
  printf 'current contents\n' >"$QS_CONF"
  cp() { [[ "$2" == "$SNAP/d" ]] && return 1; command cp "$@"; }
  if sshd_restore; then return 1; fi
  [[ -f "$SNAP/complete" ]] && grep -qx 'current contents' "$QS_CONF"
)

test_absent_config_directory_is_restored_as_absent() (
  make_ssh_fixture || return 1
  rm -f -- "$QS_CONF" && rmdir -- "$SSH_CONF_DIR" || return 1
  sshd_snapshot || return 1
  ensure_include || return 1
  sshd_restore || return 1
  [[ ! -e "$SSH_CONF_DIR" ]] && grep -qx 'Port 22' "$MAIN_CONF"
)

test_existing_recovery_snapshot_is_not_overwritten() (
  make_ssh_fixture || return 1
  sshd_snapshot || return 1
  local saved="$SNAP"
  if sshd_snapshot; then return 1; fi
  [[ "$SNAP" == "$saved" && -f "$saved/complete" ]]
)

test_failed_config_write_rolls_back_before_reload() (
  make_ssh_fixture || return 1
  sshd_val() { printf 'yes\n'; }
  login_users_with_keys() { printf 'admin\n'; }
  confirm() { return 0; }
  sed() { return 1; }
  systemctl() { printf 'unexpected service operation\n' >&2; exit 99; }
  if step_nopass; then return 1; fi
  [[ -z "$SNAP" ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_first_persistent_backup_is_preserved() (
  make_ssh_fixture || return 1
  backup_file "$MAIN_CONF" || return 1
  printf 'Port 6090\n' >"$MAIN_CONF"
  backup_file "$MAIN_CONF" || return 1
  grep -qx 'Port 22' "$BACKUP_DIR/${MAIN_CONF//\//_}"
)

test_failed_restore_directory_rename_preserves_current_config() (
  make_ssh_fixture || return 1
  sshd_snapshot || return 1
  printf 'current contents\n' >"$QS_CONF"
  mv() { [[ "$3" == */d && "$4" == "$SSH_CONF_DIR" ]] && return 1; command mv "$@"; }
  if sshd_restore; then return 1; fi
  [[ -f "$SNAP/complete" ]] && grep -qx 'current contents' "$QS_CONF"
)

test_failed_restore_main_rename_restores_displaced_directory() (
  make_ssh_fixture || return 1
  sshd_snapshot || return 1
  printf 'current contents\n' >"$QS_CONF"
  mv() { [[ "$3" == */main && "$4" == "$MAIN_CONF" ]] && return 1; command mv "$@"; }
  if sshd_restore; then return 1; fi
  [[ -f "$SNAP/complete" ]] && grep -qx 'current contents' "$QS_CONF"
)

test_failed_include_preparation_rolls_back() (
  make_ssh_fixture || return 1
  cp() {
    [[ "$2" == "$MAIN_CONF" && "$3" == "$MAIN_CONF".quicksetup.* ]] && return 1
    command cp "$@"
  }
  if sshd_begin_change; then return 1; fi
  [[ -z "$SNAP" ]] && grep -qx 'Port 22' "$MAIN_CONF" && grep -qx 'Port 22' "$QS_CONF"
)

test_failed_recovery_retains_complete_snapshot() (
  make_ssh_fixture || return 1
  sshd() { return 0; }
  ssh_svc() { printf 'ssh\n'; }
  ssh_ports() { printf '22\n'; }
  sshd_restart() { return 1; }
  systemctl() { return 1; }
  sshd_snapshot || return 1
  printf 'Port 6090\n' >"$QS_CONF"
  if sshd_apply restart; then return 1; fi
  [[ -f "$SNAP/complete" ]] && grep -qx 'Port 22' "$QS_CONF"
)

test_noncanonical_port_cannot_bypass_old_port_guard() (
  sshd_snapshot() { printf 'unexpected snapshot\n' >&2; exit 99; }
  ! remove_old_ports 22 00022
)

test_port_with_leading_zero_is_rejected_before_changes() (
  ssh_ports() { printf '22\n'; }
  ask() { REPLY=00022; }
  if step_port; then return 1; fi
  [[ -z "$SELECTED_SSH_PORT" ]]
)

passed=0
failed=0
while IFS= read -r test_name; do
  if "$test_name"; then
    printf 'PASS %s\n' "$test_name"
    ((passed+=1))
  else
    printf 'FAIL %s\n' "$test_name" >&2
    ((failed+=1))
  fi
done < <(compgen -A function test_ | sort)
printf '\n%s passed; %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
