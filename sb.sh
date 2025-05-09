#!/bin/bash

#=========================================================================================
# Project: sing-box Multi-User Management Script with Cloudflare Tunnel
# Version: 2.0.0 (Merged Version)
# Base Script Author: frank-cn-2000 <https://github.com/frank-cn-2000/sing-box-yg>
# Cloudflare Tunnel Integration & Enhancements: AI Assistant / szgz methodology
# Script Update Date: 2024-05-09
#=========================================================================================

# --- Global Variables & Configuration ---
SCRIPT_VERSION="2.0.0"
SCRIPT_UPDATE_DATE="2024-05-09" # Date of this merge

# Colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# Paths
# Main Sing-box paths (from original script, slightly standardized naming)
SING_BOX_BIN_PATH="/usr/local/bin/sing-box"
SING_BOX_CONFIG_FILE="/usr/local/etc/sing-box/config.json" # Main config
SING_BOX_USER_INFO_FILE="/etc/sing-box-yg/info.json"      # User & port info by frank-cn-2000 script
SING_BOX_LOG_FILE="/var/log/sing-box.log"
SING_BOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"
SING_BOX_CONFIG_PATH_DIR="/usr/local/etc/sing-box/" # Directory for config
SING_BOX_INFO_PATH_DIR="/etc/sing-box-yg/"          # Directory for info file

# Cloudflared paths
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_SERVICE_NAME="cloudflared"
CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"

# OS detection variables
OS_RELEASE=""
OS_VERSION=""
OS_ARCH="" # System architecture (amd64, arm64, etc.)
SING_BOX_ARCH="" # Architecture mapping for sing-box releases

# --- Helper Functions ---
echo_color() { local color=$1; shift; echo -e "${color}$*${PLAIN}"; }
echo_error() { echo_color "${RED}" "$@"; }
echo_success() { echo_color "${GREEN}" "$@"; }
echo_warning() { echo_color "${YELLOW}" "$@"; }
echo_info() { echo_color "${BLUE}" "$@"; }
echo_line() { echo "--------------------------------------------------------------------"; }

press_to_continue() { echo_info "Press Enter to continue..."; read -r; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "Error: This script must be run as root."
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_RELEASE=$ID
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS_RELEASE=$(lsb_release -si)
        OS_VERSION=$(lsb_release -sr)
    elif [[ -f /etc/lsb-release ]]; then
        . /etc/lsb-release
        OS_RELEASE=$DISTRIB_ID
        OS_VERSION=$DISTRIB_RELEASE
    elif [[ -f /etc/debian_version ]]; then
        OS_RELEASE="debian"; OS_VERSION=$(cat /etc/debian_version)
    elif [[ -f /etc/redhat-release ]]; then
        OS_RELEASE=$(grep -oE '^(CentOS|AlmaLinux|Rocky|Red Hat Enterprise Linux)' /etc/redhat-release | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/red hat enterprise linux/rhel/')
        [[ -z "$OS_RELEASE" ]] && OS_RELEASE=$(cat /etc/redhat-release | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
    else
        echo_error "Unsupported OS detection method."
        exit 1
    fi

    case $(uname -m) in
        i386 | i686) OS_ARCH="386"; SING_BOX_ARCH="386" ;;
        x86_64 | amd64) OS_ARCH="amd64"; SING_BOX_ARCH="amd64" ;;
        armv5tel) OS_ARCH="armv5"; SING_BOX_ARCH="armv5" ;;
        armv6l) OS_ARCH="armv6"; SING_BOX_ARCH="armv6" ;;
        armv7l | armv8l) OS_ARCH="armv7"; SING_BOX_ARCH="armv7" ;; # sing-box uses armv7
        aarch64 | arm64) OS_ARCH="arm64"; SING_BOX_ARCH="arm64" ;;
        s390x) OS_ARCH="s390x"; SING_BOX_ARCH="s390x" ;;
        riscv64) OS_ARCH="riscv64"; SING_BOX_ARCH="riscv64" ;;
        *) echo_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    echo_info "OS: ${OS_RELEASE} ${OS_VERSION}, System Arch: ${OS_ARCH}, Sing-box Arch: ${SING_BOX_ARCH}"
}

