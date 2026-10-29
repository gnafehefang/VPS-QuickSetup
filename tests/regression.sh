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

make_key_fixture() {
  local dir
  dir=$(mktemp -d "$TEST_TMP/keys.XXXXXX") || return 1
  KEY_TEST_HOME="$dir/home"
  KEY_TEST_LOG="$dir/messages"
  mkdir -p "$KEY_TEST_HOME" || return 1
  ssh-keygen -q -t ed25519 -N '' -f "$dir/test-key" || return 1
  KEY_TEST_KEY=$(<"$dir/test-key.pub")
  : >"$KEY_TEST_LOG"
  getent() {
    [[ "$1:$2" == passwd:admin ]] || return 2
    printf 'admin:x:1000:1000::%s:/bin/bash\n' "$KEY_TEST_HOME"
  }
  id() {
    case "$*" in
      admin) return 0 ;;
      '-gn admin') printf 'admin\n' ;;
      *) return 1 ;;
    esac
  }
  install() {
    [[ "$*" == "-d -m 700 -o admin -g admin $KEY_TEST_HOME/.ssh" ]] \
      && command mkdir -p -- "${@: -1}"
  }
  chmod() { [[ "$*" == "600 $KEY_TEST_HOME/.ssh/authorized_keys" ]]; }
  chown() { return 0; }
  ok() { printf '%s\n' "$*" >>"$KEY_TEST_LOG"; }
}

test_key_missing_user_never_touches_files() (
  make_key_fixture || return 1
  id() { return 1; }
  install() { printf 'unexpected install\n' >&2; exit 99; }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -e "$KEY_TEST_HOME/.ssh" ]]
)

test_key_empty_root_or_missing_home_never_touches_files() (
  make_key_fixture || return 1
  local bad_home
  getent() { printf 'admin:x:1000:1000::%s:/bin/bash\n' "$bad_home"; }
  install() { printf 'unexpected install\n' >&2; exit 99; }
  for bad_home in '' / "$KEY_TEST_HOME/missing"; do
    if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  done
  [[ ! -s "$KEY_TEST_LOG" ]]
)

test_key_install_failure_is_not_reported_as_success() (
  make_key_fixture || return 1
  install() { return 1; }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -e "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

test_key_permission_failure_is_not_reported_as_success() (
  make_key_fixture || return 1
  chown() { return 1; }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -s "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

test_key_append_failure_is_not_reported_as_success() (
  make_key_fixture || return 1
  local KEY_TEST_WRITES=0
  printf() {
    if [[ "${2:-}" == "$KEY_TEST_KEY" ]]; then
      ((KEY_TEST_WRITES+=1))
      [[ "$KEY_TEST_WRITES" != 2 ]] || return 1
    fi
    builtin printf "$@"
  }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ "$KEY_TEST_WRITES" == 2 && ! -s "$KEY_TEST_LOG" && ! -s "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

test_key_read_failure_does_not_append_or_report_success() (
  make_key_fixture || return 1
  grep() { return 2; }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -s "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

test_key_tempfile_failure_prevents_writes() (
  make_key_fixture || return 1
  mktemp() { return 1; }
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -e "$KEY_TEST_HOME/.ssh" ]]
)

test_key_all_invalid_input_returns_failure() (
  make_key_fixture || return 1
  if add_key_lines admin <<<'not-a-public-key'; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && ! -s "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

test_key_valid_unterminated_input_is_written_and_deduplicated() (
  make_key_fixture || return 1
  local input="$KEY_TEST_HOME/input"
  printf '%s' "$KEY_TEST_KEY" >"$input"
  add_key_lines admin <"$input" && add_key_lines admin <"$input" || return 1
  has_keys admin && grep -qxF "$KEY_TEST_KEY" "$KEY_TEST_HOME/.ssh/authorized_keys" \
    && [[ "$(wc -l <"$KEY_TEST_HOME/.ssh/authorized_keys")" == 1 \
      && "$(wc -l <"$KEY_TEST_LOG")" == 1 ]]
)

test_key_append_separates_existing_unterminated_line() (
  make_key_fixture || return 1
  mkdir -p "$KEY_TEST_HOME/.ssh"
  printf '%s old-comment' "$KEY_TEST_KEY" >"$KEY_TEST_HOME/.ssh/authorized_keys"
  add_key_lines admin <<<"$KEY_TEST_KEY" || return 1
  [[ "$(wc -l <"$KEY_TEST_HOME/.ssh/authorized_keys")" == 2 ]] \
    && grep -qxF "$KEY_TEST_KEY" "$KEY_TEST_HOME/.ssh/authorized_keys"
)

test_key_directory_target_is_rejected_before_writes() (
  make_key_fixture || return 1
  mkdir -p "$KEY_TEST_HOME/.ssh/authorized_keys"
  if add_key_lines admin <<<"$KEY_TEST_KEY"; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" && -d "$KEY_TEST_HOME/.ssh/authorized_keys" ]]
)

make_pubkey_step_fixture() {
  make_key_fixture || return 1
  PUBKEY_TEST_ASKS=0
  PUBKEY_TEST_REPLIES=()
  PUBKEY_TEST_OUTPUT="$KEY_TEST_HOME/output"
  PUBKEY_TEST_PROMPTS="$KEY_TEST_HOME/prompts"
  if [[ "${1:-}" == existing ]]; then
    mkdir -p "$KEY_TEST_HOME/.ssh" || return 1
    printf '%s' "$KEY_TEST_KEY" >"$KEY_TEST_HOME/.ssh/authorized_keys"
    cp "$KEY_TEST_HOME/.ssh/authorized_keys" "$KEY_TEST_HOME/original_keys" || return 1
  fi
  ask() {
    [[ "$PUBKEY_TEST_ASKS" -lt "${#PUBKEY_TEST_REPLIES[@]}" ]] \
      || { printf 'unexpected prompt: %s\n' "$1" >&2; exit 99; }
    printf '%s [%s]\n' "$1" "${2:-}" >>"$PUBKEY_TEST_PROMPTS"
    REPLY="${PUBKEY_TEST_REPLIES[$PUBKEY_TEST_ASKS]:-${2:-}}"
    ((PUBKEY_TEST_ASKS+=1))
  }
  skip() { printf 'SKIP %s\n' "$*" >>"$KEY_TEST_LOG"; }
}

test_pubkey_existing_valid_keys_default_or_explicit_skip() (
  local choice
  for choice in '' 0; do
    (
      make_pubkey_step_fixture existing || return 1
      PUBKEY_TEST_REPLIES=(admin "$choice")
      add_key_lines() { printf 'unexpected key write\n' >&2; exit 99; }
      curl() { printf 'unexpected network request\n' >&2; exit 99; }
      step_pubkey >"$PUBKEY_TEST_OUTPUT" || return 1
      [[ "$PUBKEY_TEST_ASKS" == 2 ]] \
        && grep -qxF '选择 [0]' "$PUBKEY_TEST_PROMPTS" \
        && grep -qF '0) 保留现有公钥' "$PUBKEY_TEST_OUTPUT" \
        && grep -qxF 'SKIP 保留 admin 的现有有效公钥' "$KEY_TEST_LOG" \
        && cmp -s "$KEY_TEST_HOME/original_keys" "$KEY_TEST_HOME/.ssh/authorized_keys"
    ) || return 1
  done
)

test_pubkey_blank_input_retains_existing_valid_keys() (
  local method
  for method in 1 2; do
    (
      make_pubkey_step_fixture existing || return 1
      PUBKEY_TEST_REPLIES=(admin "$method" '')
      add_key_lines() { printf 'unexpected key write\n' >&2; exit 99; }
      curl() { printf 'unexpected network request\n' >&2; exit 99; }
      step_pubkey >"$PUBKEY_TEST_OUTPUT" || return 1
      [[ "$PUBKEY_TEST_ASKS" == 3 ]] \
        && grep -qxF 'SKIP 保留 admin 的现有有效公钥' "$KEY_TEST_LOG" \
        && cmp -s "$KEY_TEST_HOME/original_keys" "$KEY_TEST_HOME/.ssh/authorized_keys"
    ) || return 1
  done
)

test_pubkey_without_valid_keys_cannot_skip() (
  local state method
  for state in missing empty malformed; do
    for method in 0 '' 1 2; do
      (
        make_pubkey_step_fixture || return 1
        if [[ "$state" != missing ]]; then
          mkdir -p "$KEY_TEST_HOME/.ssh" || return 1
          : >"$KEY_TEST_HOME/.ssh/authorized_keys"
          [[ "$state" != malformed ]] || printf 'not-a-public-key\n' >"$KEY_TEST_HOME/.ssh/authorized_keys"
        fi
        PUBKEY_TEST_REPLIES=(admin "$method" '')
        add_key_lines() { printf 'unexpected key write\n' >&2; exit 99; }
        curl() { printf 'unexpected network request\n' >&2; exit 99; }
        if step_pubkey >"$PUBKEY_TEST_OUTPUT" 2>&1; then return 1; fi
        [[ ! -s "$KEY_TEST_LOG" ]] \
          && grep -qxF '选择 [1]' "$PUBKEY_TEST_PROMPTS" \
          && grep -qF '没有有效公钥, 不能跳过' "$PUBKEY_TEST_OUTPUT" \
          && ! grep -qF '0) 保留现有公钥' "$PUBKEY_TEST_OUTPUT"
      ) || return 1
    done
  done
)

test_pubkey_skip_rechecks_keys_after_selection() (
  local method
  for method in 0 1 2; do
    (
      make_pubkey_step_fixture existing || return 1
      ask() {
        case "$1" in
          要给哪个用户添加公钥) REPLY='admin' ;;
          选择)
            [[ "$2" == 0 ]] || exit 99
            rm -f -- "$KEY_TEST_HOME/.ssh/authorized_keys" || exit 99
            REPLY="$method" ;;
          *) REPLY='' ;;
        esac
      }
      if step_pubkey >"$PUBKEY_TEST_OUTPUT" 2>&1; then return 1; fi
      [[ ! -s "$KEY_TEST_LOG" ]] && grep -qF '没有有效公钥, 不能跳过' "$PUBKEY_TEST_OUTPUT"
    ) || return 1
  done
)

