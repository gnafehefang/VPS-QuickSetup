#!/usr/bin/env bash
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
# shellcheck source=setup.sh
source "$ROOT/setup.sh" || exit 1
TEST_TMP=$(mktemp -d) || exit 1
trap 'command rm -rf -- "$TEST_TMP"' EXIT

make_bootstrap_fixture() {
  BOOTSTRAP_DIR=$(mktemp -d "$TEST_TMP/bootstrap.XXXXXX") || return 1
  BOOTSTRAP_TREE="$BOOTSTRAP_DIR/checkout with spaces"
  BOOTSTRAP_ARCHIVE="$BOOTSTRAP_DIR/repository.tar.gz"
  BOOTSTRAP_LOG="$BOOTSTRAP_DIR/main.log"
  BOOTSTRAP_DOWNLOAD_LOG="$BOOTSTRAP_DIR/download.log"
  BOOTSTRAP_SUDO_LOG="$BOOTSTRAP_DIR/sudo.log"
  BOOTSTRAP_MARKER="$BOOTSTRAP_DIR/loaded.log"
  BOOTSTRAP_OUTPUT="$BOOTSTRAP_DIR/output"
  BOOTSTRAP_TMP="$BOOTSTRAP_DIR/runtime"
  BOOTSTRAP_CURL_FAIL=no
  BOOTSTRAP_EXIT=0
  mkdir -p "$BOOTSTRAP_TREE" "$BOOTSTRAP_TMP" || return 1
  cp "$ROOT/setup.sh" "$BOOTSTRAP_TREE/setup.sh" \
    && cp -a "$ROOT/scripts" "$BOOTSTRAP_TREE/scripts" || return 1
  printf '%s\n' \
    'main() {' \
    '  [[ "$DEFAULT_TZ" == Asia/Singapore && -f "$QUICKSETUP_ROOT/scripts/14-status.sh" ]] || return 99' \
    '  declare -F step_pubkey step_admin step_port step_all summary >/dev/null || return 99' \
    '  printf "root=%s\n" "$QUICKSETUP_ROOT" >"$BOOTSTRAP_LOG"' \
    '  printf "arg=%s\n" "$@" >>"$BOOTSTRAP_LOG"' \
    '  return "$BOOTSTRAP_EXIT"' \
    '}' >"$BOOTSTRAP_TREE/scripts/menu.sh"
  export BOOTSTRAP_ARCHIVE BOOTSTRAP_LOG BOOTSTRAP_DOWNLOAD_LOG BOOTSTRAP_SUDO_LOG
  export BOOTSTRAP_MARKER BOOTSTRAP_CURL_FAIL BOOTSTRAP_EXIT
  export TMPDIR="$BOOTSTRAP_TMP"
  curl() {
    local url='' output=''
    while (( $# )); do
      case "$1" in
        https://*) url="$1" ;;
        -o) shift; output="$1" ;;
      esac
      shift
    done
    [[ "$url" == https://github.com/gnafehefang/VPS-QuickSetup/archive/refs/heads/main.tar.gz && -n "$output" ]] || return 99
    printf '%s\n' "$url" >>"$BOOTSTRAP_DOWNLOAD_LOG"
    if [[ "$BOOTSTRAP_CURL_FAIL" == yes ]]; then
      printf 'partial download\n' >"$output"
      return 22
    fi
    command cp "$BOOTSTRAP_ARCHIVE" "$output"
  }
  export -f curl
}

pack_bootstrap_fixture() {
  tar -czf "$BOOTSTRAP_ARCHIVE" -C "$BOOTSTRAP_DIR" 'checkout with spaces'
}

bootstrap_tmp_is_empty() {
  [[ -z "$(find "$BOOTSTRAP_TMP" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

run_remote_bootstrap() {
  bash <(command cat "$ROOT/setup.sh") "$@" >"$BOOTSTRAP_OUTPUT" 2>&1
}

make_sudo_stub() {
  mkdir -p "$BOOTSTRAP_DIR/bin" || return 1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "$1" == bash && -f "$2" && -f "${2%/*}/scripts/14-status.sh" ]] || exit 99' \
    'printf "%s\n" "$@" >"$BOOTSTRAP_SUDO_LOG"' \
    'exit 37' >"$BOOTSTRAP_DIR/bin/sudo"
  chmod 700 "$BOOTSTRAP_DIR/bin/sudo" || return 1
  export PATH="$BOOTSTRAP_DIR/bin:$PATH"
}

test_local_source_uses_entry_directory_without_running_menu_or_downloading() (
  make_bootstrap_fixture || return 1
  cd "$BOOTSTRAP_TMP" || return 1
  bash -c 'source "$1" || exit; [[ "$QUICKSETUP_ROOT" == "$2" ]] && declare -F step_update step_tz step_pubkey step_admin step_port step_ufw step_fail2ban step_swap step_tcp step_nopass step_noroot step_hostname step_all summary >/dev/null' \
    bash "$BOOTSTRAP_TREE/setup.sh" "$BOOTSTRAP_TREE" || return 1
  [[ ! -e "$BOOTSTRAP_LOG" && ! -e "$BOOTSTRAP_DOWNLOAD_LOG" ]]
)

test_local_execution_keeps_arguments_and_never_downloads() (
  make_bootstrap_fixture || return 1
  cd "$BOOTSTRAP_TMP" || return 1
  bash "$BOOTSTRAP_TREE/setup.sh" 'argument with spaces' second || return 1
  grep -qxF "root=$BOOTSTRAP_TREE" "$BOOTSTRAP_LOG" \
    && grep -qxF 'arg=argument with spaces' "$BOOTSTRAP_LOG" \
    && grep -qxF 'arg=second' "$BOOTSTRAP_LOG" \
    && [[ ! -e "$BOOTSTRAP_DOWNLOAD_LOG" ]]
)

test_local_missing_module_stops_before_loading_or_menu_without_remote_fallback() (
  make_bootstrap_fixture || return 1
  printf 'printf "loaded\\n" >"$BOOTSTRAP_MARKER"\n' >>"$BOOTSTRAP_TREE/scripts/common.sh"
  rm -- "$BOOTSTRAP_TREE/scripts/menu.sh" || return 1
  if bash "$BOOTSTRAP_TREE/setup.sh" >"$BOOTSTRAP_OUTPUT" 2>&1; then return 1; fi
  [[ ! -e "$BOOTSTRAP_MARKER" && ! -e "$BOOTSTRAP_LOG" && ! -e "$BOOTSTRAP_DOWNLOAD_LOG" ]] \
    && grep -qF 'menu.sh' "$BOOTSTRAP_OUTPUT"
)

test_local_syntax_error_stops_before_loading_any_module() (
  make_bootstrap_fixture || return 1
  printf 'printf "loaded\\n" >"$BOOTSTRAP_MARKER"\n' >>"$BOOTSTRAP_TREE/scripts/common.sh"
  printf 'if then\n' >>"$BOOTSTRAP_TREE/scripts/menu.sh"
  if bash "$BOOTSTRAP_TREE/setup.sh" >"$BOOTSTRAP_OUTPUT" 2>&1; then return 1; fi
  [[ ! -e "$BOOTSTRAP_MARKER" && ! -e "$BOOTSTRAP_LOG" && ! -e "$BOOTSTRAP_DOWNLOAD_LOG" ]]
)

test_source_failure_returns_to_caller_without_running_menu() (
  make_bootstrap_fixture || return 1
  rm -- "$BOOTSTRAP_TREE/scripts/12-hostname.sh" || return 1
  bash -c 'if source "$1"; then exit 99; fi; printf "caller survived\n"' \
    bash "$BOOTSTRAP_TREE/setup.sh" >"$BOOTSTRAP_OUTPUT" 2>&1 || return 1
  grep -qxF 'caller survived' "$BOOTSTRAP_OUTPUT" && [[ ! -e "$BOOTSTRAP_LOG" ]]
)

test_module_runtime_failure_never_runs_menu() (
  make_bootstrap_fixture || return 1
  printf '\nreturn 19\n' >>"$BOOTSTRAP_TREE/scripts/12-hostname.sh"
  if bash "$BOOTSTRAP_TREE/setup.sh" >"$BOOTSTRAP_OUTPUT" 2>&1; then return 1; fi
  [[ ! -e "$BOOTSTRAP_LOG" ]]
)

test_unregistered_script_is_not_executed() (
  make_bootstrap_fixture || return 1
  printf 'printf "unexpected\\n" >"$BOOTSTRAP_MARKER"\n' >"$BOOTSTRAP_TREE/scripts/unregistered.sh"
  bash "$BOOTSTRAP_TREE/setup.sh" || return 1
  [[ -e "$BOOTSTRAP_LOG" && ! -e "$BOOTSTRAP_MARKER" ]]
)

test_each_registered_module_is_loaded_once() (
  make_bootstrap_fixture || return 1
  local file
  for file in "$BOOTSTRAP_TREE"/scripts/*.sh; do
    printf '\nprintf "%%s\\n" "%s" >>"$BOOTSTRAP_MARKER"\n' "${file##*/}" >>"$file"
  done
  bash "$BOOTSTRAP_TREE/setup.sh" || return 1
  [[ "$(wc -l <"$BOOTSTRAP_MARKER")" == 19 ]] || return 1
  for file in "$BOOTSTRAP_TREE"/scripts/*.sh; do
    [[ "$(grep -cxF "${file##*/}" "$BOOTSTRAP_MARKER")" == 1 ]] || return 1
  done
)

