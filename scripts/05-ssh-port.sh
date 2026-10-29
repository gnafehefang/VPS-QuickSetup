#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 5. 修改 SSH 端口 ----------
PENDING_OLD_PORTS=""
SELECTED_SSH_PORT=""
random_ssh_port() { # random_ssh_port "当前 SSH 端口", 同时避开已有 TCP 连接占用的本地端口。
  local current="${1:-}" sockets used candidates port
  sockets=$(ss -tanH 2>/dev/null) || { err "无法读取 TCP 端口占用情况, 不自动选择端口"; return 1; }
  used=$(awk '{p=$4; sub(/^.*:/,"",p); if(p~/^[0-9]+$/) print p}' <<<"$sockets" | paste -sd' ' -)
  current=${current//$'\n'/ }
  candidates=$(shuf -i "$SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX") \
    || { err "无法生成随机端口候选"; return 1; }
  for port in $candidates; do
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -ge "$SSH_RANDOM_PORT_MIN" && "$port" -le "$SSH_RANDOM_PORT_MAX" ]] || continue
    [[ " $current $used " != *" $port "* ]] || continue
    printf '%s\n' "$port"; return 0
  done
  err "随机范围 $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX 内没有可用端口"; return 1
}
remove_old_ports() { # remove_old_ports "p1 p2" keep
  local olds="$1" keep="$2" p
  [[ -z "$olds" ]] && return 0
  [[ "$keep" =~ ^[1-9][0-9]{0,4}$ && "$keep" -le 65535 && " $olds " != *" $keep "* ]] \
    || { err "保留端口无效或同时属于旧端口"; return 1; }
  sshd_begin_change || return 1
  if ! { sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF" && echo "Port $keep" >>"$QS_CONF"; }; then
    sshd_abort_change; return 1
  fi
  sshd_apply restart || return 1
  if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q "Status: active"; then
    for p in $olds; do ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p" >/dev/null 2>&1; done
    [[ " $olds " == *" 22 "* ]] && ufw delete allow OpenSSH >/dev/null 2>&1
  fi
  f2b_refresh
  PENDING_OLD_PORTS=""
  ok "已关闭旧端口: $olds, 现在只监听 $keep"
}
step_port() { # step_port [defer]
  local defer="${1:-}" cur new suggested sockets p olds=""
  SELECTED_SSH_PORT=""
  cur=$(ssh_ports) && [[ -n "$cur" ]] || { err "无法确认当前 SSH 端口, 停止修改"; return 1; }
  cur=${cur//$'\n'/ }
  info "当前 SSH 端口: $cur"
  if suggested=$(random_ssh_port "$cur"); then
    ask "新的 SSH 端口 [随机范围: $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX, 回车使用: $suggested]" ""
  else
    suggested=""
    warn "随机默认端口不可用, 请手动输入"
    ask "新的 SSH 端口 [随机范围: $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX, 需手动输入]" ""
  fi
  new="${REPLY:-$suggested}"
  [[ "$new" =~ ^[1-9][0-9]{0,4}$ && "$new" -le 65535 ]] || { err "端口不合法, 请输入 1-65535 且不要加前导零"; return 1; }
  for p in $cur; do [[ "$p" != "$new" ]] && olds="$olds $p"; done; olds="${olds# }"
  if [[ "$cur" == "$new" ]]; then SELECTED_SSH_PORT="$new"; skip "SSH 已经只监听 $new"; return 0; fi
  sockets=$(ss -tanH "( sport = :$new )" 2>/dev/null) || { err "无法复核 TCP 端口占用情况, 停止修改"; return 1; }
  if [[ -n "$sockets" && " $cur " != *" $new "* ]]; then err "端口 $new 已被其他程序或 TCP 连接占用"; return 1; fi
  if command -v ufw >/dev/null; then
    local status
    status=$(LC_ALL=C ufw status) || { err "无法读取 UFW 状态, 停止修改 SSH 端口"; return 1; }
    if [[ "$status" == *"Status: active"* ]]; then ufw_allow_ssh "$new" || return 1; fi
  fi
  sshd_begin_change || return 1
  # 注释掉其他位置的 Port, 统一由 00-quicksetup.conf 管理
  local f
  for f in "$MAIN_CONF" "$SSH_CONF_DIR"/*.conf; do
    [[ -f "$f" && "$f" != "$QS_CONF" ]] || continue
    if grep -Eiq '^[[:space:]]*Port[[:space:]]' "$f"; then
      sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$f" || { sshd_abort_change; return 1; }
    else
      [[ $? -eq 1 ]] || { sshd_abort_change; return 1; }
    fi
  done
  sed -i '/^[[:space:]]*Port[[:space:]]/Id' "$QS_CONF" || { sshd_abort_change; return 1; }
  for p in $olds $new; do echo "Port $p" >>"$QS_CONF" || { sshd_abort_change; return 1; }; done
  sshd_apply restart || return 1
  ok "sshd 已在 $new 监听 (过渡期同时保留: ${olds:-无})"
  SELECTED_SSH_PORT="$new"
  f2b_refresh
  [[ -z "$olds" ]] && return 0
  PENDING_OLD_PORTS="$olds"
  if [[ "$defer" == defer ]]; then info "旧端口 $olds 先保留, 最后再关闭"; return 0; fi
  warn "请另开一个窗口测试:  ssh -p $new <用户>@<服务器IP>"
  if confirm "新端口 $new 登录测试成功了吗? 成功则关闭旧端口 $olds" n; then
    remove_old_ports "$olds" "$new"
  else
    warn "旧端口 $olds 仍保留, 测试成功后可再次运行菜单 5 (输入 $new) 来关闭"
  fi
}