test_pubkey_skip_checks_selected_user_only() (
  make_pubkey_step_fixture existing || return 1
  PUBKEY_TEST_REPLIES=(root 1 '')
  id() { [[ "$*" == root ]]; }
  if step_pubkey >"$PUBKEY_TEST_OUTPUT" 2>&1; then return 1; fi
  [[ ! -s "$KEY_TEST_LOG" ]] \
    && grep -qF 'root 没有有效公钥, 不能跳过' "$PUBKEY_TEST_OUTPUT" \
    && cmp -s "$KEY_TEST_HOME/original_keys" "$KEY_TEST_HOME/.ssh/authorized_keys"
)

test_pubkey_valid_input_succeeds_with_or_without_existing_keys() (
  local state method
  for state in missing existing; do
    for method in 1 2; do
      (
        make_pubkey_step_fixture "$state" || return 1
        ssh-keygen -q -t ed25519 -N '' -f "$KEY_TEST_HOME/another-key" || return 1
        local new_key expected=1
        new_key=$(<"$KEY_TEST_HOME/another-key.pub")
        [[ "$state" != existing ]] || expected=2
        if [[ "$method" == 1 ]]; then PUBKEY_TEST_REPLIES=(admin 1 "$new_key")
        else PUBKEY_TEST_REPLIES=(admin 2 example-user); fi
        curl() {
          [[ "$*" == '-fsSL https://github.com/example-user.keys' ]] \
            && printf '%s\n' "$new_key"
        }
        step_pubkey >"$PUBKEY_TEST_OUTPUT" || return 1
        has_keys admin && grep -qxF "$new_key" "$KEY_TEST_HOME/.ssh/authorized_keys" \
          && [[ "$(wc -l <"$KEY_TEST_HOME/.ssh/authorized_keys")" == "$expected" ]] \
          && grep -qxF 'admin 的 authorized_keys 有效' "$KEY_TEST_LOG" \
          && { [[ "$state" != existing ]] || grep -qxF "$KEY_TEST_KEY" "$KEY_TEST_HOME/.ssh/authorized_keys"; }
      ) || return 1
    done
  done
)

test_pubkey_nonempty_invalid_input_fails_with_existing_keys() (
  local method
  for method in 1 2; do
    (
      make_pubkey_step_fixture existing || return 1
      PUBKEY_TEST_REPLIES=(admin "$method" not-a-public-key)
      curl() { printf 'not-a-public-key\n'; }
      if step_pubkey >"$PUBKEY_TEST_OUTPUT" 2>&1; then return 1; fi
      [[ ! -s "$KEY_TEST_LOG" ]] \
        && cmp -s "$KEY_TEST_HOME/original_keys" "$KEY_TEST_HOME/.ssh/authorized_keys"
    ) || return 1
  done
)

test_pubkey_github_failure_or_empty_result_is_not_skip() (
  local result
  for result in failure empty; do
    (
      make_pubkey_step_fixture existing || return 1
      PUBKEY_TEST_REPLIES=(admin 2 example-user)
      curl() { [[ "$result" == empty ]]; }
      add_key_lines() { printf 'unexpected key write\n' >&2; exit 99; }
      if step_pubkey >"$PUBKEY_TEST_OUTPUT" 2>&1; then return 1; fi
      [[ ! -s "$KEY_TEST_LOG" ]] \
        && cmp -s "$KEY_TEST_HOME/original_keys" "$KEY_TEST_HOME/.ssh/authorized_keys"
    ) || return 1
  done
)