check_dependencies() {
    local dependencies=("curl" "wget" "jq" "openssl" "uuid-runtime" "qrencode")
    local missing_deps_pkg_names=() # Package names to install
    local missing_commands=() # Actual commands missing

    echo_info "Checking for required commands/packages: ${dependencies[*]}"
    for dep_pkg_name in "${dependencies[@]}"; do
        local cmd_to_check="$dep_pkg_name"
        case "$dep_pkg_name" in
            "uuid-runtime") cmd_to_check="uuidgen" ;;
            "qrencode") cmd_to_check="qrencode" ;;
        esac
        if ! command -v "$cmd_to_check" &>/dev/null; then
            missing_deps_pkg_names+=("$dep_pkg_name")
            missing_commands+=("$cmd_to_check")
        fi
    done

    if [[ ${#missing_deps_pkg_names[@]} -gt 0 ]]; then
        echo_warning "Missing commands/packages: Pkgs to check: [${missing_deps_pkg_names[*]}] for commands: [${missing_commands[*]}]"
        if [[ "$OS_RELEASE" == "ubuntu" || "$OS_RELEASE" == "debian" || "$OS_RELEASE" == "raspbian" ]]; then
            echo_info "Attempting to install for Debian/Ubuntu..."
            echo_info "Running apt update..."
            sudo apt update
            echo_info "Attempting to install: ${missing_deps_pkg_names[*]}"
            if ! sudo apt install -y "${missing_deps_pkg_names[@]}"; then
                 echo_error "Failed with apt: ${missing_deps_pkg_names[*]}"
            else echo_success "Apt install attempt finished for: ${missing_deps_pkg_names[*]}"; fi
        elif [[ "$OS_RELEASE" == "centos" || "$OS_RELEASE" == "almalinux" || "$OS_RELEASE" == "rocky" || "$OS_RELEASE" == "rhel" ]]; then
            echo_info "Attempting to install for RHEL-based..."
            local rhel_install_list=()
            for pkg in "${missing_deps_pkg_names[@]}"; do
                [[ "$pkg" == "uuid-runtime" ]] && rhel_install_list+=("util-linux") || rhel_install_list+=("$pkg")
            done
            rhel_install_list=($(echo "${rhel_install_list[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')) # Unique
            
            if [[ " ${rhel_install_list[*]} " =~ " jq " || " ${rhel_install_list[*]} " =~ " qrencode " ]] && ! rpm -q epel-release &>/dev/null && [[ "$OS_VERSION" =~ ^[789] ]]; then
                echo_info "EPEL likely needed. Installing epel-release..."
                sudo yum install -y epel-release
            fi
            echo_info "Running yum makecache..."
            sudo yum makecache
            echo_info "Attempting to install with yum: ${rhel_install_list[*]}"
            if ! sudo yum install -y "${rhel_install_list[@]}"; then
                echo_error "Failed with yum: ${rhel_install_list[*]}"
            else echo_success "Yum install attempt finished for: ${rhel_install_list[*]}"; fi
        else
            echo_error "Unsupported OS for auto-dependency install: ${OS_RELEASE}"
        fi

        local still_missing_final=()
        for dep_pkg_name_final in "${dependencies[@]}"; do
            local cmd_to_check_final="$dep_pkg_name_final"
            case "$dep_pkg_name_final" in
                "uuid-runtime") cmd_to_check_final="uuidgen" ;;
                "qrencode") cmd_to_check_final="qrencode" ;;
            esac
            if ! command -v "$cmd_to_check_final" &>/dev/null; then
                still_missing_final+=("$cmd_to_check_final (from $dep_pkg_name_final or equivalent)")
            fi
        done
        if [[ ${#still_missing_final[@]} -gt 0 ]]; then
            echo_error "Critical commands still missing: ${still_missing_final[*]}. Please install manually."
            exit 1
        fi
        echo_success "Dependency check passed after installation attempt."
    else
        echo_success "All required dependencies are already installed."
    fi
}

# --- Cloudflare Tunnel Functions ---
check_cloudflared_arch() {
    case $(uname -m) in
    i386 | i686) ARCH_CLOUDFLARED="386" ;;
    x86_64 | amd64) ARCH_CLOUDFLARED="amd64" ;;
    armv5tel | armv6l | armv7l | armv8l) ARCH_CLOUDFLARED="arm" ;;
    aarch64 | arm64) ARCH_CLOUDFLARED="arm64" ;;
    *) echo_error "Unsupported architecture for Cloudflared: $(uname -m)"; return 1 ;;
    esac
    return 0
}

