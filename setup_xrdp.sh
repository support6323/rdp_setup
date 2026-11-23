#!/bin/sh
# POSIX-compliant interactive multi-user xRDP + XFCE + Falkon setup for headless Ubuntu 22.04/24.04
# Features: Non-sudo RDP users restricted to SSH port-forwarding tunnels only, trusted Falkon desktop shortcut & default browser, Fail2Ban, Swap, and manage-rdp-user helper.
set -eu

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Please run this script as root (sudo sh $0)" >&2
    exit 1
fi

echo "=========================================================="
echo " Headless Ubuntu VPS -> Multi-User xRDP + XFCE + Falkon"
echo "=========================================================="

# --- Interactive Prompts ---
printf "Enter Swap size to create if none exists [default: 4G]: "
read -r SWAP_SIZE
[ -z "$SWAP_SIZE" ] && SWAP_SIZE="4G"

while :; do
    printf "How many RDP users do you want to create now? [1-10]: "
    read -r USER_COUNT
    case "$USER_COUNT" in
        ''|*[!0-9]*)
            echo "Please enter a valid number."
            ;;
        *)
            if [ "$USER_COUNT" -ge 1 ] && [ "$USER_COUNT" -le 10 ]; then
                break
            else
                echo "Please enter a number between 1 and 10."
            fi
            ;;
    esac
done

# Collect usernames and passwords upfront before package installation
USER_CREDENTIALS=""
i=1
while [ "$i" -le "$USER_COUNT" ]; do
    echo ""
    echo "--- Configure User $i of $USER_COUNT ---"
    while :; do
        printf "Enter username for user %s: " "$i"
        read -r USERNAME
        if [ -z "$USERNAME" ]; then
            echo "Username cannot be empty."
        elif echo "$USERNAME" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
            break
        else
            echo "Invalid username. Use lowercase letters, numbers, underscores, or hyphens."
        fi
    done

    while :; do
        printf "Enter password for %s: " "$USERNAME"
        stty -echo
        read -r PASSWORD
        stty echo
        printf "\n"
        if [ -z "$PASSWORD" ]; then
            echo "Password cannot be empty."
            continue
        fi
        printf "Confirm password for %s: " "$USERNAME"
        stty -echo
        read -r PASSWORD_CONFIRM
        stty echo
        printf "\n"
        if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
            break
        else
            echo "Passwords do not match. Try again."
        fi
    done

    USER_CREDENTIALS="${USER_CREDENTIALS}${USERNAME}:${PASSWORD}
"
    i=$((i + 1))
done

echo ""
echo "=== 1. Updating System & Installing Packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update -y
apt-get install -y xfce4 xfce4-goodies dbus-x11 libglib2.0-bin xdg-utils xrdp falkon xclip fail2ban ufw

echo "=== 2. Configuring ${SWAP_SIZE} Swap File ==="
if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap (${SWAP_SIZE}) enabled."
else
    echo "Swapfile already exists, skipping."
fi

echo "=== 3. Configuring xRDP Performance, Security & Session Cleanup ==="
adduser xrdp ssl-cert

# Configure startwm.sh for XFCE
cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
cat << 'EOF' > /etc/xrdp/startwm.sh
#!/bin/sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi

unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

# Backup xrdp.ini and apply lag-reduction + localhost-only security bindings
cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
sed -i 's|^port=3389|port=tcp://127.0.0.1:3389|' /etc/xrdp/xrdp.ini
sed -i 's|^max_bpp=.*|max_bpp=16|' /etc/xrdp/xrdp.ini
sed -i 's|^use_compression=.*|use_compression=yes|' /etc/xrdp/xrdp.ini
sed -i 's|^crypt_level=.*|crypt_level=low|' /etc/xrdp/xrdp.ini

grep -q '^tcp_nodelay=' /etc/xrdp/xrdp.ini || sed -i '/^\[Globals\]/a tcp_nodelay=true' /etc/xrdp/xrdp.ini
grep -q '^tcp_keepalive=' /etc/xrdp/xrdp.ini || sed -i '/^\[Globals\]/a tcp_keepalive=true' /etc/xrdp/xrdp.ini

# Automatically kill disconnected/abandoned sessions after 2 hours (7200s) to free RAM
cp /etc/xrdp/sesman.ini /etc/xrdp/sesman.ini.bak
sed -i 's|^KillDisconnected=.*|KillDisconnected=true|' /etc/xrdp/sesman.ini
sed -i 's|^DisconnectedTimeLimit=.*|DisconnectedTimeLimit=7200|' /etc/xrdp/sesman.ini