test_pubkey_step_propagates_writer_failure() (
  make_key_fixture || return 1
  local state method
  for state in missing existing; do
    for method in 1 2; do
      (
        local checks=0
        ask() {
          case "$1" in
            要给哪个用户添加公钥) REPLY='admin' ;;
            选择) REPLY="$method" ;;
            *) REPLY="$KEY_TEST_KEY" ;;
          esac
        }
        curl() { printf '%s\n' "$KEY_TEST_KEY"; }
        add_key_lines() { return 1; }
        has_keys() {
          ((checks+=1))
          [[ "$checks" == 1 ]] || { printf 'unexpected readback after write failure\n' >&2; exit 99; }
          [[ "$state" == existing ]]
        }
        if step_pubkey >/dev/null; then return 1; fi
        [[ "$checks" == 1 && ! -s "$KEY_TEST_LOG" ]]
      ) || return 1
    done
  done
)

test_sshd_val_preserves_all_allowusers_values() (
  SSHD_RUN_DIR=$(mktemp -d) || return 1
  sshd() { printf 'permitrootlogin no\nallowusers admin other\nallowusers third\n'; }
  [[ "$(sshd_val allowusers)" == 'admin other third' && "$(sshd_val permitrootlogin)" == no ]]
)

test_sshd_val_rejects_partial_dump_on_failure() (
  SSHD_RUN_DIR=$(mktemp -d) || return 1
  sshd() { printf 'allowusers admin\n'; return 1; }
  local output
  if output=$(sshd_val allowusers); then return 1; fi
  [[ -z "$output" ]]
)

test_sshd_dump_val_deduplicates_without_losing_distinct_values() (
  local dump=$'port 6090\nport 6090\nport 22222\nallowusers admin admin opc\nallowusers opc other'
  [[ "$(sshd_dump_val "$dump" port)" == '6090 22222' \
    && "$(sshd_dump_val "$dump" AllowUsers)" == 'admin opc other' ]]
)

make_noroot_fixture() {
  ADMIN_USER='admin'
  NOROOT_TEST_ROOT=no
  NOROOT_TEST_ALLOW=''
  NOROOT_TEST_CALLS=''
  NOROOT_TEST_CANDS='admin'
  NOROOT_TEST_VERIFY_FAIL=no
  SELECTED_SSH_PORT=''
  SSH_CONNECTION=''
  public_ip() { printf '192.0.2.1\n'; }
  id() {
    case "$1" in
      -u) printf '1000\n' ;;
      -nG) printf 'admin sudo\n' ;;
      *) return 1 ;;
    esac
  }
  has_keys() { return 0; }
  sudo_users_with_keys() { printf '%s\n' "$NOROOT_TEST_CANDS"; }
  sshd_val() {
    case "$1" in
      permitrootlogin) printf '%s\n' "$NOROOT_TEST_ROOT" ;;
      allowusers) printf '%s\n' "$NOROOT_TEST_ALLOW" ;;
      *) return 1 ;;
    esac
  }
  sshd_verify_policy() {
    NOROOT_TEST_CALLS+="verify:$*;"
    [[ "$NOROOT_TEST_VERIFY_FAIL" == no ]]
  }
  ask() { NOROOT_TEST_CALLS+='ask;'; REPLY='admin'; }
  confirm() { NOROOT_TEST_CALLS+='confirm;'; return 0; }
  ssh_ports() { printf '6090\n'; }
  sshd_begin_change() { NOROOT_TEST_CALLS+='begin;'; }
  qs_set() { NOROOT_TEST_CALLS+="set:$*;"; }
  sshd_apply() { NOROOT_TEST_CALLS+="apply:$*;"; }
  passwd() { [[ "$*" == '-S root' ]] && printf 'root L\n'; }
}

test_noroot_existing_root_ban_still_configures_allowusers() (
  local existing_allow
  for existing_allow in '' opc 'admin opc'; do
    (
      make_noroot_fixture
      NOROOT_TEST_ALLOW="$existing_allow"
      step_noroot >/dev/null || return 1
      [[ "$NOROOT_TEST_CALLS" == 'ask;confirm;begin;set:PermitRootLogin no;set:AllowUsers admin;apply:reload PermitRootLogin no AllowUsers admin;' \
        && "$ADMIN_USER" == admin ]]
    ) || return 1
  done
)

test_noroot_skips_only_after_both_policies_are_verified() (
  make_noroot_fixture
  NOROOT_TEST_ALLOW='admin'
  step_noroot || return 1
  [[ "$NOROOT_TEST_CALLS" == 'verify:PermitRootLogin no AllowUsers admin;' ]]
)

test_noroot_duplicate_allowusers_is_already_configured() (
  make_noroot_fixture
  sshd_val() { sshd_dump_val $'permitrootlogin no\nallowusers admin admin\nallowusers admin' "$1"; }
  step_noroot || return 1
  [[ "$NOROOT_TEST_CALLS" == 'verify:PermitRootLogin no AllowUsers admin;' ]]
)

test_noroot_failed_verification_is_not_successful_skip() (
  make_noroot_fixture
  NOROOT_TEST_ALLOW='admin'
  NOROOT_TEST_VERIFY_FAIL=yes
  if step_noroot; then return 1; fi
  [[ "$NOROOT_TEST_CALLS" == 'verify:PermitRootLogin no AllowUsers admin;' ]]
)

test_noroot_existing_root_ban_requires_keyed_admin() (
  make_noroot_fixture
  NOROOT_TEST_CANDS=''
  if step_noroot; then return 1; fi
  [[ -z "$NOROOT_TEST_CALLS" ]]
)

test_noroot_reuses_only_matching_login_confirmation() (
  local state
  for state in matching other-user other-port standalone; do
    (
      make_noroot_fixture
      SELECTED_SSH_PORT=6090
      ssh_ports() { printf '22\n6090\n'; }
      local warnings=''
      warn() { warnings+="$*"; }
      case "$state" in
        matching) step_noroot admin 6090 || return 1 ;;
        other-user) step_noroot other 6090 || return 1 ;;
        other-port) step_noroot admin 22 || return 1 ;;
        standalone) step_noroot || return 1 ;;
      esac
      if [[ "$state" == matching ]]; then
        [[ "$NOROOT_TEST_CALLS" != *'confirm;'* && -z "$warnings" ]]
      else
        [[ "$NOROOT_TEST_CALLS" == *'confirm;'* \
          && "$warnings" == *'请另开窗口测试密钥登录:'* && "$warnings" == *'登录后执行:'* ]]
      fi
    ) || return 1
  done
)

test_admin_login_commands_are_separate_copyable_lines() (
  make_noroot_fixture
  warn() { printf 'WARN %s\n' "$*"; }
  local output
  output=$(confirm_admin_login admin 6090) || return 1
  [[ "$output" == *$'\nssh -o PreferredAuthentications=publickey -p 6090 admin@192.0.2.1\n\n'* \
    && "$output" == *$'\nsudo -i'* && "$output" != *'<服务器IP>'* ]] \
    && [[ "$(grep -cxF 'sudo -i' <<<"$output")" == 1 ]]
)

