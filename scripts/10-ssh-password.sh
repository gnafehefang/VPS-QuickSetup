#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 10. 禁用密码登录 ----------
step_nopass() { # [本轮已确认的 user port]; 单独运行不复用登录确认
  local tested_user="${1:-}" tested_port="${2:-}"
  if [[ "$(sshd_val passwordauthentication)" == no && "$(sshd_val kbdinteractiveauthentication)" == no \
        && "$(sshd_val pubkeyauthentication)" == yes ]]; then
    sshd_verify_policy PubkeyAuthentication yes PasswordAuthentication no KbdInteractiveAuthentication no || return 1
    skip "密码登录已禁用"; return 0; fi
  local users; users=$(login_users_with_keys | tr '\n' ' ')
  [[ -z "$users" ]] && { err "没有任何用户配置了有效公钥, 拒绝禁用密码登录 (先用菜单 3)"; return 1; }
  info "已配置公钥的用户: $users"
  if [[ -n "$tested_user" && -n "$tested_port" ]]; then
    local port; port=$(ssh_login_test_port) || return 1
    [[ "$port" == "$tested_port" ]] || { err "SSH 目标端口已变化, 请重新测试后再禁用密码登录"; return 1; }
    confirm_admin_login "$tested_user" "$port" "$tested_user" "$tested_port" || return 1
  else
    confirm "你确认已经用密钥成功登录过吗?" n || { warn "已取消"; return 1; }
  fi
  sshd_begin_change || return 1
  if ! { qs_set PubkeyAuthentication yes && qs_set PasswordAuthentication no && qs_set KbdInteractiveAuthentication no; }; then
    sshd_abort_change; return 1
  fi
  sshd_apply reload PubkeyAuthentication yes PasswordAuthentication no KbdInteractiveAuthentication no || return 1
  ok "已禁用密码登录 (仅允许密钥)"
}
