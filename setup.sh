#!/usr/bin/env bash
# VPS-QuickSetup - 模块加载及启动入口 (Debian / Ubuntu)
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/gnafehefang/VPS-QuickSetup/main/setup.sh)
set -o pipefail

quicksetup_load_modules() {
  local module
  local modules=(
    common.sh ssh-common.sh keys-common.sh login-check.sh
    01-update.sh 02-timezone.sh 03-pubkey.sh 04-admin.sh
    05-ssh-port.sh 06-ufw.sh 07-fail2ban.sh 08-swap.sh
    09-tcp.sh 10-ssh-password.sh 11-ssh-root.sh 12-hostname.sh
    13-all.sh 14-status.sh menu.sh
  )
  # 全部预检通过后才加载, 缺失或损坏时不进入菜单。
  for module in "${modules[@]}"; do
    if [[ ! -f "$QUICKSETUP_ROOT/scripts/$module" || ! -r "$QUICKSETUP_ROOT/scripts/$module" ]]; then
      printf '[错误] 模块缺失或不可读: %s/scripts/%s; 请使用完整仓库\n' "$QUICKSETUP_ROOT" "$module" >&2
      return 1
    fi
    bash -n "$QUICKSETUP_ROOT/scripts/$module" || return 1
  done
  # shellcheck source=scripts/common.sh
  source "$QUICKSETUP_ROOT/scripts/common.sh" || return 1
  # shellcheck source=scripts/ssh-common.sh
  source "$QUICKSETUP_ROOT/scripts/ssh-common.sh" || return 1
  # shellcheck source=scripts/keys-common.sh
  source "$QUICKSETUP_ROOT/scripts/keys-common.sh" || return 1
  # shellcheck source=scripts/login-check.sh
  source "$QUICKSETUP_ROOT/scripts/login-check.sh" || return 1
  # shellcheck source=scripts/01-update.sh
  source "$QUICKSETUP_ROOT/scripts/01-update.sh" || return 1
  # shellcheck source=scripts/02-timezone.sh
  source "$QUICKSETUP_ROOT/scripts/02-timezone.sh" || return 1
  # shellcheck source=scripts/03-pubkey.sh
  source "$QUICKSETUP_ROOT/scripts/03-pubkey.sh" || return 1
  # shellcheck source=scripts/04-admin.sh
  source "$QUICKSETUP_ROOT/scripts/04-admin.sh" || return 1
  # shellcheck source=scripts/05-ssh-port.sh
  source "$QUICKSETUP_ROOT/scripts/05-ssh-port.sh" || return 1
  # shellcheck source=scripts/06-ufw.sh
  source "$QUICKSETUP_ROOT/scripts/06-ufw.sh" || return 1
  # shellcheck source=scripts/07-fail2ban.sh
  source "$QUICKSETUP_ROOT/scripts/07-fail2ban.sh" || return 1
  # shellcheck source=scripts/08-swap.sh
  source "$QUICKSETUP_ROOT/scripts/08-swap.sh" || return 1
  # shellcheck source=scripts/09-tcp.sh
  source "$QUICKSETUP_ROOT/scripts/09-tcp.sh" || return 1
  # shellcheck source=scripts/10-ssh-password.sh
  source "$QUICKSETUP_ROOT/scripts/10-ssh-password.sh" || return 1
  # shellcheck source=scripts/11-ssh-root.sh
  source "$QUICKSETUP_ROOT/scripts/11-ssh-root.sh" || return 1
  # shellcheck source=scripts/12-hostname.sh
  source "$QUICKSETUP_ROOT/scripts/12-hostname.sh" || return 1
  # shellcheck source=scripts/13-all.sh
  source "$QUICKSETUP_ROOT/scripts/13-all.sh" || return 1
  # shellcheck source=scripts/14-status.sh
  source "$QUICKSETUP_ROOT/scripts/14-status.sh" || return 1
  # shellcheck source=scripts/menu.sh
  source "$QUICKSETUP_ROOT/scripts/menu.sh" || return 1
}

quicksetup_download() (
  local dir tool
  for tool in curl tar mktemp bash; do
    command -v "$tool" >/dev/null 2>&1 || { printf '[错误] 远程启动需要 %s\n' "$tool" >&2; return 1; }
  done
  dir=$(mktemp -d "${TMPDIR:-/tmp}/quicksetup.XXXXXX") || return 1
  trap 'rm -rf -- "$dir"' EXIT
  # 从同一个归档启动入口及全部模块, 不逐个读取浮动分支。
  if ! curl -fsSL --connect-timeout 10 --max-time 120 \
      https://github.com/gnafehefang/VPS-QuickSetup/archive/refs/heads/main.tar.gz -o "$dir/repository.tar.gz"; then
    printf '[错误] 下载完整脚本包失败, 未运行任何配置步骤\n' >&2
    return 1
  fi
  mkdir -- "$dir/repository" || return 1
  if ! tar -xzf "$dir/repository.tar.gz" -C "$dir/repository" \
      --strip-components=1 --no-same-owner --no-same-permissions; then
    printf '[错误] 解压脚本包失败, 未运行任何配置步骤\n' >&2
    return 1
  fi
  if [[ ! -f "$dir/repository/setup.sh" || -L "$dir/repository/setup.sh" ]] \
      || ! bash -n "$dir/repository/setup.sh"; then
    printf '[错误] 脚本包入口缺失或损坏\n' >&2
    return 1
  fi
  # 保留父进程, 等待 sudo / 菜单退出后再清理整个临时目录。
  bash "$dir/repository/setup.sh" "$@"
)

if [[ -f "${BASH_SOURCE[0]}" ]]; then
  QUICKSETUP_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || { return 1 2>/dev/null || exit 1; }
  quicksetup_load_modules || { return 1 2>/dev/null || exit 1; }
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
  fi
elif [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  quicksetup_download "$@"
else
  printf '[错误] 请从完整仓库 source setup.sh, 不支持 source 远程流\n' >&2
  return 1
fi
