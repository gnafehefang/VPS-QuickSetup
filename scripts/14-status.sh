#!/usr/bin/env bash
# 由 setup.sh 统一加载, 保持各步骤共享本轮状态。

# ---------- 当前状态 ----------
summary_login_user() { # 仅为简单、可核对的密钥认证策略生成示例, 不猜测复杂准入规则。
  local dump="$1" allow candidate entry found uid home sh key
  [[ -n "$dump" && "$(sshd_dump_val "$dump" pubkeyauthentication)" == yes ]] || return 1
  sshd_policy_layout_supported >/dev/null 2>&1 || return 1
  for key in denyusers allowgroups denygroups; do
    [[ -z "$(sshd_dump_val "$dump" "$key")" ]] || return 1
  done
  case "$(sshd_dump_val "$dump" authenticationmethods)" in ''|any|publickey) ;; *) return 1 ;; esac
  allow=$(sshd_dump_val "$dump" allowusers)
  [[ -z "$allow" || "$allow" =~ ^[a-zA-Z0-9_\ -]+$ ]] || return 1
  for candidate in "${ADMIN_USER:-}" "$DEFAULT_ADMIN" "${SUDO_USER:-}" $(sudo_users_with_keys) $(login_users_with_keys); do
    [[ "$candidate" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || continue
    [[ -z "$allow" || " $allow " == *" $candidate "* ]] || continue
    entry=$(getent passwd "$candidate") || continue
    IFS=: read -r found _ uid _ _ home sh <<<"$entry"
    [[ "$found" == "$candidate" && "$uid" =~ ^[0-9]+$ && "$home" == /* && "$home" != / \
        && -n "$sh" && "$sh" != */nologin && "$sh" != */false ]] || continue
    if [[ "$uid" == 0 ]]; then
      [[ "$candidate" == root ]] || continue
      case "$(sshd_dump_val "$dump" permitrootlogin)" in yes|prohibit-password|without-password) ;; *) continue ;; esac
    fi
    has_keys "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