install_cloudflared_executable() {
    echo_info "Detecting architecture for Cloudflared..."
    check_cloudflared_arch || return 1
    echo_info "Downloading Cloudflared for ${ARCH_CLOUDFLARED} architecture..."
    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CLOUDFLARED}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -Lso "${CLOUDFLARED_BIN}" "${download_url}" || { echo_error "Curl download failed: ${download_url}"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${CLOUDFLARED_BIN}" "${download_url}" || { echo_error "Wget download failed: ${download_url}"; return 1; }
    else echo_error "Neither curl nor wget found."; return 1; fi

    [[ ! -f "${CLOUDFLARED_BIN}" ]] && { echo_error "Cloudflared binary not found after download."; return 1; }
    chmod +x "${CLOUDFLARED_BIN}"
    echo_success "Cloudflared binary at ${CLOUDFLARED_BIN}"
    return 0
}

get_singbox_listen_port_for_tunnel() {
    local port=""
    if [[ -f "$SING_BOX_USER_INFO_FILE" ]]; then # Check info file first
        port=$(jq -r '.listen_port // .reality_listen_port // ""' "$SING_BOX_USER_INFO_FILE" 2>/dev/null)
        [[ -n "$port" && "$port" != "null" ]] && { echo "$port"; return 0; }
    fi
    if [[ -f "$SING_BOX_CONFIG_FILE" ]]; then # Fallback to main config
        port=$(jq -r '.inbounds[] | select(.type=="vmess" or .type=="vless" or .type=="trojan" or .type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or .type=="mixed") | .listen_port | select(. != null) | tostring' "$SING_BOX_CONFIG_FILE" | head -n 1)
        [[ -n "$port" && "$port" != "null" ]] && { echo_info "Found port $port from main config."; echo "$port"; return 0; }
        port=$(jq -r '.inbounds[0].listen_port // ""' "$SING_BOX_CONFIG_FILE" 2>/dev/null) # Absolute fallback to first inbound
        [[ -n "$port" && "$port" != "null" ]] && { echo_info "Found port $port from first inbound in main config."; echo "$port"; return 0; }
    fi
    echo_warning "Could not auto-determine Sing-box port for tunnel."
    read -rp "Enter Sing-box listening port for tunnel (e.g., 443, 2053): " manual_port
    [[ "$manual_port" =~ ^[0-9]+$ && "$manual_port" -gt 0 && "$manual_port" -le 65535 ]] && { echo "$manual_port"; return 0; } || { echo_error "Invalid port: $manual_port"; return 1; }
}

