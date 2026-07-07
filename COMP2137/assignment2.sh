#!/bin/bash
#
# assignment2.sh - COMP2137 Assignment 2
# Idempotent server configuration script for server1
#
# Configures:
#   - Static IP 192.168.16.21/24 via netplan on the interface with default route
#   - /etc/hosts entry for server1
#   - apache2 and squid installed + running
#   - 11 user accounts with home dirs, bash shell, rsa+ed25519 keys
#   - dennis gets sudo + extra authorized_keys entry
#
# Safe to re-run any number of times.

set -u  # error on unset variables; we handle command failures manually, not with set -e

TARGET_IP="192.168.16.21"
TARGET_CIDR="24"
TARGET_HOSTNAME="server1"
DENNIS_EXTRA_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI student@generic-vm"

USERS=(dennis aubrey captain snibbles brownie scooter sandy perrier cindy tiger yoda)

CHANGES_MADE=0

# ---------- helpers ----------

log_section() {
    echo ""
    echo "=================================================="
    echo " $1"
    echo "=================================================="
}

log_ok() {
    echo "  [OK]      $1"
}

log_changed() {
    echo "  [CHANGED] $1"
    CHANGES_MADE=1
}

log_error() {
    echo "  [ERROR]   $1" >&2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root (use sudo). Exiting." >&2
        exit 1
    fi
}

# ---------- 1. network configuration ----------

