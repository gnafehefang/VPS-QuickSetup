#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 9. TCP 调优 ----------
step_tcp() {
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    err "内核不支持 BBR ($(uname -r))"; return 1; fi
  if [[ -f "$TCP_SYSCTL" && "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr \
        && "$(sysctl -n net.core.default_qdisc)" == fq && "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 1 ]]; then
    skip "BBR + fq 已启用"; return 0; fi
  cat >"$TCP_SYSCTL" <<EOT
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOT
  echo tcp_bbr >/etc/modules-load.d/quicksetup-bbr.conf
  sysctl -q -p "$TCP_SYSCTL" && ok "已启用 BBR: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}