install_cloudflare_tunnel_service() {
    check_root
    [[ ! -f "${SING_BOX_CONFIG_FILE}" ]] && { echo_error "Sing-box not installed. Install it first."; press_to_continue; return 1; }

    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        echo_warning "${CLOUDFLARED_BIN} exists."
        read -rp "Skip download & proceed with service setup? (Y/n): " skip_dl; skip_dl=${skip_dl:-Y}
        if [[ "${skip_dl,,}" == "n" ]]; then
            read -rp "Re-download & overwrite ${CLOUDFLARED_BIN}? (y/N): " overwrite_cf; overwrite_cf=${overwrite_cf:-N}
            [[ "${overwrite_cf,,}" == "y" ]] && { sudo rm -f "${CLOUDFLARED_BIN}"; install_cloudflared_executable || return 1; }
        fi
    else install_cloudflared_executable || return 1; fi

    if systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service"; then
        echo_warning "Cloudflared service already installed."
        read -rp "Uninstall existing and reinstall? (y/N): " reinstall_svc; reinstall_svc=${reinstall_svc:-N}
        if [[ "${reinstall_svc,,}" == "y" ]]; then
            echo_info "Uninstalling existing Cloudflared service..."
            sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}" >/dev/null 2>&1
            sudo "${CLOUDFLARED_BIN}" service uninstall >/dev/null 2>&1
            sudo rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service" "/lib/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
            sudo systemctl daemon-reload
            echo_success "Existing service uninstalled."
        else echo_info "Skipping reinstallation."; return 0; fi
    fi

    local tunnel_sb_port; tunnel_sb_port=$(get_singbox_listen_port_for_tunnel)
    [[ $? -ne 0 || -z "$tunnel_sb_port" ]] && { echo_error "Failed to get Sing-box port. Aborting."; press_to_continue; return 1; }
    echo_info "Sing-box port for tunnel: ${YELLOW}${tunnel_sb_port}${PLAIN}"

    echo_line
    echo_info "Get Cloudflare Tunnel Token:"
    echo_info "1. Go to Cloudflare Zero Trust: ${GREEN}https://one.dash.cloudflare.com/${PLAIN}"
    echo_info "2. ${YELLOW}Access -> Tunnels${PLAIN} -> ${BLUE}Create a tunnel${PLAIN} -> Type: ${CYAN}Cloudflared${PLAIN}"
    echo_info "3. Name tunnel (e.g., singbox-server) -> ${BLUE}Save tunnel${PLAIN}"
    echo_info "4. Choose OS (e.g., Linux -> Debian/Ubuntu, 64-bit)"
    echo_info "5. ${RED}COPY THE TOKEN${PLAIN} from 'cloudflared service install TOKEN_HERE'"
    echo_line
    read -rp "Paste Cloudflare Tunnel Token: " cf_token
    [[ -z "$cf_token" ]] && { echo_error "No token. Aborting."; press_to_continue; return 1; }

    echo_info "Installing Cloudflared service with token..."
    if sudo "${CLOUDFLARED_BIN}" service install "${cf_token}"; then
        echo_success "Cloudflared service installed."
        sudo systemctl enable "${CLOUDFLARED_SERVICE_NAME}" --now >/dev/null 2>&1
        echo_info "Waiting for tunnel to establish..." && sleep 5
        echo_line
        echo_success "Cloudflare Tunnel service setup."
        echo_info "${RED}NEXT STEPS IN CLOUDFLARE DASHBOARD:${PLAIN}"
        echo_info "1. Back in Tunnels, ${BLUE}Configure${PLAIN} your tunnel."
        echo_info "2. Tab ${CYAN}Public Hostnames${PLAIN} -> ${BLUE}Add a public hostname${PLAIN}"
        echo_info "   - Subdomain: (e.g., mysb), Domain: (your domain)"
        echo_info "   - Path: (empty or specific, e.g. /vless)"
        echo_info "   - Service Type: ${GREEN}HTTP${PLAIN}, URL: ${GREEN}localhost:${tunnel_sb_port}${PLAIN}"
        echo_info "   - (Optional) Additional settings -> TLS -> No TLS Verify (if local Sing-box uses self-signed HTTPS)"
        echo_info "3. ${BLUE}Save hostname${PLAIN}."
        echo_info "Access via ${GREEN}https://<subdomain>.<domain>/<path>${PLAIN}"
        echo_info "Status: ${CYAN}systemctl status ${CLOUDFLARED_SERVICE_NAME}${PLAIN}, Logs: ${CYAN}journalctl -u ${CLOUDFLARED_SERVICE_NAME} -f${PLAIN}"
    else
        echo_error "Cloudflared service install failed. Check logs."
        echo_error "Try: journalctl -u ${CLOUDFLARED_SERVICE_NAME}"
    fi
    press_to_continue
}

uninstall_cloudflare_tunnel_service() {
    check_root
    echo_info "Uninstalling Cloudflare Tunnel..."
    if systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service"; then
        sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}"
        sudo systemctl disable "${CLOUDFLARED_SERVICE_NAME}" >/dev/null 2>&1
        [[ -f "$CLOUDFLARED_BIN" ]] && sudo "${CLOUDFLARED_BIN}" service uninstall
        sudo rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service" "/lib/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
        sudo systemctl daemon-reload
        echo_success "Cloudflared service uninstalled."
    else echo_info "Cloudflared service not installed."; fi

    read -rp "Remove ${CLOUDFLARED_BIN} executable? (y/N): " rm_bin; rm_bin=${rm_bin:-N}
    [[ "${rm_bin,,}" == "y" && -f "$CLOUDFLARED_BIN" ]] && sudo rm -f "${CLOUDFLARED_BIN}" && echo_success "Executable removed."

    read -rp "Remove configs (${CLOUDFLARED_CONFIG_DIR}, /root/.cloudflared)? (y/N): " rm_cfg; rm_cfg=${rm_cfg:-N}
    if [[ "${rm_cfg,,}" == "y" ]]; then
        sudo rm -rf "${CLOUDFLARED_CONFIG_DIR}" "/root/.cloudflared"
        echo_success "Configs removed."
    fi
    echo_info "Uninstallation complete. Delete tunnel from Cloudflare dashboard if needed."
    press_to_continue
}

