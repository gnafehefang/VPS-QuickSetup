#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 6. UFW ----------
ufw_allow_ssh() {
  LC_ALL=C ufw allow "$1/tcp" comment SSH >/dev/null || { err "UFW 放行 $1/tcp 失败"; return 1; }
  ok "UFW 已放行 $1/tcp"
}
step_ufw() {
  apt_install ufw || { err "UFW 安装失败"; return 1; }
  local ports status p
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法确认 SSH 端口, 拒绝启用 UFW"; return 1; }
  for p in $ports; do
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ && "$p" -le 65535 ]] || { err "无效 SSH 端口: $p"; return 1; }
  done
  status=$(LC_ALL=C ufw status) || { err "无法读取 UFW 状态"; return 1; }
  # UFW 自身会跳过重复规则, 不把同端口的 DENY 或受限规则误判成已放行。
  for p in $ports; do ufw_allow_ssh "$p" || return 1; done
  if [[ "$status" == *"Status: active"* ]]; then skip "UFW 已启用"
  else
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1
    ufw --force enable || { err "UFW 启用失败"; return 1; }
    ok "UFW 已启用"
  fi
  ufw status
}