# Allow color-manager actions without repeated Polkit password popups
mkdir -p /etc/polkit-1/rules.d
cat << 'EOF' > /etc/polkit-1/rules.d/45-allow-colord.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
EOF

# Set Falkon as system-wide default browser alternative
if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/bin/falkon ]; then
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/falkon 200
    update-alternatives --set x-www-browser /usr/bin/falkon
fi

echo "=== 4. Configuring SSH Tunnel-Only Group & Restricted Shell ==="
# Create dedicated group for RDP users restricted to SSH port-forwarding tunnels
groupadd -f rdp-tunnel

# Create a POSIX tunnel-only login shell that blocks interactive SSH shell commands
# while keeping SSH TCP port forwarding (-L 3390:127.0.0.1:3389 -N) fully functional
cat << 'EOF' > /usr/local/bin/rdp-tunnel-shell
#!/bin/sh
echo "Interactive SSH shell access is disabled for this account."
echo "Use SSH port forwarding only: ssh -L 3390:127.0.0.1:3389 -N <user>@<server-ip>"
exit 1
EOF
chmod 755 /usr/local/bin/rdp-tunnel-shell
grep -qxF '/usr/local/bin/rdp-tunnel-shell' /etc/shells || echo '/usr/local/bin/rdp-tunnel-shell' >> /etc/shells

# Add modular drop-in Match Group rule without modifying main /etc/ssh/sshd_config settings
mkdir -p /etc/ssh/sshd_config.d
cat << 'EOF' > /etc/ssh/sshd_config.d/90-rdp-tunnel-only.conf
Match Group rdp-tunnel
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:3389
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /usr/local/bin/rdp-tunnel-shell
EOF

sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo "=== 5. Installing /usr/local/bin/manage-rdp-user Helper Script ==="
cat << 'EOF' > /usr/local/bin/manage-rdp-user
#!/bin/sh
# POSIX helper script to add, remove, or list non-sudo, tunnel-only xRDP users
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Run as root (sudo manage-rdp-user ...)" >&2
    exit 1
fi

usage() {
    echo "Usage:"
    echo "  manage-rdp-user add <username> [password]   Create/configure a non-sudo, SSH-tunnel-only RDP user"
    echo "  manage-rdp-user remove <username>           Kill sessions and delete an RDP user"
    echo "  manage-rdp-user list                        List all configured RDP users"
    exit 1
}

configure_user_desktop() {
    TARGET_USER="$1"
    USER_HOME="/home/${TARGET_USER}"

    mkdir -p "${USER_HOME}/Desktop" \
             "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml" \
             "${USER_HOME}/.config/xfce4" \
             "${USER_HOME}/.config"

    echo "xfce4-session" > "${USER_HOME}/.xsession"

    # Disable XFCE compositing to eliminate window drag lag
    cat << 'XML' > "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XML

    # Set Falkon as default XFCE Preferred Web Browser
    cat << 'HELPERS' > "${USER_HOME}/.config/xfce4/helpers.rc"
WebBrowser=falkon
HELPERS

    # Set Falkon as XDG default MIME handler for http/https/html
    cat << 'MIME' > "${USER_HOME}/.config/mimeapps.list"
[Default Applications]
x-scheme-handler/http=org.kde.falkon.desktop
x-scheme-handler/https=org.kde.falkon.desktop
text/html=org.kde.falkon.desktop
application/xhtml+xml=org.kde.falkon.desktop
MIME

    # Create Falkon Desktop shortcut
    cat << 'DESKTOP' > "${USER_HOME}/Desktop/Falkon.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Falkon
Comment=Lightweight KDE Web Browser
Exec=falkon %u
Icon=falkon
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
DESKTOP
    chmod +x "${USER_HOME}/Desktop/Falkon.desktop"

    chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}"

    # Mark Desktop shortcut as trusted via GVFS metadata so XFCE never shows an untrusted popup
    su -s /bin/sh "$TARGET_USER" -c "dbus-run-session gio set '${USER_HOME}/Desktop/Falkon.desktop' metadata::trusted true" >/dev/null 2>&1 || true
    su -s /bin/sh "$TARGET_USER" -c "xdg-settings set default-web-browser org.kde.falkon.desktop" >/dev/null 2>&1 || true
}