manage_cloudflare_tunnel() {
    clear
    echo_line; echo_color "${GREEN}" "Cloudflare Tunnel Management"; echo_color "${CYAN}" "---"
    echo -e "  ${GREEN}1.${PLAIN} Install Tunnel Service"; echo -e "  ${GREEN}2.${PLAIN} Uninstall Tunnel Service"
    echo -e "  ${GREEN}3.${PLAIN} Start Tunnel"; echo -e "  ${GREEN}4.${PLAIN} Stop Tunnel"; echo -e "  ${GREEN}5.${PLAIN} Restart Tunnel"
    echo -e "  ${GREEN}6.${PLAIN} Tunnel Status"; echo -e "  ${GREEN}7.${PLAIN} Tunnel Logs"; echo -e "  ${GREEN}0.${PLAIN} Back to Main Menu"
    echo_color "${CYAN}" "---"; read -rp "Choice [0-7]: " choice

    local svc_exists; svc_exists=$(systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service" && echo true || echo false)
    handle_svc_action() {
        $svc_exists && { sudo systemctl "$1" "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Service $1 successful." || echo_error "Service $1 failed."; } || echo_error "Service not installed."
        press_to_continue
    }
    case "$choice" in
        1) install_cloudflare_tunnel_service ;;
        2) uninstall_cloudflare_tunnel_service ;;
        3) handle_svc_action "start" ;;
        4) handle_svc_action "stop" ;;
        5) handle_svc_action "restart" ;;
        6) $svc_exists && sudo systemctl status "${CLOUDFLARED_SERVICE_NAME}" --no-pager || echo_error "Service not installed."; press_to_continue ;;
        7) $svc_exists && { echo_info "Logs for ${CLOUDFLARED_SERVICE_NAME}. Ctrl+C to exit."; sudo journalctl -u "${CLOUDFLARED_SERVICE_NAME}" -f --no-pager; } || echo_error "Service not installed." ;; # No press_to_continue
        0) return ;;
        *) echo_error "Invalid choice."; press_to_continue ;;
    esac
    [[ "$choice" != "0" && "$choice" != "7" ]] && manage_cloudflare_tunnel # Loop back unless returning or viewing logs
    [[ "$choice" == "7" ]] && press_to_continue && manage_cloudflare_tunnel # Loop back for logs after manual exit from logs
}


# --- Sing-box Core Functions (Merged from frank-cn-2000/sing-box-yg/sb.sh) ---

# Function to check if Sing-box is installed
is_sing_box_installed() {
    [[ -f "${SING_BOX_BIN_PATH}" && -f "${SING_BOX_CONFIG_FILE}" && -f "${SING_BOX_SERVICE_FILE}" ]]
}

# Install Sing-box
install_sing_box() {
    echo_info "Starting Sing-box installation..."
    if is_sing_box_installed; then
        echo_warning "Sing-box already installed. For reinstallation, uninstall first."
        press_to_continue
        return
    fi

    # Download and install Sing-box binary
    echo_info "Downloading Sing-box core for ${SING_BOX_ARCH}..."
    local latest_version; latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    if [[ -z "$latest_version" ]]; then
        echo_error "Failed to fetch latest Sing-box version. Check network or GitHub API."
        press_to_continue
        return
    fi
    echo_info "Latest Sing-box version: ${latest_version}"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version_no_v#v}-linux-${SING_BOX_ARCH}.tar.gz"
    latest_version_no_v="${latest_version#v}" # remove 'v' prefix if present
    download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}.tar.gz"


    if command -v curl >/dev/null 2>&1; then
        curl -Lso "/tmp/sing-box.tar.gz" "$download_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "/tmp/sing-box.tar.gz" "$download_url"
    else
        echo_error "Neither curl nor wget found for downloading."
        press_to_continue
        return
    fi

    if [[ ! -s "/tmp/sing-box.tar.gz" ]]; then # Check if file is not empty
        echo_error "Failed to download Sing-box archive or archive is empty."
        rm -f "/tmp/sing-box.tar.gz"
        press_to_continue
        return
    fi

    sudo tar -xzf "/tmp/sing-box.tar.gz" -C "/tmp/"
    # The extracted folder name is sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}
    sudo mv "/tmp/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}/sing-box" "${SING_BOX_BIN_PATH}"
    sudo chmod +x "${SING_BOX_BIN_PATH}"
    sudo rm -rf "/tmp/sing-box.tar.gz" "/tmp/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}"
    echo_success "Sing-box binary installed at ${SING_BOX_BIN_PATH}"

    # Create config directory
    sudo mkdir -p "${SING_BOX_CONFIG_PATH_DIR}"
    sudo mkdir -p "${SING_BOX_INFO_PATH_DIR}" # For user info file

    # Create default config (basic structure)
    if [[ ! -f "${SING_BOX_CONFIG_FILE}" ]]; then
        echo_info "Creating default config file..."
        cat <<EOF | sudo tee "${SING_BOX_CONFIG_FILE}" > /dev/null
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
        echo_success "Default config created at ${SING_BOX_CONFIG_FILE}"
    fi
    
    # Create service file
    if [[ ! -f "${SING_BOX_SERVICE_FILE}" ]]; then
        echo_info "Creating systemd service file..."
        cat <<EOF | sudo tee "${SING_BOX_SERVICE_FILE}" > /dev/null
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${SING_BOX_CONFIG_PATH_DIR}
ExecStart=${SING_BOX_BIN_PATH} run -c ${SING_BOX_CONFIG_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable sing-box
        echo_success "Systemd service created and enabled."
    fi

    echo_success "Sing-box installation complete."
    echo_info "You may need to configure inbounds and users now."
    press_to_continue
}

