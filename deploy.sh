#!/usr/bin/env bash
set -euo pipefail

RDP_USER="${RDP_USER:-}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
RDP_PORT="${RDP_PORT:-3389}"
INSTALL_JAVA="${INSTALL_JAVA:-true}"
INSTALL_CHROME="${INSTALL_CHROME:-true}"
INSTALL_UFW="${INSTALL_UFW:-}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-}"
XFCE_EXTRAS="${XFCE_EXTRAS:-false}"
DISABLE_DISPLAY_MANAGER="${DISABLE_DISPLAY_MANAGER:-true}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
deploy.sh - XFCE + xrdp + Temurin JDK 11 + Google Chrome

Usage:
  sudo ./deploy.sh

The script asks for the RDP user, the password and whether to install ufw
and fail2ban before anything else. Presetting a variable skips the matching
question.

Environment variables:
  RDP_USER=<name>                User for the RDP session
  RDP_PASSWORD=<password>        Set the password non-interactively
  RDP_PORT=3389                  Listening port for xrdp
  INSTALL_JAVA=true|false        Install Temurin JDK 11
  INSTALL_CHROME=true|false      Install Google Chrome
  INSTALL_UFW=true|false         Install and enable the ufw firewall
  INSTALL_FAIL2BAN=true|false    Install and configure fail2ban
  XFCE_EXTRAS=true|false         Also install xfce4-goodies
  DISABLE_DISPLAY_MANAGER=true|false
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; die "Unknown argument: $1" ;;
esac

trap 'printf "\033[1;31m[x]\033[0m Aborted at line %s\n" "$LINENO" >&2' ERR

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|y|1) return 0 ;;
    *) return 1 ;;
  esac
}

has_tty() { : >/dev/tty 2>/dev/null; }

ask_value() {
  local prompt="$1" default="$2" reply=""
  printf '\033[1;36m[?]\033[0m %s [%s]: ' "$prompt" "$default" >/dev/tty
  read -r reply </dev/tty || reply=""
  [ -n "$reply" ] || reply="$default"
  printf '%s' "$reply"
}

ask_yes_no() {
  local prompt="$1" default="$2" hint="[Y/n]" reply=""
  [ "$default" = "n" ] && hint="[y/N]"
  while true; do
    printf '\033[1;36m[?]\033[0m %s %s ' "$prompt" "$hint" >/dev/tty
    read -r reply </dev/tty || reply=""
    reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
    [ -n "$reply" ] || reply="$default"
    case "$reply" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

echo_off() { stty -echo </dev/tty 2>/dev/null || true; }
echo_on()  { stty echo </dev/tty 2>/dev/null || true; }

ask_password() {
  local p1="" p2=""
  trap 'echo_on' EXIT
  while true; do
    echo_off
    printf '\033[1;36m[?]\033[0m Password for "%s": ' "$RDP_USER" >/dev/tty
    read -rs p1 </dev/tty || p1=""
    echo_on
    printf '\n' >/dev/tty
    echo_off
    printf '\033[1;36m[?]\033[0m Repeat password: ' >/dev/tty
    read -rs p2 </dev/tty || p2=""
    echo_on
    printf '\n' >/dev/tty
    if [ "${#p1}" -lt 8 ]; then
      warn "At least 8 characters required."
      continue
    fi
    if [ "$p1" != "$p2" ]; then
      warn "Passwords do not match."
      continue
    fi
    RDP_PASSWORD="$p1"
    return 0
  done
}

valid_username() {
  printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./deploy.sh"
}

detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release is not readable."
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-${DEBIAN_CODENAME:-}}}"
  case " $OS_ID $OS_LIKE " in
    *ubuntu*|*debian*) ;;
    *) die "Unsupported system: $OS_NAME. Ubuntu or Debian required." ;;
  esac
  ARCH="$(dpkg --print-architecture)"
}

pkg_exists() { apt-cache show "$1" >/dev/null 2>&1; }

apt_install_first() {
  local p
  for p in "$@"; do
    if pkg_exists "$p"; then
      apt-get install "${APT_OPTS[@]}" "$p"
      return 0
    fi
  done
  return 1
}

default_username() {
  local u=""
  u="$(awk -F: '$3>=1000 && $3<65000 && $1!="nobody" {print $1; exit}' /etc/passwd || true)"
  [ -n "$u" ] || u="osrs"
  printf '%s' "$u"
}

