#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

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