test_noroot_cancelled_login_test_prevents_configuration() (
  make_noroot_fixture
  confirm() { NOROOT_TEST_CALLS+='confirm;'; return 1; }
  if step_noroot; then return 1; fi
  [[ "$NOROOT_TEST_CALLS" == 'ask;confirm;' ]]
)

test_noroot_unknown_ip_does_not_show_placeholder_or_change_policy() (
  make_noroot_fixture
  public_ip() { printf '<服务器IP>\n'; }
  local output
  output=$(step_noroot 2>&1) && return 1
  [[ "$output" == *'无法确定服务器地址'* && "$output" != *'ssh -'* ]]
)

test_login_port_prefers_selected_then_connection_then_configured() (
  ssh_ports() { printf '22\n6090\n'; }
  SSH_CONNECTION='198.51.100.1 55555 192.0.2.1 6090'
  SELECTED_SSH_PORT=22
  [[ "$(ssh_login_test_port)" == 22 ]] || return 1
  SELECTED_SSH_PORT=22222
  [[ "$(ssh_login_test_port)" == 6090 ]] || return 1
  SSH_CONNECTION=''
  [[ "$(ssh_login_test_port)" == 22 ]] || return 1
  ssh_ports() { return 1; }
  ! ssh_login_test_port
)

test_nopass_confirmation_reuse_rechecks_admin_and_port() (
  local state
  for state in matching changed-port missing-key standalone; do
    (
      local calls='' confirms=0
      sshd_val() { printf 'yes\n'; }
      login_users_with_keys() { printf 'admin\n'; }
      ssh_ports() { printf '22\n6090\n'; }
      SELECTED_SSH_PORT=6090
      id() {
        case "$1" in -u) printf '1000\n' ;; -nG) printf 'admin sudo\n' ;; *) return 1 ;; esac
      }
      has_keys() { [[ "$state" != missing-key ]]; }
      confirm() { ((confirms+=1)); return 0; }
      sshd_begin_change() { calls+='begin;'; }
      qs_set() { calls+="set:$*;"; }
      sshd_apply() { calls+="apply:$*;"; }
      case "$state" in
        matching) step_nopass admin 6090 || return 1 ;;
        standalone) step_nopass || return 1 ;;
        changed-port) if step_nopass admin 22; then return 1; fi ;;
        missing-key) if step_nopass admin 6090; then return 1; fi ;;
      esac
      case "$state" in
        matching) [[ "$calls" == begin\;* && "$confirms" == 0 ]] ;;
        standalone) [[ "$calls" == begin\;* && "$confirms" == 1 ]] ;;
        *) [[ -z "$calls" && "$confirms" == 0 ]] ;;
      esac
    ) || return 1
  done
)

make_summary_login_fixture() {
  ADMIN_USER=''
  SUDO_USER=''
  DEFAULT_ADMIN='admin'
  SUMMARY_TEST_DUMP=$'port 6090\npermitrootlogin no\npasswordauthentication no\npubkeyauthentication yes\nkbdinteractiveauthentication no\nauthenticationmethods any\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\nauthorizedkeyscommand none\ntrustedusercakeys none'
  SUMMARY_TEST_KEY_USERS='root admin opc'
  SUMMARY_TEST_SHELL=/bin/bash
  SUMMARY_TEST_SSHD_FAIL=no
  sshd_policy_layout_supported() { return 0; }
  sudo_users_with_keys() { printf 'opc\nadmin\n'; }
  login_users_with_keys() { printf 'root\nopc\nadmin\n'; }
  has_keys() { [[ " $SUMMARY_TEST_KEY_USERS " == *" $1 "* ]]; }
  getent() {
    [[ "$1" == passwd ]] || return 2
    case "$2" in
      root) printf 'root:x:0:0::/root:/bin/bash\n' ;;
      admin|opc) printf '%s:x:1000:1000::/home/%s:%s\n' "$2" "$2" "$SUMMARY_TEST_SHELL" ;;
      *) return 2 ;;
    esac
  }
}

test_summary_login_prefers_admin_without_allowusers_or_with_multiple_users() (
  make_summary_login_fixture
  [[ "$(summary_login_user "$SUMMARY_TEST_DUMP")" == admin ]] || return 1
  SUMMARY_TEST_DUMP+=$'\nallowusers opc\nallowusers admin'
  [[ "$(summary_login_user "$SUMMARY_TEST_DUMP")" == admin ]]
)

test_summary_login_does_not_recommend_banned_root_or_unlisted_admin() (
  make_summary_login_fixture
  SUMMARY_TEST_DUMP+=$'\nallowusers opc'
  [[ "$(summary_login_user "$SUMMARY_TEST_DUMP")" == opc ]] || return 1
  SUMMARY_TEST_KEY_USERS=root
  if summary_login_user "$SUMMARY_TEST_DUMP"; then return 1; fi
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP%$'\nallowusers opc'}
  if summary_login_user "$SUMMARY_TEST_DUMP"; then return 1; fi
)

test_summary_login_refuses_complex_rules_or_disabled_pubkey() (
  local restriction
  for restriction in 'allowusers admin@192.0.2.*' 'denyusers admin' 'allowgroups admins' \
      'denygroups disabled' 'authenticationmethods publickey,password'; do
    (
      make_summary_login_fixture
      if summary_login_user "$SUMMARY_TEST_DUMP"$'\n'"$restriction"; then return 1; fi
    ) || return 1
  done
  make_summary_login_fixture
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/pubkeyauthentication yes/pubkeyauthentication no}
  if summary_login_user "$SUMMARY_TEST_DUMP"; then return 1; fi
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/pubkeyauthentication no/pubkeyauthentication yes}
  sshd_policy_layout_supported() { return 1; }
  ! summary_login_user "$SUMMARY_TEST_DUMP"
)

test_summary_login_rejects_missing_keys_and_nonlogin_shells() (
  make_summary_login_fixture
  SUMMARY_TEST_KEY_USERS=''
  if summary_login_user "$SUMMARY_TEST_DUMP"; then return 1; fi
  SUMMARY_TEST_KEY_USERS='admin'
  SUMMARY_TEST_SHELL=/usr/sbin/nologin
  ! summary_login_user "$SUMMARY_TEST_DUMP"
)

