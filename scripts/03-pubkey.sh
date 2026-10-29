#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 3. 添加公钥 ----------
step_pubkey() {
  ask "要给哪个用户添加公钥" "root"; local user="$REPLY" default_method=1 keys=""
  id "$user" >/dev/null 2>&1 || { err "用户 $user 不存在 (可先用菜单 4 创建)"; return 1; }
  if has_keys "$user"; then
    info "$user 已有有效公钥"
    echo "  0) 保留现有公钥, 跳过添加"
    default_method=0
  fi
  echo "  1) 粘贴公钥内容 (例如 ssh-ed25519 AAAA... 本机 ~/.ssh/id_ed25519.pub 的内容)"
  echo "  2) 从 GitHub 拉取 (https://github.com/<用户名>.keys)"
  ask "选择" "$default_method"
  case "$REPLY" in
    0) ;;
    2) ask "GitHub 用户名 (已有有效公钥时可回车跳过)" ""
       if [[ -n "$REPLY" ]]; then
         keys=$(curl -fsSL "https://github.com/$REPLY.keys") || { err "拉取失败"; return 1; }
         [[ -n "$keys" ]] || { err "该 GitHub 账号没有公钥"; return 1; }
       fi ;;
    *) ask "粘贴公钥 (一行, 已有有效公钥时可回车跳过)" ""; keys="$REPLY" ;;
  esac
  if [[ -z "$keys" ]]; then
    has_keys "$user" || { err "未输入公钥, 且 $user 没有有效公钥, 不能跳过"; return 1; }
    skip "保留 $user 的现有有效公钥"
    return 0
  fi
  printf '%s\n' "$keys" | add_key_lines "$user" || return 1
  has_keys "$user" || { err "$user 仍没有有效公钥"; return 1; }
  ok "$user 的 authorized_keys 有效"
}