test_remote_archive_starts_matching_entry_and_modules_then_cleans_up() (
  make_bootstrap_fixture && pack_bootstrap_fixture || return 1
  run_remote_bootstrap 'argument with spaces' second || return 1
  local root
  root=$(sed -n 's/^root=//p' "$BOOTSTRAP_LOG")
  [[ "$root" == "$BOOTSTRAP_TMP"/quicksetup.*/repository && ! -e "$root" ]] \
    && [[ "$(wc -l <"$BOOTSTRAP_DOWNLOAD_LOG")" == 1 ]] \
    && grep -qxF 'arg=argument with spaces' "$BOOTSTRAP_LOG" \
    && grep -qxF 'arg=second' "$BOOTSTRAP_LOG" \
    && bootstrap_tmp_is_empty
)

test_remote_child_exit_status_is_preserved_and_cleanup_still_runs() (
  make_bootstrap_fixture && pack_bootstrap_fixture || return 1
  BOOTSTRAP_EXIT=37
  local status=0
  run_remote_bootstrap || status=$?
  [[ "$status" == 37 && -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty
)

test_failed_download_does_not_execute_partial_package() (
  make_bootstrap_fixture || return 1
  BOOTSTRAP_CURL_FAIL=yes
  if run_remote_bootstrap; then return 1; fi
  [[ ! -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty \
    && grep -qF '下载完整脚本包失败' "$BOOTSTRAP_OUTPUT"
)

test_invalid_archive_does_not_run_menu_and_is_cleaned_up() (
  make_bootstrap_fixture || return 1
  printf 'not an archive\n' >"$BOOTSTRAP_ARCHIVE"
  if run_remote_bootstrap; then return 1; fi
  [[ ! -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty \
    && grep -qF '解压脚本包失败' "$BOOTSTRAP_OUTPUT"
)

test_archive_missing_entry_does_not_run_and_is_cleaned_up() (
  make_bootstrap_fixture || return 1
  rm -- "$BOOTSTRAP_TREE/setup.sh" || return 1
  pack_bootstrap_fixture || return 1
  if run_remote_bootstrap; then return 1; fi
  [[ ! -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty \
    && grep -qF '脚本包入口缺失或损坏' "$BOOTSTRAP_OUTPUT"
)

test_archive_missing_module_does_not_run_and_is_cleaned_up() (
  make_bootstrap_fixture || return 1
  rm -- "$BOOTSTRAP_TREE/scripts/12-hostname.sh" || return 1
  pack_bootstrap_fixture || return 1
  if run_remote_bootstrap; then return 1; fi
  [[ ! -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty \
    && grep -qF '12-hostname.sh' "$BOOTSTRAP_OUTPUT"
)

test_archive_syntax_errors_do_not_run_and_are_cleaned_up() (
  local file
  for file in setup.sh scripts/menu.sh; do
    (
      make_bootstrap_fixture || return 1
      printf '\nif then\n' >>"$BOOTSTRAP_TREE/$file"
      pack_bootstrap_fixture || return 1
      if run_remote_bootstrap; then return 1; fi
      [[ ! -e "$BOOTSTRAP_LOG" ]] && bootstrap_tmp_is_empty
    ) || return 1
  done
)

test_sudo_relaunch_uses_complete_local_tree_and_preserves_arguments() (
  (( EUID != 0 )) || return 0
  make_bootstrap_fixture && make_sudo_stub || return 1
  local status=0
  bash -c 'source "$1" || exit; need_root "argument with spaces"' \
    bash "$BOOTSTRAP_TREE/setup.sh" >"$BOOTSTRAP_OUTPUT" 2>&1 || status=$?
  [[ "$status" == 37 ]] \
    && grep -qxF "$BOOTSTRAP_TREE/setup.sh" "$BOOTSTRAP_SUDO_LOG" \
    && grep -qxF 'argument with spaces' "$BOOTSTRAP_SUDO_LOG" \
    && [[ ! -e "$BOOTSTRAP_DOWNLOAD_LOG" ]]
)

test_remote_sudo_relaunch_keeps_package_until_child_exits() (
  (( EUID != 0 )) || return 0
  make_bootstrap_fixture && make_sudo_stub || return 1
  printf 'main() { need_root "$@"; }\n' >"$BOOTSTRAP_TREE/scripts/menu.sh"
  pack_bootstrap_fixture || return 1
  local status=0 entry
  run_remote_bootstrap 'argument with spaces' || status=$?
  entry=$(sed -n '2p' "$BOOTSTRAP_SUDO_LOG")
  [[ "$status" == 37 && "$entry" == "$BOOTSTRAP_TMP"/quicksetup.*/repository/setup.sh ]] \
    && grep -qxF 'argument with spaces' "$BOOTSTRAP_SUDO_LOG" \
    && bootstrap_tmp_is_empty
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