make_summary_fixture() {
  make_summary_login_fixture
  local dir
  dir=$(mktemp -d "$TEST_TMP/summary.XXXXXX") || return 1
  SSHD_RUN_DIR="$dir/run"
  BACKUP_DIR="$dir/absent-backup"
  SUMMARY_TEST_OUTPUT="$dir/output"
  sshd() { printf '%s\n' "$SUMMARY_TEST_DUMP"; [[ "$SUMMARY_TEST_SSHD_FAIL" == no ]]; }
  hostname() { printf 'Host20261029\n'; }
  public_ip() { printf '192.0.2.1\n'; }
  timedatectl() { printf 'Asia/Singapore\n'; }
  swapon() { :; }
  sysctl() { printf 'test\n'; }
  ufw() { printf 'Status: active\n'; }
  ss() { printf 'Netid State Local Address:Port\ntcp LISTEN 0.0.0.0:6090\n'; }
  summary_accounts() { :; }
  fail2ban-client() { printf 'Status for the jail: sshd\n'; }
}

test_summary_uses_admin_and_explains_missing_allowusers() (
  make_summary_fixture || return 1
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qx '    User admin' "$SUMMARY_TEST_OUTPUT" \
    && grep -qF '没有用户名白名单' "$SUMMARY_TEST_OUTPUT" \
    && ! grep -qx '    User root' "$SUMMARY_TEST_OUTPUT"
)

test_summary_failed_dump_does_not_generate_login_example() (
  make_summary_fixture || return 1
  SUMMARY_TEST_SSHD_FAIL=yes
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qF '未知 (读取失败)' "$SUMMARY_TEST_OUTPUT" \
    && ! grep -q '^    User ' "$SUMMARY_TEST_OUTPUT"
)

make_account_report_fixture() {
  make_key_fixture || return 1
  ACCOUNT_TEST_DIR="$KEY_TEST_HOME/accounts"
  ACCOUNT_TEST_OPC_HOME="$ACCOUNT_TEST_DIR/opc"
  ACCOUNT_TEST_EXTRA=''
  ACCOUNT_TEST_OUTPUT="$ACCOUNT_TEST_DIR/output"
  mkdir -p "$ACCOUNT_TEST_DIR"/{root,admin,ubuntu}/.ssh "$ACCOUNT_TEST_OPC_HOME" "$ACCOUNT_TEST_DIR/service" || return 1
  ssh-keygen -q -t ed25519 -N '' -f "$ACCOUNT_TEST_DIR/second-key" || return 1
  local second
  second=$(<"$ACCOUNT_TEST_DIR/second-key.pub")
  printf '%s\n' "$KEY_TEST_KEY" >"$ACCOUNT_TEST_DIR/root/.ssh/authorized_keys"
  printf '%s\n%s duplicate-comment\n' "$KEY_TEST_KEY" "$KEY_TEST_KEY" >"$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys"
  printf '%s\n%s private-comment-not-for-report\n' "$KEY_TEST_KEY" "$second" >"$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys2"
  printf '%s' "$KEY_TEST_KEY" >"$ACCOUNT_TEST_DIR/ubuntu/.ssh/authorized_keys"
  getent() {
    [[ "$*" == passwd ]] || return 2
    printf 'root:x:0:0::%s/root:/bin/bash\nadmin:x:1000:1000::%s/admin:/bin/bash\n' "$ACCOUNT_TEST_DIR" "$ACCOUNT_TEST_DIR"
    printf 'ubuntu:x:1001:1001::%s/ubuntu:/bin/bash\nopc:x:1002:1002::%s:/bin/bash\n' "$ACCOUNT_TEST_DIR" "$ACCOUNT_TEST_OPC_HOME"
    printf 'service:x:99:99::%s/service:/usr/sbin/nologin\n%s' "$ACCOUNT_TEST_DIR" "$ACCOUNT_TEST_EXTRA"
  }
  warn() { printf 'WARN %s\n' "$*"; }
}

test_account_report_lists_login_users_and_unique_key_counts() (
  make_account_report_fixture || return 1
  cp "$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys" "$ACCOUNT_TEST_DIR/original" || return 1
  cp "$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys2" "$ACCOUNT_TEST_DIR/original2" || return 1
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '系统账号总数: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF '登录及带公钥账号: 4' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'root: 1 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'admin: 2 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'ubuntu: 1 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'opc: 0 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -q '^service:' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -qF 'private-comment-not-for-report' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -qF "${KEY_TEST_KEY#* }" "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -Eq 'UID|SHELL|KEYS|文件:|WARN|/bin/|/sbin/' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -qF "$ACCOUNT_TEST_DIR" "$ACCOUNT_TEST_OUTPUT" \
    && [[ "$(wc -l <"$ACCOUNT_TEST_OUTPUT")" == 10 ]] \
    && cmp -s "$ACCOUNT_TEST_DIR/original" "$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys" \
    && cmp -s "$ACCOUNT_TEST_DIR/original2" "$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys2"
)

