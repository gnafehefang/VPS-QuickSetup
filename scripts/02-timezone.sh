#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 2. 时区 ----------
step_tz() {
  local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
  info "当前时区: ${cur:-未知}"
  ask "时区" "$DEFAULT_TZ"; local tz="$REPLY"
  [[ -f "/usr/share/zoneinfo/$tz" ]] || { err "无效时区: $tz"; return 1; }
  [[ "$cur" == "$tz" ]] && { skip "时区已是 $tz"; return 0; }
  timedatectl set-timezone "$tz" 2>/dev/null || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "$tz" >/etc/timezone; }
  ok "时区已设为 $tz ($(date '+%F %T %Z'))"
}