# Uninstall Sing-box
uninstall_sing_box() {
    echo_warning "This will uninstall Sing-box and remove all its configurations!"
    read -rp "Are you sure you want to continue? (y/N): " confirm
    confirm=${confirm:-N}
    if [[ "${confirm,,}" != "y" ]]; then
        echo_info "Uninstallation cancelled."
        press_to_continue
        return
    fi

    sudo systemctl stop sing-box >/dev/null 2>&1
    sudo systemctl disable sing-box >/dev/null 2>&1
    sudo rm -f "${SING_BOX_SERVICE_FILE}"
    sudo systemctl daemon-reload

    sudo rm -f "${SING_BOX_BIN_PATH}"
    sudo rm -rf "${SING_BOX_CONFIG_PATH_DIR}" # Removes config.json and other potential files
    sudo rm -rf "${SING_BOX_INFO_PATH_DIR}"   # Removes info.json
    sudo rm -f "${SING_BOX_LOG_FILE}"

    echo_success "Sing-box uninstalled successfully."
    press_to_continue
}

# Manage Sing-box Service (start, stop, restart, status)
manage_sing_box_service() {
    if ! is_sing_box_installed; then
        echo_error "Sing-box is not installed."
        press_to_continue
        return
    fi
    clear
    echo_color "${GREEN}" "Manage Sing-box Service"; echo_line
    echo -e "  ${GREEN}1.${PLAIN} Start Sing-box"
    echo -e "  ${GREEN}2.${PLAIN} Stop Sing-box"
    echo -e "  ${GREEN}3.${PLAIN} Restart Sing-box"
    echo -e "  ${GREEN}4.${PLAIN} View Sing-box Status"
    echo -e "  ${GREEN}0.${PLAIN} Back to Main Menu"; echo_line
    read -rp "Enter your choice [0-4]: " choice

    case "$choice" in
        1) sudo systemctl start sing-box && echo_success "Sing-box started." || echo_error "Failed to start Sing-box." ;;
        2) sudo systemctl stop sing-box && echo_success "Sing-box stopped." || echo_error "Failed to stop Sing-box." ;;
        3) sudo systemctl restart sing-box && echo_success "Sing-box restarted." || echo_error "Failed to restart Sing-box." ;;
        4) sudo systemctl status sing-box --no-pager ;;
        0) return ;;
        *) echo_error "Invalid choice." ;;
    esac
    press_to_continue
    manage_sing_box_service # Loop back
}

# View Sing-box Logs
view_sing_box_logs() {
    if ! is_sing_box_installed; then
        echo_error "Sing-box is not installed."
        press_to_continue
        return
    fi
    echo_info "Displaying Sing-box logs (from journalctl). Press Ctrl+C to exit."
    sudo journalctl -u sing-box -f --no-pager
    # No press_to_continue, user exits manually
}