test_account_report_masks_all_fingerprints() (
  make_account_report_fixture || return 1
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  local file fingerprint
  for file in "$ACCOUNT_TEST_DIR/root/.ssh/authorized_keys" "$ACCOUNT_TEST_DIR/second-key.pub"; do
    fingerprint=$(ssh-keygen -l -E sha256 -f "$file" | awk '{print $2}') || return 1
    ! grep -qF "$fingerprint" "$ACCOUNT_TEST_OUTPUT" || return 1
    fingerprint=${fingerprint#SHA256:}
    grep -qxF "    SHA256:${fingerprint:0:6}********${fingerprint: -6}" "$ACCOUNT_TEST_OUTPUT" || return 1
  done
  [[ "$(grep -Ec '^    SHA256:[A-Za-z0-9+/=]{6}\*{8}[A-Za-z0-9+/=]{6}$' "$ACCOUNT_TEST_OUTPUT")" == 4 ]]
)

test_account_report_deduplicates_before_masking() (
  make_account_report_fixture || return 1
  ssh-keygen() {
    case "${!#}" in
      "$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys"|"$ACCOUNT_TEST_DIR/admin/.ssh/authorized_keys2")
        printf '256 SHA256:ABCDEF0123456789012345678901234567890UVWXYZ (ED25519)\n'
        printf '256 SHA256:ABCDEF1123456789012345678901234567890UVWXYZ (ED25519)\n' ;;
      *) command ssh-keygen "$@" ;;
    esac
  }
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF 'admin: 2 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && [[ "$(grep -cxF '    SHA256:ABCDEF********UVWXYZ' "$ACCOUNT_TEST_OUTPUT")" == 2 ]] \
    && ! grep -qF '0123456789' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_fully_masks_short_fingerprints() (
  make_account_report_fixture || return 1
  ssh-keygen() {
    if [[ "${!#}" == "$ACCOUNT_TEST_DIR/root/.ssh/authorized_keys" ]]; then
      printf '256 SHA256:ABCDEFUVWXYZ (ED25519)\n'
    else command ssh-keygen "$@"; fi
  }
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '    SHA256:********' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -qF 'ABCDEF' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -qF 'UVWXYZ' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_handles_long_names() (
  make_account_report_fixture || return 1
  ACCOUNT_TEST_EXTRA="long-custom-login-account:x:1003:1003::$ACCOUNT_TEST_DIR/service:/bin/bash"$'\n'
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '系统账号总数: 6' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF '登录及带公钥账号: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'long-custom-login-account: 0 把密钥' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_hides_nonlogin_services_without_keys() (
  make_account_report_fixture || return 1
  ACCOUNT_TEST_EXTRA=$'bin:x:2:2::/:/usr/sbin/nologin\nsync:x:4:65534::/:/bin/sync\nno-login:x:5:5::/:/bin/false\n'
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '系统账号总数: 8' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF '登录及带公钥账号: 4' "$ACCOUNT_TEST_OUTPUT" \
    && ! grep -Eq '^(bin|sync|service|no-login):|^WARN ' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_keeps_nonlogin_accounts_with_keys() (
  make_account_report_fixture || return 1
  mkdir -p "$ACCOUNT_TEST_DIR/service/.ssh" || return 1
  printf '%s\n' "$KEY_TEST_KEY" >"$ACCOUNT_TEST_DIR/service/.ssh/authorized_keys"
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '登录及带公钥账号: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'service: 1 把密钥' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_keeps_nonlogin_accounts_with_unverified_keyfiles() (
  make_account_report_fixture || return 1
  mkdir -p "$ACCOUNT_TEST_DIR/service/.ssh" || return 1
  printf 'not-a-public-key\n' >"$ACCOUNT_TEST_DIR/service/.ssh/authorized_keys"
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '登录及带公钥账号: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'service: 0+? 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && [[ "$(grep -c '^WARN ' "$ACCOUNT_TEST_OUTPUT")" == 1 ]]
)

test_account_report_includes_custom_shell_accounts_without_uid_threshold() (
  make_account_report_fixture || return 1
  ACCOUNT_TEST_EXTRA="operator:x:50:50::$ACCOUNT_TEST_DIR/service:/usr/local/bin/custom-shell"$'\n'
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '登录及带公钥账号: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'operator: 0 把密钥' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_empty_login_list_has_no_phantom_account() (
  make_account_report_fixture || return 1
  getent() { printf 'daemon:x:1:1::/:/usr/sbin/nologin\nsync:x:4:65534::/:/bin/sync\n'; }
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF '系统账号总数: 2' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF '登录及带公钥账号: 0' "$ACCOUNT_TEST_OUTPUT" \
    && [[ "$(wc -l <"$ACCOUNT_TEST_OUTPUT")" == 2 ]]
)

test_account_report_marks_unverified_sources_unknown() (
  local state
  for state in malformed directory read-failure bad-home; do
    (
      make_account_report_fixture || return 1
      mkdir -p "$ACCOUNT_TEST_OPC_HOME/.ssh" || return 1
      case "$state" in
        malformed) printf 'not-a-public-key\n' >"$ACCOUNT_TEST_OPC_HOME/.ssh/authorized_keys" ;;
        directory) mkdir -p "$ACCOUNT_TEST_OPC_HOME/.ssh/authorized_keys" ;;
        read-failure)
          printf '%s\n' "$KEY_TEST_KEY" >"$ACCOUNT_TEST_OPC_HOME/.ssh/authorized_keys"
          ssh-keygen() { [[ "${!#}" != "$ACCOUNT_TEST_OPC_HOME/.ssh/authorized_keys" ]] && command ssh-keygen "$@"; } ;;
        bad-home) ACCOUNT_TEST_OPC_HOME=/ ;;
      esac
      summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
      grep -qxF 'opc: 0+? 把密钥' "$ACCOUNT_TEST_OUTPUT" \
        && [[ "$(grep -c '^WARN ' "$ACCOUNT_TEST_OUTPUT")" == 1 ]] \
        && ! grep -qF "$ACCOUNT_TEST_DIR" "$ACCOUNT_TEST_OUTPUT"
    ) || return 1
  done
)

test_account_report_summarizes_multiple_read_failures_once() (
  make_account_report_fixture || return 1
  mkdir -p "$ACCOUNT_TEST_OPC_HOME/.ssh" || return 1
  printf 'invalid key\n' >"$ACCOUNT_TEST_OPC_HOME/.ssh/authorized_keys"
  printf 'invalid key\n' >"$ACCOUNT_TEST_DIR/ubuntu/.ssh/authorized_keys2"
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" || return 1
  grep -qxF 'opc: 0+? 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'ubuntu: 1+? 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && [[ "$(grep -c '^WARN ' "$ACCOUNT_TEST_OUTPUT")" == 1 ]]
)

test_account_report_warns_about_additional_uid_zero() (
  make_account_report_fixture || return 1
  ACCOUNT_TEST_EXTRA="otherroot:x:0:0::$ACCOUNT_TEST_DIR/service:/usr/sbin/nologin"$'\n'
  summary_accounts >"$ACCOUNT_TEST_OUTPUT" 2>&1 || return 1
  grep -qxF '登录及带公钥账号: 5' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qxF 'otherroot: 0 把密钥' "$ACCOUNT_TEST_OUTPUT" \
    && grep -qF 'otherroot 也是 UID 0 账号' "$ACCOUNT_TEST_OUTPUT"
)

test_account_report_enumeration_failure_is_not_empty_inventory() (
  getent() { return 2; }
  local output
  warn() { printf '%s\n' "$*"; }
  if output=$(summary_accounts); then return 1; fi
  [[ "$output" == *'账号清单读取失败'* && "$output" != *'系统账号总数:'* ]]
)

test_summary_network_audit_only_reads_rules_and_listeners() (
  make_summary_fixture || return 1
  ufw() {
    [[ "$*" == 'status numbered' ]] || { printf 'unexpected UFW change\n' >&2; exit 99; }
    printf 'Status: active\n[ 1] 6090/tcp ALLOW IN Anywhere\n[ 2] 59625/tcp ALLOW IN Anywhere\n'
  }
  ss() { [[ "$*" == -lntup ]] && printf 'tcp LISTEN 127.0.0.1:59625 users:((service,pid=123))\n'; }
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qF '[ 2] 59625/tcp' "$SUMMARY_TEST_OUTPUT" \
    && grep -qF '127.0.0.1:59625' "$SUMMARY_TEST_OUTPUT" \
    && grep -qF '保留既有规则' "$SUMMARY_TEST_OUTPUT"
)

