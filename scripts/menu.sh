#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

menu() {
  cat <<EOT

${c_grn}======= VPS-QuickSetup =======${c_off}
 1. 系统更新 + 基础工具
 2. 设置时区 (默认 $DEFAULT_TZ)
 3. 添加公钥 (启用密钥登录)
 4. 创建 admin 用户
 5. 修改 SSH 端口 (默认随机 $SSH_RANDOM_PORT_MIN-$SSH_RANDOM_PORT_MAX)
 6. 安装 UFW
 7. 安装 fail2ban
 8. 设置 swap
 9. TCP 调优 (BBR)
10. 禁用密码登录
11. 禁用 root 登录
12. 修改 hostname
13. ALL (按安全顺序执行)
14. 查看当前状态
 0. 退出
EOT
}

main() {
  need_root "$@"
  check_os
  while true; do
    menu
    ask "请选择" ""
    case "$REPLY" in
      1) step_update ;;  2) step_tz ;;      3) step_pubkey ;;  4) step_admin ;;
      5) step_port ;;    6) step_ufw ;;     7) step_fail2ban ;; 8) step_swap ;;
      9) step_tcp ;;    10) step_nopass ;; 11) step_noroot ;; 12) step_hostname ;;
      13) step_all ;;   14) summary ;;     0|q|Q) echo "再见"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}
