#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 1. 系统更新 ----------
step_update() {
  info "更新系统并安装基础工具..."
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt_install curl wget sudo ca-certificates nano htop unzip
  ok "系统更新完成"
}