configure_interactive() {
  local suggested pw_state=""
  suggested="${SUDO_USER:-}"
  [ -n "$suggested" ] && [ "$suggested" != "root" ] || suggested="$(default_username)"

  if ! has_tty; then
    [ -n "$RDP_USER" ] || RDP_USER="$suggested"
    [ -n "$INSTALL_UFW" ] || INSTALL_UFW="true"
    [ -n "$INSTALL_FAIL2BAN" ] || INSTALL_FAIL2BAN="true"
    warn "No interactive terminal, falling back to defaults (user: $RDP_USER)"
    return 0
  fi

  printf '\n'
  log "Configuration"

  while [ -z "$RDP_USER" ]; do
    RDP_USER="$(ask_value 'Username for the RDP session' "$suggested")"
    if [ "$RDP_USER" = "root" ]; then
      warn "root is not allowed as the RDP user."
      RDP_USER=""
    elif ! valid_username "$RDP_USER"; then
      warn "Invalid name. Allowed: a-z, 0-9, underscore and dash, must start with a letter."
      RDP_USER=""
    fi
  done

  if id "$RDP_USER" >/dev/null 2>&1; then
    pw_state="$(passwd -S "$RDP_USER" 2>/dev/null | awk '{print $2}' || true)"
  else
    log "User '$RDP_USER' does not exist yet and will be created."
  fi

  if [ -z "$RDP_PASSWORD" ]; then
    if [ "$pw_state" = "P" ]; then
      if ask_yes_no "User '$RDP_USER' already has a password. Replace it?" "n"; then
        ask_password
      fi
    else
      ask_password
    fi
  fi

  if [ -z "$INSTALL_UFW" ] || [ -z "$INSTALL_FAIL2BAN" ]; then
    if ask_yes_no "Install firewall (ufw) and brute force protection (fail2ban)?" "y"; then
      [ -n "$INSTALL_UFW" ] || INSTALL_UFW="true"
      [ -n "$INSTALL_FAIL2BAN" ] || INSTALL_FAIL2BAN="true"
    else
      [ -n "$INSTALL_UFW" ] || INSTALL_UFW="false"
      [ -n "$INSTALL_FAIL2BAN" ] || INSTALL_FAIL2BAN="false"
    fi
  fi

  printf '\n'
  log "User: $RDP_USER, port: $RDP_PORT, ufw: $INSTALL_UFW, fail2ban: $INSTALL_FAIL2BAN"
  printf '\n'
}

resolve_user() {
  [ -n "$RDP_USER" ] || RDP_USER="$(default_username)"
  [ "$RDP_USER" != "root" ] || die "root is not suitable as the RDP user."
  if ! id "$RDP_USER" >/dev/null 2>&1; then
    log "Creating user '$RDP_USER'"
    useradd -m -s /bin/bash "$RDP_USER"
    usermod -aG sudo "$RDP_USER" 2>/dev/null || true
  fi
  USER_HOME="$(getent passwd "$RDP_USER" | cut -d: -f6)"
  USER_GROUP="$(id -gn "$RDP_USER")"
  [ -d "$USER_HOME" ] || die "Home directory of $RDP_USER not found."
}

set_password() {
  local state
  if [ -n "$RDP_PASSWORD" ]; then
    printf '%s:%s\n' "$RDP_USER" "$RDP_PASSWORD" | chpasswd
    ok "Password for '$RDP_USER' has been set"
    return 0
  fi
  state="$(passwd -S "$RDP_USER" 2>/dev/null | awk '{print $2}' || true)"
  if [ "$state" = "P" ]; then
    log "Keeping the existing password of '$RDP_USER'"
    return 0
  fi
  warn "No password set for '$RDP_USER'. Set one with: sudo passwd $RDP_USER"
}

system_update() {
  log "System update"
  apt-get update
  apt-get "${APT_OPTS[@]}" full-upgrade
  ok "System updated"
}

install_base() {
  log "Base packages"
  apt-get install "${APT_OPTS[@]}" ca-certificates curl wget gnupg apt-transport-https locales sudo
  install -d -m 0755 /etc/apt/keyrings
}

install_desktop() {
  log "XFCE desktop"
  local pkgs=(xfce4 xfce4-terminal thunar dbus-x11 x11-xserver-utils xdg-utils fonts-dejavu-core xfce4-power-manager)
  if is_true "$XFCE_EXTRAS"; then
    pkgs+=(xfce4-goodies)
  fi
  apt-get install "${APT_OPTS[@]}" "${pkgs[@]}"
  apt_install_first polkitd policykit-1 || warn "polkit was not installed"
  ok "XFCE installed"
}

