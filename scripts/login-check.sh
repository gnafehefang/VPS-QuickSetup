#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

ssh_login_test_port() {
  local ports port _client_ip _client_port _server_ip server_port
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法确认 SSH 端口, 停止登录测试"; return 1; }
  ports=$(tr '\n' ' ' <<<"$ports")
  read -r _client_ip _client_port _server_ip server_port <<<"${SSH_CONNECTION:-}"
  for port in "${SELECTED_SSH_PORT:-}" "${server_port:-}" $ports; do
    if [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 && " $ports " == *" $port "* ]]; then
      printf '%s\n' "$port"; return 0
    fi
  done
  err "没有可用的 SSH 测试端口"; return 1
}
confirm_admin_login() { # user port [本轮已确认的 user port]
  local user="$1" port="$2" ip
  admin_login_ready "$user" || return 1
  if [[ "$user" == "${3:-}" && "$port" == "${4:-}" ]]; then
    info "沿用本轮已确认的 $user / 端口 $port 密钥登录与 sudo 测试"
    return 0
  fi
  ip=$(public_ip)
  [[ -n "$ip" && "$ip" != '<服务器IP>' ]] || { err "无法确定服务器地址, 请核对网络后重新测试"; return 1; }
  warn "请另开窗口测试密钥登录:"
  printf 'ssh -o PreferredAuthentications=publickey -p %s %s@%s\n\n' "$port" "$user" "$ip"
  warn "登录后执行:"
  printf 'sudo -i\n\n'
  confirm "$user 已用密钥登录该端口并 sudo 成功, 继续?" n || { warn "已取消"; return 1; }
}