test_summary_security_targets_are_green() (
  make_summary_fixture || return 1
  SUMMARY_TEST_DUMP+=$'\nallowusers admin'
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qF "root 登录      : ${c_grn}no${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "密码登录       : ${c_grn}no${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "密钥登录       : ${c_grn}yes${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "键盘交互认证   : ${c_grn}no${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "AllowUsers     : ${c_grn}admin${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "UFW 已启用     : ${c_grn}yes${c_off}" "$SUMMARY_TEST_OUTPUT"
)

test_summary_deduplicates_ports_and_allowusers() (
  make_summary_fixture || return 1
  SUMMARY_TEST_DUMP+=$'\nport 6090\nallowusers admin admin\nallowusers admin'
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qxF 'SSH 端口       : 6090' "$SUMMARY_TEST_OUTPUT" \
    && grep -qxF "AllowUsers     : ${c_grn}admin${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qxF '    User admin' "$SUMMARY_TEST_OUTPUT"
)

test_summary_deduplication_still_reports_other_allowed_users() (
  make_summary_fixture || return 1
  SUMMARY_TEST_DUMP+=$'\nport 22222\nallowusers admin other admin'
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qxF 'SSH 端口       : 6090 22222' "$SUMMARY_TEST_OUTPUT" \
    && grep -qxF "AllowUsers     : ${c_red}admin other${c_off}" "$SUMMARY_TEST_OUTPUT"
)

test_summary_unsafe_security_values_are_red() (
  make_summary_fixture || return 1
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/permitrootlogin no/permitrootlogin yes}
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/passwordauthentication no/passwordauthentication yes}
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/pubkeyauthentication yes/pubkeyauthentication no}
  SUMMARY_TEST_DUMP=${SUMMARY_TEST_DUMP/kbdinteractiveauthentication no/kbdinteractiveauthentication yes}
  ufw() { printf 'Status: inactive\n'; }
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  grep -qF "root 登录      : ${c_red}yes${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "密码登录       : ${c_red}yes${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "密钥登录       : ${c_red}no${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "键盘交互认证   : ${c_red}yes${c_off}" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "AllowUsers     : ${c_red}未设置" "$SUMMARY_TEST_OUTPUT" \
    && grep -qF "UFW 已启用     : ${c_red}no${c_off}" "$SUMMARY_TEST_OUTPUT"
)

test_summary_failed_queries_are_red_unknown_not_green() (
  make_summary_fixture || return 1
  SUMMARY_TEST_SSHD_FAIL=yes
  ufw() { printf 'Status: active\n'; return 1; }
  fail2ban-client() { printf 'Status for the jail: sshd\n'; return 1; }
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  local label
  for label in 'root 登录      ' '密码登录       ' '密钥登录       ' '键盘交互认证   ' 'UFW 已启用     ' 'sshd jail 就绪 '; do
    grep -qF "$label: ${c_red}未知 (读取失败)${c_off}" "$SUMMARY_TEST_OUTPUT" || return 1
  done
  ! grep -qF "$c_grn" "$SUMMARY_TEST_OUTPUT"
)

test_summary_main_banner_is_bold_bright_and_separated() (
  make_summary_fixture || return 1
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  local output
  output=$(<"$SUMMARY_TEST_OUTPUT")
  [[ "$c_title" != "$c_blu" && "$output" == *$'\n\n'"${c_title}################################################################"$'\n                           当前状态\n################################################################'"${c_off}"$'\n'* ]]
)

summary_note_after_blank() {
  awk -v text="$1" '
    index($0, "[说明] " text) { found++; if (previous !~ /^[[:space:]]*$/) bad=1 }
    { previous=$0 }
    END { exit !(found==1 && !bad) }
  ' "$SUMMARY_TEST_OUTPUT"
}

test_summary_ssh_explanation_starts_after_blank_line() (
  make_summary_fixture || return 1
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  summary_note_after_blank '以上为全局有效配置' \
    && grep -qF '       启用密钥认证不代表已验证登录。' "$SUMMARY_TEST_OUTPUT"
)

test_summary_listener_explanation_starts_after_blank_line() (
  make_summary_fixture || return 1
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  summary_note_after_blank '以上包含回环和系统服务监听'
)

test_summary_sections_have_colored_headers_and_blank_lines() (
  make_summary_fixture || return 1
  summary >"$SUMMARY_TEST_OUTPUT" || return 1
  local output section
  output=$(<"$SUMMARY_TEST_OUTPUT")
  for section in 'SSH 全局策略' '账号与公钥' 'TCP / UDP 监听' 'UFW 防火墙' 'fail2ban' '本机 ~/.ssh/config 可添加'; do
    [[ "$output" == *$'\n\n'"${c_blu}========== $section ==========${c_off}"$'\n'* ]] || return 1
  done
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
  id() {
    case "$*" in
      '-u admin') printf '1000\n' ;;
      '-nG admin') printf 'admin sudo\n' ;;
      *) return 1 ;;
    esac
  }
  has_keys() { [[ "$1" == admin && "${ALL_TEST_KEYS_OK:-yes}" == yes ]]; }
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
    "5. 修改 SSH 端口 (默认随机 $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX)" \
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
  step_nopass() { calls+='10 '; [[ "$*" == 'admin 6090' ]]; }
  step_noroot() { calls+='11 '; [[ "$*" == 'admin 6090' ]]; }
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

test_all_key_failure_stops_before_admin_and_port_changes() (
  local calls='' port_mode=''
  mock_setup_steps
  ADMIN_USER=stale
  step_pubkey() { calls+='3 '; return 1; }
  if step_all >/dev/null; then return 1; fi
  [[ "$calls" == '1 2 3 ' && -z "$ADMIN_USER" && -z "$SELECTED_SSH_PORT" ]]
)

test_all_admin_failure_stops_before_port_and_firewall_changes() (
  local calls='' port_mode=''
  mock_setup_steps
  step_admin() { calls+='4 '; ADMIN_USER='admin'; return 1; }
  if step_all >/dev/null; then return 1; fi
  [[ "$calls" == '1 2 3 4 ' && -z "$ADMIN_USER" && -z "$SELECTED_SSH_PORT" ]]
)

test_all_rejects_unusable_admin_even_if_step_reports_success() (
  local reason
  for reason in unset-name root-name missing-user root-uid missing-key missing-sudo; do
    (
      local calls='' port_mode=''
      mock_setup_steps
      step_admin() {
        calls+='4 '
        case "$reason" in
          unset-name) ADMIN_USER='' ;;
          root-name) ADMIN_USER=root ;;
          *) ADMIN_USER='admin' ;;
        esac
      }
      id() {
        [[ "$reason" != missing-user ]] || return 1
        case "$1" in
          -u) [[ "$reason" == root-uid ]] && printf '0\n' || printf '1000\n' ;;
          -nG) [[ "$reason" == missing-sudo ]] && printf 'admin\n' || printf 'admin sudo\n' ;;
          *) return 1 ;;
        esac
      }
      has_keys() { [[ "$reason" != missing-key ]]; }
      if step_all >/dev/null; then return 1; fi
      [[ "$calls" == '1 2 3 4 ' && -z "$ADMIN_USER" && -z "$SELECTED_SSH_PORT" ]]
    ) || return 1
  done
)