# Update Sing-box Core
update_sing_box_core() {
    if ! is_sing_box_installed; then
        echo_error "Sing-box is not installed. Please install it first."
        press_to_continue
        return
    fi
    echo_info "Checking for Sing-box core updates..."
    local current_version; current_version=$(${SING_BOX_BIN_PATH} version | head -n1 | awk '{print $3}')
    local latest_version; latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    latest_version_no_v="${latest_version#v}" # remove 'v' prefix

    if [[ -z "$latest_version" ]]; then
        echo_error "Failed to fetch latest version from GitHub."
        press_to_continue
        return
    fi

    echo_info "Current version: ${current_version}"
    echo_info "Latest version: ${latest_version_no_v}"

    if [[ "$current_version" == "$latest_version_no_v" ]]; then
        echo_success "You are already using the latest version of Sing-box."
        press_to_continue
        return
    fi

    read -rp "New version ${latest_version_no_v} available. Update now? (Y/n): " confirm_update
    confirm_update=${confirm_update:-Y}
    if [[ "${confirm_update,,}" != "y" ]]; then
        echo_info "Update cancelled."
        press_to_continue
        return
    fi

    echo_info "Downloading Sing-box ${latest_version_no_v} for ${SING_BOX_ARCH}..."
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}.tar.gz"

    if command -v curl >/dev/null 2>&1; then
        curl -Lso "/tmp/sing-box-update.tar.gz" "$download_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "/tmp/sing-box-update.tar.gz" "$download_url"
    else
        echo_error "Neither curl nor wget found."; press_to_continue; return
    fi

    if [[ ! -s "/tmp/sing-box-update.tar.gz" ]]; then
        echo_error "Download failed or archive is empty."; rm -f "/tmp/sing-box-update.tar.gz"; press_to_continue; return
    fi

    echo_info "Stopping Sing-box service..."
    sudo systemctl stop sing-box

    echo_info "Replacing binary..."
    sudo tar -xzf "/tmp/sing-box-update.tar.gz" -C "/tmp/"
    sudo mv "/tmp/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}/sing-box" "${SING_BOX_BIN_PATH}"
    sudo chmod +x "${SING_BOX_BIN_PATH}"
    sudo rm -rf "/tmp/sing-box-update.tar.gz" "/tmp/sing-box-${latest_version_no_v}-linux-${SING_BOX_ARCH}"

    echo_info "Starting Sing-box service..."
    sudo systemctl start sing-box
    echo_success "Sing-box updated to version $(${SING_BOX_BIN_PATH} version | head -n1 | awk '{print $3}')"
    press_to_continue
}

# Update This Script (Logic from frank-cn-2000/sing-box-yg, needs URL adjustment for merged script)
update_this_script() {
    echo_info "Checking for script updates..."
    # !!! IMPORTANT: This URL points to the original frank-cn-2000 script.
    # !!! If you host this merged script elsewhere, change this URL.
    local remote_script_url="https://raw.githubusercontent.com/frank-cn-2000/sing-box-yg/main/sb.sh"
    # As an alternative, if you want to update from szgz/proxy (which only has the CF part)
    # local remote_script_url="https://raw.githubusercontent.com/szgz/proxy/main/sb.sh" # This is likely NOT what you want for the full script
    
    echo_warning "Current update URL is: ${remote_script_url}"
    echo_warning "This might revert to a different script version if you are using a custom merged script."
    read -rp "Proceed with update check from this URL? (y/N): " proceed_update_check
    proceed_update_check=${proceed_update_check:-N}
    if [[ "${proceed_update_check,,}" != "y" ]]; then
        echo_info "Script update check cancelled."
        press_to_continue
        return
    fi

    local temp_script_path="/tmp/sb_update_temp.sh"
    if curl -Lso "$temp_script_path" "$remote_script_url"; then
        # Basic check: see if downloaded script is different and has a version string
        # This version check is rudimentary and might not be perfectly accurate if versions are formatted differently.
        local remote_version=$(grep -oP 'SCRIPT_VERSION="[^"]+"' "$temp_script_path" | grep -oP '"\K[^"]+')
        if [[ -n "$remote_version" && "$remote_version" != "$SCRIPT_VERSION" ]]; then # A simple string comparison
            echo_success "New version ${remote_version} found (current: ${SCRIPT_VERSION})."
            read -rp "Do you want to update the script? (Y/n): " confirm_script_update
            confirm_script_update=${confirm_script_update:-Y}
            if [[ "${confirm_script_update,,}" == "y" ]]; then
                chmod +x "$temp_script_path"
                if sudo mv "$temp_script_path" "$0"; then # $0 is the path of the current script
                    echo_success "Script updated successfully. Please re-run the script: sudo $0"
                    exit 0
                else
                    echo_error "Failed to replace the script. Check permissions."
                    sudo rm -f "$temp_script_path"
                fi
            else
                 echo_info "Script update cancelled by user."
                 sudo rm -f "$temp_script_path"
            fi
        elif [[ -n "$remote_version" && "$remote_version" == "$SCRIPT_VERSION" ]]; then
             echo_info "You are already using the latest version (${SCRIPT_VERSION}) from the checked URL."
             sudo rm -f "$temp_script_path"
        else
            echo_warning "Could not determine remote version or downloaded script is not different."
            echo_info "If you believe there's an update, check the URL manually: ${remote_script_url}"
            sudo rm -f "$temp_script_path"
        fi
    else
        echo_error "Failed to download the update script. Check network or URL: ${remote_script_url}"
    fi
    press_to_continue
}


