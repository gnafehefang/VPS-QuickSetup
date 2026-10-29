#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

has_keys() { # has_keys user
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  [[ -n "$home" && -s "$home/.ssh/authorized_keys" ]] && ssh-keygen -l -f "$home/.ssh/authorized_keys" >/dev/null 2>&1
}
login_users_with_keys() {
  local u
  while IFS=: read -r u _ uid _ _ _ sh; do
    [[ "$uid" -eq 0 || "$uid" -ge 1000 ]] || continue
    [[ "$sh" == */nologin || "$sh" == */false ]] && continue
    has_keys "$u" && echo "$u"
  done </etc/passwd
}
sudo_users_with_keys() {
  local u
  for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    [[ "$u" != root ]] && has_keys "$u" && echo "$u"
  done
}

add_key_lines() { # add_key_lines user  (从 stdin 读公钥)
  local user="$1" home grp key_file line tmp fingerprint status last valid=0
  id "$user" >/dev/null 2>&1 || { err "用户 $user 不存在, 不写入公钥"; return 1; }
  home=$(getent passwd "$user" | cut -d: -f6) \
    && grp=$(id -gn "$user") && [[ -n "$grp" && "$home" == /* && "$home" != / && -d "$home" ]] \
    || { err "无法确认 $user 的主目录和用户组, 不写入公钥"; return 1; }
  key_file="$home/.ssh/authorized_keys"
  [[ ! -L "$home" && ! -L "$home/.ssh" && ! -L "$key_file" \
      && ( ! -e "$key_file" || -f "$key_file" ) ]] \
    || { err "公钥目标路径异常或是符号链接, 请人工检查: $key_file"; return 1; }
  tmp=$(mktemp) || { err "无法创建公钥校验临时文件"; return 1; }
  if ! { install -d -m 700 -o "$user" -g "$grp" "$home/.ssh" \
      && touch "$key_file" && chmod 600 "$key_file" && chown "$user:$grp" "$key_file"; }; then
    rm -f -- "$tmp"; err "准备 $user 的公钥文件或权限失败"; return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    printf '%s\n' "$line" >"$tmp" || { rm -f -- "$tmp"; err "暂存公钥失败"; return 1; }
    if ! fingerprint=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then warn "无效公钥, 已忽略: ${line:0:40}..."; continue; fi
    ((valid+=1))
    if grep -qxF -- "$line" "$key_file"; then skip "公钥已存在"; continue
    else
      status=$?
      [[ "$status" == 1 ]] || { rm -f -- "$tmp"; err "读取现有公钥失败"; return 1; }
    fi
    if [[ -s "$key_file" ]]; then
      last=$(tail -c 1 "$key_file") || { rm -f -- "$tmp"; err "读取公钥文件末尾失败"; return 1; }
      if [[ -n "$last" ]]; then
        printf '\n' >>"$key_file" || { rm -f -- "$tmp"; err "写入公钥分隔换行失败"; return 1; }
      fi
    fi
    printf '%s\n' "$line" >>"$key_file" || { rm -f -- "$tmp"; err "写入公钥失败: $key_file"; return 1; }
    ok "已添加: $(awk '{print $2, $NF}' <<<"$fingerprint")"
  done
  rm -f -- "$tmp"
  [[ "$valid" -gt 0 ]] && has_keys "$user" || { err "本次未提供有效公钥或写入后校验失败"; return 1; }
}
