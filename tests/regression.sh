#!/usr/bin/env bash
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
source "$ROOT/setup.sh"

info() { :; }
ok() { :; }
skip() { :; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; }

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