# --- Sing-box Configuration & User Management Functions (Placeholders for frank-cn-2000 logic) ---
# These are complex and involve deep interaction with config.json and info.json.
# For now, I'll put basic placeholders. Merging them requires careful porting of jq logic.
# THE FOLLOWING FUNCTIONS ARE HIGHLY SIMPLIFIED AND NEED THE FULL LOGIC FROM frank-cn-2000/sing-box-yg/sb.sh

manage_sing_box_config() {
    if ! is_sing_box_installed; then echo_error "Sing-box not installed."; press_to_continue; return; fi
    echo_warning "Config management needs full merge from original frank-cn-2000 script."
    echo_info "You can manually edit: sudo nano ${SING_BOX_CONFIG_FILE}"
    echo_info "And user info (if used by config): sudo nano ${SING_BOX_USER_INFO_FILE}"
    press_to_continue
}

manage_users() {
    if ! is_sing_box_installed; then echo_error "Sing-box not installed."; press_to_continue; return; fi
    echo_warning "User management needs full merge from original frank-cn-2000 script."
    echo_info "This typically involves editing ${SING_BOX_CONFIG_FILE} and/or ${SING_BOX_USER_INFO_FILE}"
    press_to_continue
}

generate_client_config() {
    if ! is_sing_box_installed; then echo_error "Sing-box not installed."; press_to_continue; return; fi
    echo_warning "Client config/QR generation needs full merge from original frank-cn-2000 script."
    echo_info "This depends on your specific inbound configurations in ${SING_BOX_CONFIG_FILE}."
    press_to_continue
}

# --- Main Menu ---
main_menu() {
    clear
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${GREEN}"  " sing-box Management Script (Merged)  Version: ${SCRIPT_VERSION}"
    echo_color "${BLUE}"   " Script Date: ${SCRIPT_UPDATE_DATE}"
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${CYAN}"   "Current system time: $(date +"%Y-%m-%d %H:%M:%S")"
    echo_line
    echo -e "  ${GREEN}1.${PLAIN} Install Sing-box"
    echo -e "  ${GREEN}2.${PLAIN} Uninstall Sing-box"
    echo -e "  ${GREEN}3.${PLAIN} Manage Sing-box Service"
    echo -e "  ${GREEN}4.${PLAIN} Manage Sing-box Configuration ${YELLOW}(Basic Placeholder)${PLAIN}"
    echo -e "  ${GREEN}5.${PLAIN} Manage Users ${YELLOW}(Basic Placeholder)${PLAIN}"
    echo -e "  ${GREEN}6.${PLAIN} Generate Client Config / QR Code ${YELLOW}(Basic Placeholder)${PLAIN}"
    echo -e "  ${GREEN}7.${PLAIN} View Sing-box Logs"
    echo -e "  ${GREEN}8.${PLAIN} Update Sing-box Core"
    echo -e "  ${GREEN}9.${PLAIN} Update This Script ${YELLOW}(Check URL inside function!)${PLAIN}"
    echo -e "  ${GREEN}10.${PLAIN} Manage Cloudflare Tunnel ${RED}(New!)${PLAIN}"
    echo_line
    echo -e "  ${GREEN}0.${PLAIN} Exit Script"
    echo_color "${BLUE}" "------------------------------------------------------------------"
    read -rp "Please enter your choice [0-10]: " choice

    case "$choice" in
    1) install_sing_box ;;
    2) uninstall_sing_box ;;
    3) manage_sing_box_service ;;
    4) manage_sing_box_config ;;      # Placeholder
    5) manage_users ;;                # Placeholder
    6) generate_client_config ;;      # Placeholder
    7) view_sing_box_logs ;;
    8) update_sing_box_core ;;
    9) update_this_script ;;
    10) manage_cloudflare_tunnel ;;
    0) echo_success "Exiting script. Goodbye!"; exit 0 ;;
    *) echo_error "Invalid choice, please try again."; press_to_continue ;;
    esac
    [[ "$choice" != "0" ]] && main_menu # Loop back
}

# --- Script Initialization ---
check_root
clear
echo_info "Initializing Sing-box Management Script (Version: ${SCRIPT_VERSION})..."
check_os
check_dependencies

# Start main menu
main_menu