summary_accounts() {
  local accounts displayed="" entry u uid home sh file key_dump prints fingerprints fingerprint issues count uncertain=no
  accounts=$(getent passwd) && [[ -n "$accounts" ]] || { warn "账号清单读取失败, 不能判断是否存在其他账号"; return 1; }
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    IFS=: read -r u _ uid _ _ home sh <<<"$entry"
    case "${sh##*/}" in
      nologin|false|sync|true)
        if [[ ! "$uid" =~ ^0+$ ]]; then
          [[ "$home" == /* && "$home" != / ]] || continue
          [[ -s "$home/.ssh/authorized_keys" || -L "$home/.ssh/authorized_keys" \
            || -s "$home/.ssh/authorized_keys2" || -L "$home/.ssh/authorized_keys2" ]] || continue
        fi ;;
    esac
    displayed+="$entry"$'\n'
  done <<<"$accounts"
  displayed=${displayed%$'\n'}
  printf '登录及带公钥账号: %s\n' "$(awk 'NF{n++} END{print n+0}' <<<"$displayed")"
  [[ -n "$displayed" ]] || return 0
  while IFS=: read -r u _ uid _ _ home _; do
    fingerprints=""; issues=no
    if [[ "$home" != /* || "$home" == / || -L "$home" || -L "$home/.ssh" ]]; then
      issues=yes
    else
      for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
          issues=yes; continue
        fi
        [[ -s "$file" ]] || continue
        if ! key_dump=$(ssh-keygen -l -E sha256 -f "$file" 2>/dev/null); then
          issues=yes; continue
        fi
        prints=$(awk '$1~/^[0-9]+$/ && $2~/^SHA256:[A-Za-z0-9+\/=]+$/ && $NF~/^\([A-Za-z0-9_-]+\)$/ {print $2}' <<<"$key_dump")
        if [[ -z "$prints" ]]; then
          issues=yes; continue
        fi
        fingerprints+="$prints"$'\n'
      done
    fi
    fingerprints=$(sort -u <<<"$fingerprints" | awk 'NF')
    count=$(awk 'NF{n++} END{print n+0}' <<<"$fingerprints")
    if [[ "$issues" == yes ]]; then count+='+?'; uncertain=yes; fi
    printf '%s: %s 把密钥\n' "$u" "$count"
    if [[ -n "$fingerprints" ]]; then
      while IFS= read -r fingerprint; do
        fingerprint=${fingerprint#SHA256:}
        if (( ${#fingerprint} > 12 )); then
          printf '    SHA256:%s********%s\n' "${fingerprint:0:6}" "${fingerprint: -6}"
        else
          printf '    SHA256:********\n'
        fi
      done <<<"$fingerprints"
    fi
    if [[ "$uid" =~ ^0+$ && "$u" != root ]]; then err "$u 也是 UID 0 账号, 必须人工核查"; fi
  done <<<"$displayed"
  [[ "$uncertain" == no ]] || warn "+? 表示部分密钥来源未能读取或校验, 数量可能不完整"
  return 0
}
summary_title() {
  printf '\n\n%s################################################################\n                           当前状态\n################################################################%s\n' "$c_title" "$c_off"
}
summary_section() { printf '\n[%s]\n' "$1"; }
summary_indent() { sed '/./s/^/    /'; }
summary_note() {
  printf '\n[说明] %s\n' "$1"
  shift
  while (( $# )); do printf '       %s\n' "$1"; shift; done
}
summary_status() { # summary_status label actual expected
  local value="${2:-未知 (读取失败)}" color="$c_red"
  [[ -n "${2:-}" && "$2" == "$3" ]] && color="$c_grn"
  printf '%s: %s%s%s\n' "$1" "$color" "$value" "$c_off"
}
summary() {
  local port user ip dump="" ports allow allow_color="$c_red" ufw_dump f2b_dump
  if ! { mkdir -p "$SSHD_RUN_DIR" && dump=$(sshd -T); } 2>/dev/null; then
    dump=""
  fi
  ports=$(sshd_dump_val "$dump" port)
  read -r port _ <<<"$ports"
  user=$(summary_login_user "$dump") || user=""
  allow=$(sshd_dump_val "$dump" allowusers)
  if [[ -n "$allow" && -n "$user" && "$user" != root && "$allow" == "$user" ]]; then allow_color="$c_grn"; fi
  if [[ -z "$dump" ]]; then allow="未知 (读取失败)"
  elif [[ -z "$allow" ]]; then allow="未设置 (没有用户名白名单, 不代表仅允许 admin)"; fi
  ip=$(public_ip)
  summary_title
  summary_section "基础信息"
  {
    echo "主机名         : $(hostname)"
    echo "时区           : $(timedatectl show -p Timezone --value 2>/dev/null)"
    summary_status "自动校时已启用 " "$(ntp_value NTP)" yes
    summary_status "系统时钟已同步 " "$(ntp_value NTPSynchronized)" yes
    echo "swap           : $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | paste -sd' ' -)"
    echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
  } 2>&1 | summary_indent
  summary_section "SSH 全局策略"
  {
    [[ -n "$dump" ]] || warn "无法读取 SSH 有效配置, 不生成登录示例"
    echo "SSH 端口       : ${ports:-未知}"
    summary_status "root 登录      " "$(sshd_dump_val "$dump" permitrootlogin)" no
    summary_status "密码登录       " "$(sshd_dump_val "$dump" passwordauthentication)" no
    summary_status "密钥登录       " "$(sshd_dump_val "$dump" pubkeyauthentication)" yes
    summary_status "键盘交互认证   " "$(sshd_dump_val "$dump" kbdinteractiveauthentication)" no
    printf 'AllowUsers     : %s%s%s\n' "$allow_color" "$allow" "$c_off"
    summary_note "以上为全局有效配置, Match 等规则可能按用户或来源另行限制;" \
      "启用密钥认证不代表已验证登录。"
  } 2>&1 | summary_indent
  summary_section "账号与公钥"
  summary_accounts 2>&1 | summary_indent || true
  summary_section "TCP / UDP 监听"
  {
    if command -v ss >/dev/null; then ss -lntup || warn "读取监听端口失败"
    else warn "ss 未安装, 无法显示实际监听"; fi
    summary_note "以上包含回环和系统服务监听, 不是公网可达性测试。"
  } 2>&1 | summary_indent
  summary_section "UFW 防火墙"
  {
    if command -v ufw >/dev/null; then
      if ufw_dump=$(LC_ALL=C ufw status numbered); then
        case "$ufw_dump" in
          *'Status: active'*) summary_status "UFW 已启用     " yes yes ;;
          *'Status: inactive'*) summary_status "UFW 已启用     " no yes ;;
          *) summary_status "UFW 已启用     " "" yes ;;
        esac
        printf '%s\n' "$ufw_dump"
      else summary_status "UFW 已启用     " "" yes; warn "无法读取 UFW 规则"; fi
    else summary_status "UFW 已启用     " no yes; echo "未安装"; fi
    summary_note "保留既有规则, 不自动清空; 放行端口不等于有进程监听。" \
      "UFW 也不代表云防火墙或全部 netfilter 规则。"
  } 2>&1 | summary_indent
  summary_section "fail2ban"
  {
    if command -v fail2ban-client >/dev/null; then
      if f2b_dump=$(fail2ban-client status sshd 2>/dev/null); then
        summary_status "sshd jail 就绪 " yes yes
        printf '%s\n' "$f2b_dump"
      else summary_status "sshd jail 就绪 " "" yes; echo "查询失败或 sshd jail 未运行"; fi
    else summary_status "sshd jail 就绪 " no yes; echo "未安装"; fi
  } 2>&1 | summary_indent
  summary_section "本机 ~/.ssh/config 可添加"
  {
    if [[ -n "$user" && -n "$port" ]]; then
      cat <<EOT
Host $(hostname)
    HostName $ip
    Port $port
    User $user
    IdentityFile ~/.ssh/id_ed25519
EOT
    else
      warn "未确认可用的密钥登录用户或端口, 不猜测 User root; 请核对账户、公钥及 SSH 准入规则"
    fi
  } 2>&1 | summary_indent
  if [[ -d "$BACKUP_DIR" ]]; then
    summary_section "配置备份"
    printf '%s\n' "$BACKUP_DIR" | summary_indent
  fi
  return 0
}
