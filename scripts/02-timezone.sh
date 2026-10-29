#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 2. 时区 + 自动校时 ----------
ntp_value() { # 只接受成功读取的布尔值, 不把失败输出或空值当作状态。
  local value
  value=$(timedatectl show -p "$1" --value 2>/dev/null) || return 1
  case "$value" in
    yes|no) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

ensure_ntp() {
  local enabled supported synced
  enabled=$(ntp_value NTP) || enabled=""
  if [[ "$enabled" == yes ]]; then
    skip "自动校时已启用"
  else
    supported=$(ntp_value CanNTP) || supported=""
    if [[ "$supported" == no ]]; then
      err "未发现 timedatectl 可识别的校时服务, 请检查 chrony / systemd-timesyncd; 不自动安装或替换服务"
      return 1
    fi
    timedatectl set-ntp true || { err "启用自动校时失败, 请检查校时服务和 systemd 状态"; return 1; }
    enabled=$(ntp_value NTP) || enabled=""
    [[ "$enabled" == yes ]] || { err "已请求启用自动校时, 但未能确认 NTP=yes, 不标记为成功"; return 1; }
    ok "自动校时已启用"
  fi
  synced=$(ntp_value NTPSynchronized) || synced=""
  case "$synced" in
    yes) ok "系统时钟已同步" ;;
    no) warn "自动校时已启用, 但系统时钟尚未同步; 请稍后用 timedatectl status 复查" ;;
    *) warn "自动校时已启用, 但无法读取时钟同步状态; 不认为已同步, 请用 timedatectl status 检查" ;;
  esac
  return 0
}

step_tz() {
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat "$TIMEZONE_FILE" 2>/dev/null)
  info "当前时区: ${cur:-未知}"
  ask "时区" "$DEFAULT_TZ"; local tz="$REPLY"
  [[ -f "$ZONEINFO_DIR/$tz" ]] || { err "无效时区: $tz"; return 1; }
  if [[ "$cur" == "$tz" ]]; then
    skip "时区已是 $tz"
  elif timedatectl set-timezone "$tz" 2>/dev/null \
      || { ln -sf "$ZONEINFO_DIR/$tz" "$LOCALTIME_FILE" && printf '%s\n' "$tz" >"$TIMEZONE_FILE"; }; then
    ok "时区已设为 $tz ($(date '+%F %T %Z'))"
  else
    err "设置时区失败, 不标记为完成"
    return 1
  fi
  ensure_ntp
}
