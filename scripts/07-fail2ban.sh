#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 7. fail2ban ----------
f2b_content() {
  local ports; ports=$(ssh_ports | paste -sd, -)
  cat <<EOT
# 由 VPS-QuickSetup 管理
[sshd]
enabled  = true
port     = $ports
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOT
}
f2b_refresh() { # 端口变化后同步 jail
  [[ -f "$F2B_JAIL" ]] || return 0
  local new; new=$(f2b_content)
  [[ "$new" == "$(cat "$F2B_JAIL")" ]] && return 0
  printf '%s\n' "$new" >"$F2B_JAIL"
  systemctl restart fail2ban && info "fail2ban 端口已同步: $(ssh_ports | paste -sd, -)"
}
step_fail2ban() {
  apt_install fail2ban python3-systemd
  local new; new=$(f2b_content)
  if [[ -f "$F2B_JAIL" && "$new" == "$(cat "$F2B_JAIL")" ]] && systemctl is-active fail2ban >/dev/null; then
    skip "fail2ban 已配置并运行"
  else
    backup_file "$F2B_JAIL"
    printf '%s\n' "$new" >"$F2B_JAIL"
    systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban
    sleep 2; ok "fail2ban 已配置"
  fi
  fail2ban-client status sshd 2>/dev/null || warn "fail2ban sshd jail 未就绪, 请检查: journalctl -u fail2ban"
}