install_xrdp() {
  log "xrdp"
  apt-get install "${APT_OPTS[@]}" xrdp xorgxrdp
  usermod -aG ssl-cert xrdp 2>/dev/null || true

  if [ -f /etc/xrdp/startwm.sh ] && [ ! -f /etc/xrdp/startwm.sh.orig ]; then
    cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.orig
  fi

  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec /bin/sh /etc/X11/Xsession
EOF
  chmod 0755 /etc/xrdp/startwm.sh

  printf 'startxfce4\n' > "$USER_HOME/.xsession"
  chown "$RDP_USER":"$USER_GROUP" "$USER_HOME/.xsession"
  chmod 0644 "$USER_HOME/.xsession"

  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
  chmod 0644 /etc/X11/Xwrapper.config

  if [ -f /etc/xrdp/xrdp.ini ]; then
    sed -i "0,/^port=/s//port=${RDP_PORT}/" /etc/xrdp/xrdp.ini
  fi

  ok "xrdp configured (port ${RDP_PORT})"
}

configure_polkit() {
  log "Polkit rules"
  install -d -m 0755 /etc/polkit-1/localauthority/50-local.d
  cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow colord for all users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=yes
ResultInactive=yes
ResultActive=yes

[Allow package refresh for all users]
Identity=unix-user:*
Action=org.freedesktop.packagekit.system-sources-refresh;org.freedesktop.packagekit.system-network-proxy-configure
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
  chmod 0644 /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla

  install -d -m 0755 /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/49-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
        return polkit.Result.YES;
    }
    if (action.id == "org.freedesktop.packagekit.system-sources-refresh") {
        return polkit.Result.YES;
    }
});
EOF
  chmod 0644 /etc/polkit-1/rules.d/49-allow-colord.rules
}

configure_session_defaults() {
  log "Session defaults (no screensaver, no lock screen)"
  local xdir="$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
  install -d -m 0755 "$xdir"

  cat > "$xdir/xfce4-screensaver.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="mode" type="int" value="0"/>
    <property name="enabled" type="bool" value="false"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
</channel>
EOF

  cat > "$xdir/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="uint" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
EOF

  chown -R "$RDP_USER":"$USER_GROUP" "$USER_HOME/.config"
}

install_java() {
  log "Eclipse Temurin JDK 11"
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  chmod 0644 /etc/apt/keyrings/adoptium.gpg

  local dist="$OS_CODENAME"
  if [ -z "$dist" ] || ! curl -fsSL -o /dev/null "https://packages.adoptium.net/artifactory/deb/dists/${dist}/Release"; then
    case " $OS_ID $OS_LIKE " in
      *ubuntu*) dist="jammy" ;;
      *) dist="bookworm" ;;
    esac
    warn "No Adoptium repository for '${OS_CODENAME:-unknown}', falling back to '${dist}'"
  fi

  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb %s main\n' \
    "$ARCH" "$dist" > /etc/apt/sources.list.d/adoptium.list
  apt-get update
  apt-get install "${APT_OPTS[@]}" temurin-11-jdk

  local java_home
  java_home="$(find /usr/lib/jvm -maxdepth 1 -type d -name 'temurin-11-jdk*' 2>/dev/null | sort | head -n1)"
  if [ -n "$java_home" ]; then
    printf 'export JAVA_HOME=%s\nexport PATH="$JAVA_HOME/bin:$PATH"\n' "$java_home" > /etc/profile.d/temurin11.sh
    chmod 0644 /etc/profile.d/temurin11.sh
    update-alternatives --set java "$java_home/bin/java" >/dev/null 2>&1 || true
    update-alternatives --set javac "$java_home/bin/javac" >/dev/null 2>&1 || true
  fi
  ok "Java 11 installed"
}

install_chrome() {
  if [ "$ARCH" != "amd64" ]; then
    warn "Google Chrome is amd64 only (this system: $ARCH), installing Chromium instead"
    apt_install_first chromium chromium-browser || warn "No browser installed"
    return 0
  fi
  log "Google Chrome"
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  chmod 0644 /etc/apt/keyrings/google-chrome.gpg
  printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
    > /etc/apt/sources.list.d/google-chrome.list
  apt-get update
  apt-get install "${APT_OPTS[@]}" google-chrome-stable
  ok "Google Chrome installed"
}

detect_ssh_port() {
  local p=""
  p="$(grep -rhE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
    | awk '{print $2}' | head -n1 || true)"
  [ -n "$p" ] || p=22
  printf '%s' "$p"
}