test_all_rechecks_admin_before_login_test_prompt() (
  local calls='' port_mode='' ALL_TEST_KEYS_OK=yes
  mock_setup_steps
  step_tcp() { calls+='9 '; ALL_TEST_KEYS_OK=no; }
  confirm() { calls+='unexpected-confirm '; return 0; }
  public_ip() { printf 'unexpected IP query\n' >&2; exit 99; }
  if step_all >/dev/null; then return 1; fi
  [[ "$calls" == '1 2 3 4 5 6 7 8 9 ' && -z "$ADMIN_USER" \
    && "$PENDING_OLD_PORTS" == 22 && "$SELECTED_SSH_PORT" == 6090 ]]
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
  id() {
    case "$1" in
      -u) printf '1000\n' ;;
      -nG) printf 'admin sudo\n' ;;
      *) return 1 ;;
    esac
  }
  has_keys() { [[ "$1" == admin ]]; }
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
  random_ssh_port() { printf '52783\n'; }
  ask() { REPLY=6090; }
  step_port || return 1
  [[ "$SELECTED_SSH_PORT" == 6090 ]]
)

make_port_fixture() {
  make_ssh_fixture || return 1
  PORT_TEST_CURRENT=22
  PORT_TEST_CANDIDATES=$'52783\n52784\n65535'
  PORT_TEST_SOCKETS=''
  PORT_TEST_RECHECK=''
  PORT_TEST_INPUT=''
  PORT_TEST_PROMPT=''
  PORT_TEST_BEGIN=no
  PORT_TEST_APPLY=''
  PORT_TEST_SS_FAIL=no
  PENDING_OLD_PORTS=''
  SELECTED_SSH_PORT=''
  ssh_ports() { printf '%s\n' "$PORT_TEST_CURRENT"; }
  ss() {
    [[ "$PORT_TEST_SS_FAIL" == no ]] || return 1
    if [[ "$*" == -tanH ]]; then printf '%s' "$PORT_TEST_SOCKETS"
    elif [[ "$1" == -tanH && "$2" == '( sport = :'* ]]; then printf '%s' "$PORT_TEST_RECHECK"
    else return 1; fi
  }
  shuf() { [[ "$*" == "-i $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX" ]] && printf '%s\n' "$PORT_TEST_CANDIDATES"; }
  ask() { PORT_TEST_PROMPT="$1"; REPLY="$PORT_TEST_INPUT"; }
  ufw() { [[ "$*" == status ]] && printf 'Status: inactive\n'; }
  sshd_begin_change() { PORT_TEST_BEGIN=yes; }
  sshd_apply() { PORT_TEST_APPLY="$*"; }
  f2b_refresh() { :; }
}

test_random_port_skips_current_listening_and_connected_ports() (
  make_port_fixture || return 1
  PORT_TEST_CURRENT=$'22\n52783'
  PORT_TEST_CANDIDATES=$'52783\n52784\n52785\n65535'
  PORT_TEST_SOCKETS=$'LISTEN 0 128 0.0.0.0:52784 0.0.0.0:*\nESTAB 0 0 [2001:db8::1]:52785 [2001:db8::2]:443'
  [[ "$(random_ssh_port "$PORT_TEST_CURRENT")" == 65535 ]]
)

test_random_port_real_generator_stays_in_range() (
  ss() { return 0; }
  local port _attempt
  for _attempt in {1..8}; do
    port=$(random_ssh_port 22) || return 1
    [[ "$port" -ge 49152 && "$port" -le 65535 ]] || return 1
  done
)

test_port_enter_uses_displayed_random_candidate_and_keeps_old_port() (
  make_port_fixture || return 1
  step_port defer || return 1
  [[ "$SELECTED_SSH_PORT" == 52783 && "$PENDING_OLD_PORTS" == 22 \
    && "$PORT_TEST_PROMPT" == *'随机范围: 49152-65535, 回车使用: 52783'* \
    && "$PORT_TEST_APPLY" == restart ]] \
    && grep -qx 'Port 22' "$QS_CONF" && grep -qx 'Port 52783' "$QS_CONF"
)

test_port_random_default_is_recomputed_each_time() (
  local candidate
  for candidate in 52783 65535; do
    make_port_fixture || return 1
    PORT_TEST_CANDIDATES="$candidate"
    step_port defer || return 1
    [[ "$SELECTED_SSH_PORT" == "$candidate" && "$PORT_TEST_PROMPT" == *"回车使用: $candidate"* ]] || return 1
  done
)

test_port_manual_input_overrides_random_default() (
  local manual
  for manual in 1024 6090 65535; do
    make_port_fixture || return 1
    PORT_TEST_INPUT="$manual"
    step_port defer || return 1
    [[ "$SELECTED_SSH_PORT" == "$manual" && "$PENDING_OLD_PORTS" == 22 ]] || return 1
    grep -qx "Port $manual" "$QS_CONF" || return 1
  done
)

test_port_manual_input_still_works_when_random_range_is_full() (
  make_port_fixture || return 1
  SSH_RANDOM_PORT_MIN=52783
  SSH_RANDOM_PORT_MAX=52783
  PORT_TEST_CANDIDATES=52783
  PORT_TEST_SOCKETS='LISTEN 0 128 0.0.0.0:52783 0.0.0.0:*'
  PORT_TEST_INPUT=6090
  step_port defer || return 1
  [[ "$SELECTED_SSH_PORT" == 6090 && "$PORT_TEST_PROMPT" == *'需手动输入'* ]]
)

test_port_recheck_rejects_race_or_manual_occupied_port_before_changes() (
  local manual
  for manual in '' 6090; do
    make_port_fixture || return 1
    PORT_TEST_INPUT="$manual"
    PORT_TEST_RECHECK="ESTAB 0 0 192.0.2.1:${manual:-52783} 198.51.100.1:443"
    if step_port defer; then return 1; fi
    [[ "$PORT_TEST_BEGIN" == no && -z "$SELECTED_SSH_PORT" ]] \
      && grep -qx 'Port 22' "$QS_CONF" || return 1
  done
)

test_port_failed_socket_query_cannot_select_or_apply_default() (
  make_port_fixture || return 1
  PORT_TEST_SS_FAIL=yes
  PORT_TEST_INPUT=52783
  if step_port defer; then return 1; fi
  [[ "$PORT_TEST_BEGIN" == no && -z "$SELECTED_SSH_PORT" ]]
)

test_port_failed_random_generator_and_blank_input_do_not_change_config() (
  make_port_fixture || return 1
  shuf() { return 1; }
  if step_port defer; then return 1; fi
  [[ "$PORT_TEST_BEGIN" == no && -z "$SELECTED_SSH_PORT" ]] \
    && grep -qx 'Port 22' "$QS_CONF"
)

test_port_failed_current_port_query_stops_before_prompt() (
  make_port_fixture || return 1
  ssh_ports() { printf '22\n'; return 1; }
  if step_port defer; then return 1; fi
  [[ -z "$PORT_TEST_PROMPT" && "$PORT_TEST_BEGIN" == no && -z "$SELECTED_SSH_PORT" ]]
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
  random_ssh_port() { printf '52783\n'; }
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
