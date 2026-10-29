#!/usr/bin/env bash
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
source "$ROOT/setup.sh"
TEST_TMP=$(mktemp -d) || exit 1
trap 'command rm -rf -- "$TEST_TMP"' EXIT

info() { :; }
ok() { :; }
skip() { :; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; }

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
  step_admin() { ADMIN_USER=admin; }
  step_port() { PENDING_OLD_PORTS=22222; SELECTED_SSH_PORT=6090; }
  step_ufw() { :; }
  step_fail2ban() { :; }
  step_swap() { :; }
  step_tcp() { :; }
  step_nopass() { :; }
  step_noroot() { :; }
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