install_fail2ban() {
  log "fail2ban"
  apt-get install "${APT_OPTS[@]}" fail2ban

  local ssh_backend="auto"
  if [ ! -f /var/log/auth.log ]; then
    apt_install_first python3-systemd || warn "python3-systemd is not available"
    ssh_backend="systemd"
  fi

  cat > /etc/fail2ban/filter.d/xrdp-auth.conf <<'EOF'
[Definition]
failregex = ^.*AUTHFAIL: user=\S* ip=<HOST>(:\d+)? time=.*$
            ^.*login failed for user \S+ from <HOST>.*$
ignoreregex =
EOF
  chmod 0644 /etc/fail2ban/filter.d/xrdp-auth.conf

  if [ ! -f /var/log/xrdp-sesman.log ]; then
    install -m 0600 /dev/null /var/log/xrdp-sesman.log
  fi

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $(detect_ssh_port)
backend = ${ssh_backend}

[xrdp-auth]
enabled = true
port = ${RDP_PORT}
filter = xrdp-auth
logpath = /var/log/xrdp-sesman.log
backend = auto
maxretry = 5
bantime = 1h
EOF
  chmod 0644 /etc/fail2ban/jail.local

  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban >/dev/null 2>&1; then
    ok "fail2ban active (sshd and xrdp)"
  else
    warn "fail2ban failed to start, check: systemctl status fail2ban"
  fi
}

install_security() {
  if is_true "$INSTALL_UFW"; then
    log "ufw"
    apt-get install "${APT_OPTS[@]}" ufw
  fi
  if is_true "$INSTALL_FAIL2BAN"; then
    install_fail2ban
  fi
}

configure_firewall() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${RDP_PORT}/tcp" >/dev/null 2>&1 || true
    if is_true "$INSTALL_UFW" && ! ufw status 2>/dev/null | grep -q 'Status: active'; then
      ufw --force enable >/dev/null 2>&1 || warn "ufw could not be enabled"
    fi
    ok "ufw: SSH (${ssh_port}/tcp) and RDP (${RDP_PORT}/tcp) allowed"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${RDP_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "firewalld: port ${RDP_PORT}/tcp allowed"
  fi
}

disable_display_manager() {
  is_true "$DISABLE_DISPLAY_MANAGER" || return 0
  log "Disabling the display manager (headless)"
  local dm
  for dm in lightdm gdm3 gdm sddm xdm; do
    systemctl disable "$dm" >/dev/null 2>&1 || true
    systemctl stop "$dm" >/dev/null 2>&1 || true
  done
  systemctl set-default multi-user.target >/dev/null 2>&1 || true
}

enable_services() {
  log "Enabling services"
  systemctl enable xrdp >/dev/null 2>&1 || true
  systemctl enable xrdp-sesman >/dev/null 2>&1 || true
  systemctl restart xrdp-sesman >/dev/null 2>&1 || true
  systemctl restart xrdp
  if systemctl is-active --quiet xrdp; then
    ok "xrdp is running and starts automatically"
  else
    warn "xrdp is not running, check: systemctl status xrdp"
  fi
}

summary() {
  local ips java_v chrome_v ufw_v f2b_v
  ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd', ' - || true)"
  java_v="$(java -version 2>&1 | head -n1 || true)"
  chrome_v="$(google-chrome-stable --version 2>/dev/null || chromium --version 2>/dev/null || echo 'not installed')"
  ufw_v="$(ufw status 2>/dev/null | head -n1 || echo 'not installed')"
  f2b_v="$(systemctl is-active fail2ban 2>/dev/null || echo 'not installed')"

  printf '\n'
  ok "Done"
  printf '    System        : %s\n' "$OS_NAME"
  printf '    RDP address   : %s:%s\n' "${ips:-<ip-of-the-vm>}" "$RDP_PORT"
  printf '    RDP user      : %s\n' "$RDP_USER"
  printf '    Desktop       : XFCE\n'
  printf '    Java          : %s\n' "${java_v:-not installed}"
  printf '    Browser       : %s\n' "$chrome_v"
  printf '    ufw           : %s\n' "$ufw_v"
  printf '    fail2ban      : %s\n' "$f2b_v"
  printf '\n'
  printf '    Connect with: Windows "Remote Desktop Connection", macOS "Windows App", Linux "Remmina"\n'
  printf '    Session type in the login screen: Xorg\n\n'
}

main() {
  require_root
  detect_os
  log "Detected: $OS_NAME ($ARCH)"
  configure_interactive
  resolve_user
  set_password
  system_update
  install_base
  install_desktop
  install_xrdp
  configure_polkit
  configure_session_defaults
  if is_true "$INSTALL_JAVA"; then install_java; fi
  if is_true "$INSTALL_CHROME"; then install_chrome; fi
  install_security
  configure_firewall
  disable_display_manager
  enable_services
  summary
}

main "$@"
