#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 13. ALL ----------
run_step() { echo; echo "${c_blu}========== $1 ==========${c_off}"; shift; "$@" || { warn "该步骤未完成"; return 1; }; }
step_all() {
  ADMIN_USER=""
  PENDING_OLD_PORTS=""
  SELECTED_SSH_PORT=""
  run_step "1. 系统更新" step_update
  run_step "2. 时区 + 自动校时" step_tz
  run_step "3. 添加公钥" step_pubkey || return 1
  run_step "4. 创建管理员" step_admin || { ADMIN_USER=""; return 1; }
  admin_login_ready "$ADMIN_USER" || { ADMIN_USER=""; return 1; }
  run_step "5. 修改 SSH 端口" step_port defer || return 1
  run_step "6. UFW" step_ufw || return 1
  run_step "7. fail2ban" step_fail2ban
  run_step "8. swap" step_swap
  run_step "9. TCP 调优" step_tcp
  local port="$SELECTED_SSH_PORT" u="$ADMIN_USER"
  [[ -n "$port" ]] || { err "未确认目标 SSH 端口, 停止后续收紧操作"; return 1; }
  admin_login_ready "$u" || { ADMIN_USER=""; return 1; }
  echo
  warn "接下来会禁用密码登录、禁用 root、关闭旧端口。"
  if ! confirm_admin_login "$u" "$port"; then warn "已停止。测试通过后可单独运行 10 / 11 / 5"; summary; return 0; fi
  run_step "10. 禁用密码登录" step_nopass "$u" "$port" || return 1
  run_step "11. 禁用 root 登录" step_noroot "$u" "$port" || return 1
  if [[ -n "$PENDING_OLD_PORTS" ]]; then
    echo; run_step "关闭旧端口" remove_old_ports "$PENDING_OLD_PORTS" "$port"
  fi
  run_step "12. 修改 hostname" step_hostname || return 1
  summary
}
