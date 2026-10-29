#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 12. 修改 hostname ----------
step_hostname() {
  local day name cur static tmp
  day=$(date +%Y%m%d) || { err "无法读取当前日期"; return 1; }
  ask "新的 hostname" "Host$day"; name="$REPLY"
  local LC_ALL=C
  [[ ${#name} -le 63 && "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
    || { err "hostname 不合法: 请用 1-63 位英文字母、数字或连字符, 首尾不能是连字符"; return 1; }
  cur=$(hostname) && static=$(hostnamectl --static) \
    || { err "无法读取当前 hostname, 未修改配置"; return 1; }
  [[ -f "$HOSTS_FILE" && ! -L "$HOSTS_FILE" && ! -L "$HOSTNAME_FILE" \
      && ( ! -e "$HOSTNAME_FILE" || -f "$HOSTNAME_FILE" ) ]] \
    || { err "hostname 或 hosts 文件类型异常, 请人工检查"; return 1; }
  tmp=$(mktemp -d) || { err "无法创建 hostname 暂存目录"; return 1; }
  # 只替换本脚本管理的解析记录, 保留原有地址、别名和注释。
  if ! { cp -a "$HOSTS_FILE" "$tmp/hosts" && awk -v name="$name" '
    $0 !~ /[[:space:]]# VPS-QuickSetup hostname$/ { print }
    END { printf "127.0.1.1\t%s # VPS-QuickSetup hostname\n", name }
  ' "$HOSTS_FILE" >"$tmp/hosts.new"; }; then
    rm -rf -- "$tmp"; err "准备 hostname 配置失败, 未修改系统"; return 1
  fi
  if [[ "$cur" == "$name" && "$static" == "$name" ]] && cmp -s "$HOSTS_FILE" "$tmp/hosts.new"; then
    rm -rf -- "$tmp"; skip "hostname 已是 $name"; return 0
  fi
  if ! { backup_file "$HOSTNAME_FILE" && backup_file "$HOSTS_FILE"; }; then
    rm -rf -- "$tmp"; err "hostname 配置备份失败, 未修改系统"; return 1
  fi
  if ! cat "$tmp/hosts.new" >"$HOSTS_FILE"; then
    cat "$tmp/hosts" >"$HOSTS_FILE" || err "hosts 恢复失败, 请检查备份: $BACKUP_DIR"
    rm -rf -- "$tmp"; err "写入 hosts 失败, 未设置 hostname"; return 1
  fi
  # 显式选择 static/transient, 不让 pretty hostname 简化用户输入。
  if hostnamectl --static --transient set-hostname "$name" \
      && [[ "$(hostname)" == "$name" && "$(hostnamectl --static)" == "$name" ]]; then
    rm -rf -- "$tmp"; ok "hostname 已设为 $name"; return 0
  fi
  err "设置或校验 hostname 失败, 尝试恢复原配置"
  local restored=yes
  cat "$tmp/hosts" >"$HOSTS_FILE" || restored=no
  hostnamectl --static set-hostname "$static" || restored=no
  hostname "$cur" || restored=no
  if [[ "$restored" == yes ]]; then
    warn "已恢复原 hostname 和 hosts"
  else
    err "自动恢复未完成, 请检查备份: $BACKUP_DIR"
  fi
  rm -rf -- "$tmp"
  return 1
}
