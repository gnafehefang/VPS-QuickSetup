#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 8. swap ----------
step_swap() {
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    skip "已有 swap:"; swapon --show
  else
    local mem_mb size_mb free_mb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if   (( mem_mb < 2048 )); then size_mb=2048
    elif (( mem_mb <= 4096 )); then size_mb=$mem_mb
    else size_mb=4096; fi
    free_mb=$(df -Pm / | awk 'NR==2{print $4}')
    if (( free_mb < size_mb + 1024 )); then err "磁盘剩余 ${free_mb}M, 不足以创建 ${size_mb}M swap"; return 1; fi
    info "内存 ${mem_mb}M, 创建 ${size_mb}M /swapfile"
    fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
    chmod 600 /swapfile
    if ! { mkswap /swapfile >/dev/null && swapon /swapfile; }; then
      warn "fallocate 文件不可用, 改用 dd"; swapoff /swapfile 2>/dev/null; rm -f /swapfile
      dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; chmod 600 /swapfile
      mkswap /swapfile >/dev/null && swapon /swapfile || { err "swap 创建失败"; rm -f /swapfile; return 1; }
    fi
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "swap 已启用"; swapon --show
  fi
  if [[ "$(sysctl -n vm.swappiness)" == 10 && -f "$SWAP_SYSCTL" ]]; then skip "swappiness 已是 10"
  else echo "vm.swappiness = 10" >"$SWAP_SYSCTL"; sysctl -q -p "$SWAP_SYSCTL" && ok "swappiness = 10"; fi
}
