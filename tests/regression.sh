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
  systemctl() { return 1; }
  sshd_restart() { recovered=yes; }
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
