#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- SSH 工具函数 ----------
ssh_svc() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1 && systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}
sshd_dump_val() { # 保留多值顺序, 相同值只显示一次, 不丢弃不同用户或端口。
  awk -v k="${2,,}" '$1==k{for(i=2;i<=NF;i++) if(!seen[$i]++) print $i}' <<<"$1" | paste -sd' ' -
}
sshd_val() {
  local dump
  mkdir -p "$SSHD_RUN_DIR" && dump=$(sshd -T 2>/dev/null) || return 1
  sshd_dump_val "$dump" "$1"
}
ssh_ports() { mkdir -p "$SSHD_RUN_DIR"; sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un; }

ensure_include() {
  mkdir -p "$SSH_CONF_DIR" || return 1
  [[ -f "$QS_CONF" ]] || { echo "# 由 VPS-QuickSetup 管理" >"$QS_CONF" && chmod 644 "$QS_CONF"; } || return 1
  local tmp
  tmp=$(mktemp "$MAIN_CONF.quicksetup.XXXXXX") || return 1
  if ! { cp -a "$MAIN_CONF" "$tmp" && awk -v managed="$QS_CONF" '
    BEGIN { print "Include " managed }
    tolower($1) == "include" && $2 == managed && (NF == 2 || $3 ~ /^#/) { next }
    { print }
  ' "$MAIN_CONF" >"$tmp" && mv -f -- "$tmp" "$MAIN_CONF"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}
# 先备份 -> 修改 -> sshd -t 校验 -> 失败回滚
SNAP=""
sshd_snapshot() {
  [[ -z "$SNAP" ]] || { err "上次快照尚未清理, 请先检查: $SNAP"; return 1; }
  [[ -f "$MAIN_CONF" && ! -L "$MAIN_CONF" && ! -L "$SSH_CONF_DIR" && ! -L "$QS_CONF" ]] \
    || { err "SSH 配置不存在或受管路径是符号链接, 拒绝自动修改"; return 1; }
  local dir failed=no
  dir=$(mktemp -d) || { err "无法创建 SSH 快照目录"; return 1; }
  cp -a "$MAIN_CONF" "$dir/main" || failed=yes
  if [[ -d "$SSH_CONF_DIR" ]]; then cp -a "$SSH_CONF_DIR" "$dir/d" || failed=yes
  elif [[ -e "$SSH_CONF_DIR" ]]; then failed=yes
  else : >"$dir/d.absent" || failed=yes; fi
  if [[ "$failed" == no ]] && backup_file "$MAIN_CONF" && backup_file "$QS_CONF" && touch "$dir/complete"; then
    SNAP="$dir"
    return 0
  fi
  err "SSH 备份不完整, 未修改配置"
  rm -rf -- "$dir" || warn "临时快照清理失败: $dir"
  return 1
}
sshd_discard_snapshot() {
  [[ -n "$SNAP" ]] || return 0
  [[ -f "$SNAP/complete" ]] || { err "拒绝删除不完整快照: $SNAP"; return 1; }
  rm -rf -- "$SNAP" || return 1
  SNAP=""
}
sshd_restore() {
  [[ -n "$SNAP" && -f "$SNAP/complete" && -f "$SNAP/main" \
      && ( -d "$SNAP/d" || -f "$SNAP/d.absent" ) && ! -L "$SSH_CONF_DIR" ]] \
    || { err "快照不完整或目标路径异常, 不替换现有配置: $SNAP"; return 1; }
  local stage
  stage=$(mktemp -d "$(dirname "$SSH_CONF_DIR")/.quicksetup-restore.XXXXXX") || return 1
  if ! cp -a "$SNAP/main" "$stage/main" \
      || { [[ -d "$SNAP/d" ]] && ! cp -a "$SNAP/d" "$stage/d"; }; then
    rm -rf -- "$stage"
    err "快照暂存失败, 现有配置未被替换"
    return 1
  fi
  # 暂存和目标处于同一文件系统, 先保留现目录, 完成恢复后才清理。
  if [[ -e "$SSH_CONF_DIR" ]] && ! mv -T -- "$SSH_CONF_DIR" "$stage/displaced"; then
    err "无法暂存现有目录, 保留恢复文件: $stage"
    return 1
  fi
  if [[ -d "$stage/d" ]] && ! mv -T -- "$stage/d" "$SSH_CONF_DIR"; then
    if [[ -e "$stage/displaced" ]]; then mv -T -- "$stage/displaced" "$SSH_CONF_DIR" || true; fi
    err "目录恢复失败, 保留恢复文件: $stage"
    return 1
  fi
  if ! mv -Tf -- "$stage/main" "$MAIN_CONF"; then
    if [[ -e "$SSH_CONF_DIR" ]]; then mv -T -- "$SSH_CONF_DIR" "$stage/restored" || return 1; fi
    if [[ -e "$stage/displaced" ]]; then mv -T -- "$stage/displaced" "$SSH_CONF_DIR" || true; fi
    err "主配置恢复失败, 保留恢复文件: $stage"
    return 1
  fi
  rm -rf -- "$stage" || warn "恢复成功, 暂存目录清理失败: $stage"
  return 0
}
sshd_abort_change() {
  if sshd_restore; then sshd_discard_snapshot || warn "快照清理失败: $SNAP"
  else err "恢复失败, 请保留当前连接并检查快照: $SNAP"; fi
  return 1
}
sshd_begin_change() {
  sshd_snapshot || return 1
  ensure_include || { err "准备 SSH 配置失败"; sshd_abort_change; return 1; }
}
sshd_validate_or_rollback() {
  if mkdir -p "$SSHD_RUN_DIR" && sshd -t; then return 0; fi
  err "sshd 配置校验失败, 回滚"
  sshd_abort_change
}
sshd_wait_ready() { # sshd_wait_ready service "port ..."
  local svc="$1" ports="$2" _attempt p ready
  [[ -n "$ports" ]] || return 1
  for _attempt in 1 2 3 4 5; do
    ready=yes
    systemctl is-active --quiet "$svc" || ready=no
    for p in $ports; do ss -ltnH "( sport = :$p )" | grep -q . || ready=no; done
    [[ "$ready" == yes ]] && return 0
    sleep 1
  done
  return 1
}
sshd_policy_layout_supported() {
  local f
  for f in "$MAIN_CONF" "$SSH_CONF_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    awk -v managed="$QS_CONF" -v pattern="$SSH_CONF_DIR/*.conf" '
      tolower($1) == "match" { exit 1 }
      tolower($1) == "include" {
        if (($2 != managed && $2 != pattern) || (NF > 2 && $3 !~ /^#/)) exit 1
      }
    ' "$f" || { err "存在 Match 或非标准 Include, 无法保证所有连接的安全策略, 请人工检查: $f"; return 1; }
  done
}
sshd_expect_settings() { # sshd_expect_settings dump Key value ...
  local dump="$1" key expected actual
  shift
  while (( $# >= 2 )); do
    key="${1,,}"; expected="$2"; shift 2
    actual=$(awk -v k="$key" '$1 == k {for (i=2; i<=NF; i++) print $i}' <<<"$dump" | sort -u | paste -sd' ' -)
    [[ "$actual" == "$expected" ]] || { err "SSH 有效配置不符合预期: $key=$actual (预期 $expected)"; return 1; }
  done
}
sshd_verify_policy() { # sshd_verify_policy Key value ...
  [[ $# -gt 0 ]] || return 0
  sshd_policy_layout_supported || return 1
  local dump u client_ip _client_port server_ip server_port
  dump=$(sshd -T) && sshd_expect_settings "$dump" "$@" || return 1
  read -r client_ip _client_port server_ip server_port <<<"${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
  for u in root $(login_users_with_keys); do
    dump=$(sshd -T -C "user=$u,addr=$client_ip,host=$client_ip,laddr=$server_ip,lport=$server_port") \
      && sshd_expect_settings "$dump" "$@" || return 1
  done
}
sshd_apply() { # sshd_apply restart|reload [Key value ...]
  local action="$1" svc ports activated=no
  shift
  sshd_validate_or_rollback || return 1
  if ! sshd_verify_policy "$@"; then
    err "安全策略未生效, 恢复原配置且不重载 SSH"
    sshd_abort_change
    return 1
  fi
  svc=$(ssh_svc)
  ports=$(ssh_ports) && [[ -n "$ports" ]] || { err "无法读取预期 SSH 端口"; sshd_abort_change; return 1; }
  if [[ "$action" == restart ]]; then sshd_restart && activated=yes
  else systemctl reload "$svc" && activated=yes; fi
  if [[ "$activated" == yes ]] && sshd_wait_ready "$svc" "$ports"; then
    sshd_discard_snapshot || warn "配置已生效, 快照清理失败: $SNAP"
    return 0
  fi
  err "SSH $action 或监听检查失败, 恢复原配置"
  if sshd_restore && sshd_socket_restore "$svc" && systemctl restart "$svc" && sshd_wait_ready "$svc" "$(ssh_ports)"; then
    sshd_discard_snapshot || warn "快照清理失败: $SNAP"
    warn "已恢复原 SSH 配置, 未关闭旧防火墙入口"
  else
    err "自动恢复未完成, 请保留当前连接并检查快照: $SNAP"
  fi
  return 1
}
qs_set() { # qs_set Key "value"   (在 00-quicksetup.conf 里设置单值项)
  sed -i "/^[[:space:]]*$1[[:space:]]/Id" "$QS_CONF" || return 1
  echo "$1 $2" >>"$QS_CONF"
}
sshd_socket_snapshot() {
  local svc="$1" socket_enabled service_enabled active=no
  [[ -n "$SNAP" && -f "$SNAP/complete" ]] || { err "切换 ssh.socket 前必须有完整 SSH 快照"; return 1; }
  [[ -f "$SNAP/socket.saved" ]] && return 0
  if [[ -e "$SSH_SERVICE_DROPIN" ]]; then
    cp -a "$SSH_SERVICE_DROPIN" "$SNAP/service-dropin" && backup_file "$SSH_SERVICE_DROPIN" || return 1
  fi
  if [[ -e "$SSH_SOCKET_DROPIN" ]]; then
    cp -a "$SSH_SOCKET_DROPIN" "$SNAP/socket-dropin" && backup_file "$SSH_SOCKET_DROPIN" || return 1
  fi
  socket_enabled=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
  service_enabled=$(systemctl is-enabled "$svc" 2>/dev/null) || true
  [[ -n "$socket_enabled" && -n "$service_enabled" ]] || { err "无法备份 systemd 启用状态"; return 1; }
  systemctl is-active --quiet ssh.socket && active=yes
  printf '%s\n' "$socket_enabled" >"$SNAP/socket.enabled" \
    && printf '%s\n' "$service_enabled" >"$SNAP/service.enabled" \
    && printf '%s\n' "$active" >"$SNAP/socket.active" && touch "$SNAP/socket.saved"
}
restore_unit_enablement() {
  case "$2" in
    enabled) systemctl enable "$1" >/dev/null 2>&1 ;;
    enabled-runtime) systemctl enable --runtime "$1" >/dev/null 2>&1 ;;
    disabled) systemctl disable "$1" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}
sshd_socket_restore() {
  local svc="$1" src dst
  [[ -f "$SNAP/socket.changed" ]] || return 0
  [[ -f "$SNAP/socket.saved" && -s "$SNAP/socket.enabled" && -s "$SNAP/service.enabled" && -s "$SNAP/socket.active" ]] || return 1
  for src in service-dropin socket-dropin; do
    if [[ "$src" == service-dropin ]]; then dst="$SSH_SERVICE_DROPIN"; else dst="$SSH_SOCKET_DROPIN"; fi
    if [[ -e "$SNAP/$src" ]]; then
      mkdir -p "$(dirname "$dst")" && cp -a "$SNAP/$src" "$dst" || return 1
    else rm -f -- "$dst" || return 1; fi
  done
  systemctl daemon-reload || return 1
  restore_unit_enablement ssh.socket "$(cat "$SNAP/socket.enabled")" || return 1
  restore_unit_enablement "$svc" "$(cat "$SNAP/service.enabled")" || return 1
  if [[ "$(cat "$SNAP/socket.active")" == yes ]]; then systemctl start ssh.socket
  else systemctl stop ssh.socket; fi
}
sshd_restart() {
  local svc enabled active=no
  svc=$(ssh_svc)
  enabled=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
  systemctl is-active --quiet ssh.socket && active=yes
  # Ubuntu 迁移遗留的 drop-in 也会重新拉起 socket, 必须一起处理。
  if [[ "$enabled" == enabled || "$enabled" == enabled-runtime || "$active" == yes \
        || -e "$SSH_SERVICE_DROPIN" || -e "$SSH_SOCKET_DROPIN" ]]; then
    info "检测到 ssh.socket, 切换为 ssh.service 管理端口"
    sshd_socket_snapshot "$svc" || return 1
    touch "$SNAP/socket.changed" || return 1
    systemctl disable --now ssh.socket || return 1
    rm -f -- "$SSH_SERVICE_DROPIN" "$SSH_SOCKET_DROPIN" || return 1
    systemctl daemon-reload || return 1
    systemctl enable "$svc" || return 1
  fi
  systemctl restart "$svc"
}
