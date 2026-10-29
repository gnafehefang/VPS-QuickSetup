#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

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