ACTION="${1:-}"
TARGET_USER="${2:-}"
PASS_ARG="${3:-}"

case "$ACTION" in
    add)
        [ -z "$TARGET_USER" ] && usage
        if ! echo "$TARGET_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
            echo "Error: Invalid username format." >&2
            exit 1
        fi

        if [ -z "$PASS_ARG" ]; then
            while :; do
                printf "Enter password for %s: " "$TARGET_USER"
                stty -echo
                read -r PASS_ARG
                stty echo
                printf "\n"
                [ -z "$PASS_ARG" ] && echo "Password cannot be empty." && continue
                printf "Confirm password for %s: " "$TARGET_USER"
                stty -echo
                read -r PASS_CONFIRM
                stty echo
                printf "\n"
                [ "$PASS_ARG" = "$PASS_CONFIRM" ] && break
                echo "Passwords do not match. Try again."
            done
        fi

        if ! id "$TARGET_USER" >/dev/null 2>&1; then
            adduser --disabled-password --gecos "" --shell /usr/local/bin/rdp-tunnel-shell "$TARGET_USER"
            echo "Created non-sudo, tunnel-only user: $TARGET_USER"
        else
            usermod --shell /usr/local/bin/rdp-tunnel-shell "$TARGET_USER"
            echo "User $TARGET_USER already exists; updated password, tunnel restriction, and desktop config."
        fi

        echo "${TARGET_USER}:${PASS_ARG}" | chpasswd
        deluser "$TARGET_USER" sudo >/dev/null 2>&1 || true
        usermod -aG rdp-tunnel "$TARGET_USER"
        configure_user_desktop "$TARGET_USER"
        echo "User '$TARGET_USER' is ready (non-sudo, SSH tunnel-only, trusted Falkon shortcut & default browser)."
        ;;

    remove)
        [ -z "$TARGET_USER" ] && usage
        if [ "$TARGET_USER" = "root" ]; then
            echo "Error: Refusing to remove root." >&2
            exit 1
        fi
        if ! id "$TARGET_USER" >/dev/null 2>&1; then
            echo "Error: User '$TARGET_USER' does not exist." >&2
            exit 1
        fi

        pkill -KILL -u "$TARGET_USER" >/dev/null 2>&1 || true
        sleep 1
        deluser --remove-home "$TARGET_USER"
        echo "User '$TARGET_USER' and their home directory have been removed."
        ;;

    list)
        echo "Configured RDP Users (rdp-tunnel group):"
        awk -F: '$1 == "rdp-tunnel" { print $4 }' /etc/group | tr ',' '\n' | while read -r u; do
            [ -n "$u" ] && echo " - $u (Home: /home/$u)"
        done
        ;;

    *)
        usage
        ;;
esac
EOF
chmod +x /usr/local/bin/manage-rdp-user

echo "=== 6. Creating Initial Non-Sudo Tunnel-Only RDP Users ==="
printf "%s" "$USER_CREDENTIALS" | while IFS=: read -r username password; do
    [ -z "$username" ] && continue
    /usr/local/bin/manage-rdp-user add "$username" "$password"
done

echo "=== 7. Enabling Firewall & Fail2Ban ==="
ufw allow 22/tcp
ufw delete allow 3389/tcp >/dev/null 2>&1 || true
ufw --force enable

cat << 'EOF' > /etc/fail2ban/jail.d/sshd-local.conf
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 4
bantime = 3600
findtime = 600
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
systemctl enable xrdp
systemctl restart xrdp

echo ""
echo "=========================================================="
echo " Setup Complete!"
echo "=========================================================="
echo "Users Created    : ${USER_COUNT} non-sudo, SSH-tunnel-only RDP user(s)"
echo "Browser          : Falkon (Default browser + trusted Desktop icon)"
echo "User Manager     : sudo manage-rdp-user [add|remove|list] <username>"
echo "xRDP Binding     : 127.0.0.1:3389 (Public port 3389 blocked)"
echo "Fail2Ban Status  : Active (Protecting SSH)"
echo ""
echo "How to Connect from a Client PC:"
echo "  1. Open SSH tunnel: ssh -L 3390:127.0.0.1:3389 -N <username>@YOUR_SERVER_IP"
echo "  2. Connect RDP client to: 127.0.0.1:3390"
echo "=========================================================="