configure_network() {
    log_section "Network Configuration"

    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)

    if [ -z "$iface" ]; then
        log_error "Could not detect default route interface. Skipping network config."
        return
    fi
    log_ok "Detected target interface via default route: $iface"

    local netplan_file=""
    for f in /etc/netplan/*.yaml; do
        [ -e "$f" ] || continue
        if grep -q "$iface" "$f" 2>/dev/null; then
            netplan_file="$f"
            break
        fi
    done
    if [ -z "$netplan_file" ]; then
        netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    fi
    if [ -z "$netplan_file" ]; then
        log_error "No netplan file found in /etc/netplan/. Cannot configure network."
        return
    fi
    log_ok "Using netplan file: $netplan_file"

    local current_ip
    current_ip=$(ip -4 addr show "$iface" | grep -oP 'inet \K[0-9.]+' | head -n1)

    if [ "$current_ip" == "$TARGET_IP" ]; then
        log_ok "Interface $iface already has IP $TARGET_IP - no change needed"
    else
        log_changed "Interface $iface has IP '$current_ip' - updating to $TARGET_IP/$TARGET_CIDR"

        cp "$netplan_file" "${netplan_file}.bak.$(date +%s)"

        python3 - "$netplan_file" "$iface" "$TARGET_IP" "$TARGET_CIDR" <<'PYEOF'
import sys, yaml

path, iface, ip, cidr = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(path) as f:
    data = yaml.safe_load(f) or {}

data.setdefault("network", {})
data["network"].setdefault("version", 2)
data["network"].setdefault("ethernets", {})

eth_conf = data["network"]["ethernets"].get(iface, {})
eth_conf["addresses"] = [f"{ip}/{cidr}"]
eth_conf.pop("dhcp4", None)
data["network"]["ethernets"][iface] = eth_conf

with open(path, "w") as f:
    yaml.dump(data, f, default_flow_style=False)
PYEOF

        if [ $? -eq 0 ]; then
            chmod 600 "$netplan_file"
            netplan apply
            if [ $? -eq 0 ]; then
                log_ok "netplan applied successfully"
            else
                log_error "netplan apply failed - check $netplan_file manually"
            fi
        else
            log_error "Failed to rewrite netplan file via python3/yaml"
        fi
    fi
}

# ---------- 2. /etc/hosts ----------

configure_hosts() {
    log_section "/etc/hosts Configuration"

    local hosts_file="/etc/hosts"
    local correct_line="$TARGET_IP $TARGET_HOSTNAME"

    if grep -qE "^[0-9.]+[[:space:]]+$TARGET_HOSTNAME([[:space:]]|$)" "$hosts_file"; then
        local existing_line
        existing_line=$(grep -E "^[0-9.]+[[:space:]]+$TARGET_HOSTNAME([[:space:]]|$)" "$hosts_file")
        if [ "$existing_line" == "$correct_line" ]; then
            log_ok "/etc/hosts already has correct entry: $correct_line"
            return
        fi
    fi

    log_changed "Fixing /etc/hosts entry for $TARGET_HOSTNAME"
    cp "$hosts_file" "${hosts_file}.bak.$(date +%s)"
    sed -i "/[[:space:]]$TARGET_HOSTNAME\([[:space:]]\|$\)/d" "$hosts_file"
    echo "$correct_line" >> "$hosts_file"
    log_ok "Added: $correct_line"
}

# ---------- 3. software packages ----------

install_package() {
    local pkg="$1"
    local svc="$2"

    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log_ok "$pkg already installed"
    else
        log_changed "Installing $pkg"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_ok "$pkg installed successfully"
        else
            log_error "Failed to install $pkg"
            return
        fi
    fi

    if systemctl is-active --quiet "$svc"; then
        log_ok "$svc service is running"
    else
        log_changed "Starting $svc service"
        systemctl enable "$svc" >/dev/null 2>&1
        systemctl start "$svc"
        if systemctl is-active --quiet "$svc"; then
            log_ok "$svc started successfully"
        else
            log_error "$svc failed to start - check 'systemctl status $svc'"
        fi
    fi
}

configure_software() {
    log_section "Software Installation"
    install_package apache2 apache2
    install_package squid squid
}

# ---------- 4. user accounts ----------

configure_user() {
    local user="$1"
    local home_dir="/home/$user"

    if id "$user" &>/dev/null; then
        log_ok "User $user already exists"
    else
        useradd -m -d "$home_dir" -s /bin/bash "$user"
        if [ $? -eq 0 ]; then
            log_changed "Created user $user"
        else
            log_error "Failed to create user $user"
            return
        fi
    fi

    local current_shell
    current_shell=$(getent passwd "$user" | cut -d: -f7)
    if [ "$current_shell" != "/bin/bash" ]; then
        chsh -s /bin/bash "$user"
        log_changed "Set shell to /bin/bash for $user"
    fi

    if [ ! -d "$home_dir" ]; then
        mkdir -p "$home_dir"
        chown "$user:$user" "$home_dir"
        log_changed "Created missing home directory for $user"
    fi

    local ssh_dir="$home_dir/.ssh"
    mkdir -p "$ssh_dir"

    if [ ! -f "$ssh_dir/id_rsa" ]; then
        sudo -u "$user" ssh-keygen -t rsa -b 4096 -f "$ssh_dir/id_rsa" -N "" -q
        log_changed "Generated RSA key for $user"
    else
        log_ok "RSA key already exists for $user"
    fi

    if [ ! -f "$ssh_dir/id_ed25519" ]; then
        sudo -u "$user" ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -q
        log_changed "Generated ed25519 key for $user"
    else
        log_ok "ed25519 key already exists for $user"
    fi

    touch "$ssh_dir/authorized_keys"

    for keyfile in "$ssh_dir/id_rsa.pub" "$ssh_dir/id_ed25519.pub"; do
        if [ -f "$keyfile" ]; then
            local pubkey
            pubkey=$(cat "$keyfile")
            if ! grep -qF "$pubkey" "$ssh_dir/authorized_keys" 2>/dev/null; then
                echo "$pubkey" >> "$ssh_dir/authorized_keys"
                log_changed "Added $(basename "$keyfile") to $user's authorized_keys"
            else
                log_ok "$(basename "$keyfile") already in $user's authorized_keys"
            fi
        fi
    done

    chown -R "$user:$user" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/id_rsa" "$ssh_dir/id_ed25519" 2>/dev/null
    chmod 644 "$ssh_dir/id_rsa.pub" "$ssh_dir/id_ed25519.pub" 2>/dev/null
}

configure_dennis_extras() {
    log_section "dennis - Special Configuration"

    if id -nG dennis 2>/dev/null | grep -qw sudo; then
        log_ok "dennis already in sudo group"
    else
        usermod -aG sudo dennis
        log_changed "Added dennis to sudo group"
    fi

    local ssh_dir="/home/dennis/.ssh"
    mkdir -p "$ssh_dir"
    touch "$ssh_dir/authorized_keys"

    if ! grep -qF "$DENNIS_EXTRA_KEY" "$ssh_dir/authorized_keys" 2>/dev/null; then
        echo "$DENNIS_EXTRA_KEY" >> "$ssh_dir/authorized_keys"
        log_changed "Added specified public key to dennis's authorized_keys"
    else
        log_ok "Specified public key already present for dennis"
    fi

    chown -R dennis:dennis "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
}

configure_users() {
    log_section "User Accounts"
    for u in "${USERS[@]}"; do
        configure_user "$u"
    done
    configure_dennis_extras
}

# ---------- main ----------

main() {
    require_root

    echo "###################################################"
    echo "#  Assignment 2 - Server Configuration Script      #"
    echo "#  Target: $TARGET_HOSTNAME ($TARGET_IP)                     #"
    echo "###################################################"

    if ! python3 -c "import yaml" 2>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-yaml >/dev/null 2>&1
    fi

    configure_network
    configure_hosts
    configure_software
    configure_users

    log_section "Summary"
    if [ "$CHANGES_MADE" -eq 1 ]; then
        echo "  Configuration changes were applied. System now matches target state."
    else
        echo "  No changes were necessary. System already matched target state."
    fi
    echo ""
}

main
