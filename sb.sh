#!/bin/bash

#========================================================
# Project: sing-box mult-user management script
# Version: 1.0.3
# Author: gusarg84 <gusarg84@gmail.com>
# Blog: https://www.ygxb.org
# Github: https://github.com/frank-cn-2000/sing-box-yg
#========================================================

VERSION="1.0.3" # Script version
SCRIPT_UPDATE_DATE="2024-03-08" # Script update date

# Global Variables (some from original script, some new)
# Colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# Paths (some from original script, some new)
SING_BOX_CONFIG_PATH="/usr/local/etc/sing-box/"
SING_BOX_INFO_PATH="/etc/sing-box-yg/"
SING_BOX_BIN_PATH="/usr/local/bin/sing-box"
SING_BOX_SERVICE_NAME="sing-box"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_SERVICE_NAME="cloudflared"
CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"

# OS detection variables
OS_RELEASE=""
OS_VERSION=""
OS_ARCH=""

# Function to output colored text
echo_color() {
    local color=$1
    shift
    echo -e "${color}$*${PLAIN}"
}

echo_error() { echo_color "${RED}" "$@"; }
echo_success() { echo_color "${GREEN}" "$@"; }
echo_warning() { echo_color "${YELLOW}" "$@"; }
echo_info() { echo_color "${BLUE}" "$@"; }
echo_line() { echo "--------------------------------------------------------------------"; }

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root"
        exit 1
    fi
}

# Check OS
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
        OS_RELEASE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [[ -f /etc/redhat-release ]]; then
        OS_RELEASE=$(cat /etc/redhat-release | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    else
        echo_error "Unsupported OS"
        exit 1
    fi

    case $(uname -m) in
    i386 | i686) OS_ARCH="386" ;;
    x86_64 | amd64) OS_ARCH="amd64" ;;
    armv5tel) OS_ARCH="armv5" ;;
    armv6l) OS_ARCH="armv6" ;; # raspberry pi
    armv7l | armv8l) OS_ARCH="armv7" ;; # arm32
    aarch64 | arm64) OS_ARCH="arm64" ;; # arm64
    *)
        echo_error "Unsupported architecture: $(uname -m)"
        exit 1
        ;;
    esac
    echo_info "OS: ${OS_RELEASE} ${OS_VERSION}, Arch: ${OS_ARCH}"
}


# Check dependencies (add jq if not already checked by original sb.sh)
check_dependencies() {
    local dependencies=("curl" "wget" "jq" "openssl" "uuid-runtime") # uuid-runtime for uuidgen
    local missing_deps=()
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo_warning "Missing dependencies: ${missing_deps[*]}"
        if [[ "$OS_RELEASE" == "ubuntu" || "$OS_RELEASE" == "debian" ]]; then
            echo_info "Attempting to install missing dependencies..."
            sudo apt update >/dev/null 2>&1
            sudo apt install -y "${missing_deps[@]}" >/dev/null 2>&1
        elif [[ "$OS_RELEASE" == "centos" || "$OS_RELEASE" == "almalinux" || "$OS_RELEASE" == "rocky" ]]; then
            echo_info "Attempting to install missing dependencies..."
            sudo yum install -y epel-release >/dev/null 2>&1 # For jq and uuid on older CentOS
            sudo yum install -y "${missing_deps[@]}" >/dev/null 2>&1
        else
            echo_error "Please install the following dependencies manually: ${missing_deps[*]}"
            exit 1
        fi
        # Re-check after attempting installation
        for dep in "${missing_deps[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                echo_error "Failed to install dependency: $dep. Please install it manually."
                exit 1
            fi
        done
        echo_success "Dependencies installed."
    fi
}


# Pause
press_to_continue() {
    echo_info "Press Enter to continue..."
    read -r
}

# Function to check architecture for cloudflared
check_cloudflared_arch() {
    case $(uname -m) in
    i386 | i686) ARCH_CLOUDFLARED="386" ;;
    x86_64 | amd64) ARCH_CLOUDFLARED="amd64" ;;
    # cloudflared uses 'arm' for armv7 and 'arm64' for aarch64
    armv5tel | armv6l | armv7l | armv8l) ARCH_CLOUDFLARED="arm" ;;
    aarch64 | arm64) ARCH_CLOUDFLARED="arm64" ;;
    *)
        echo_error "Unsupported architecture for Cloudflared: $(uname -m)"
        return 1
        ;;
    esac
    return 0
}

# Function to install cloudflared executable
install_cloudflared_executable() {
    echo_info "Detecting architecture for Cloudflared..."
    if ! check_cloudflared_arch; then
        return 1
    fi

    echo_info "Downloading Cloudflared for ${ARCH_CLOUDFLARED} architecture..."
    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CLOUDFLARED}"

    if command -v curl >/dev/null 2>&1; then
        if curl -Lso "${CLOUDFLARED_BIN}" "${download_url}"; then
            echo_success "Cloudflared downloaded via curl."
        else
            echo_error "Download failed using curl. Please check your network or the URL."
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -qO "${CLOUDFLARED_BIN}" "${download_url}"; then
            echo_success "Cloudflared downloaded via wget."
        else
            echo_error "Download failed using wget. Please check your network or the URL."
            return 1
        fi
    else
        echo_error "Neither curl nor wget is installed. Please install one of them."
        return 1
    fi

    if [[ ! -f "${CLOUDFLARED_BIN}" ]]; then
        echo_error "Cloudflared binary not found after download attempt."
        return 1
    fi

    chmod +x "${CLOUDFLARED_BIN}"
    echo_success "Cloudflared binary downloaded and made executable at ${CLOUDFLARED_BIN}"
    return 0
}

# Function to get Sing-box listening port
get_singbox_listen_port() {
    local info_file="${SING_BOX_INFO_PATH}info.json"
    local config_file="${SING_BOX_CONFIG_PATH}config.json"
    local port=""

    if [[ -f "$info_file" ]]; then
        # Try to get common listen ports from info.json, prioritize reality, then general listen_port
        port=$(jq -r '.reality_listen_port // .listen_port // .inbounds[0].listen_port // ""' "$info_file" 2>/dev/null)
        if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo "$port"
            return 0
        fi
    fi

    # Fallback: try to parse config.json directly for a common inbound port
    if [[ -f "$config_file" ]]; then
        # Look for common inbound types and their listen_port
        # This tries to find the first listen_port from various common inbound types
        port=$(jq -r '
            .inbounds[] |
            select(.type=="vmess" or .type=="vless" or .type=="trojan" or .type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or .type=="mixed") |
            .listen_port |
            select(. != null) |
            tostring' "$config_file" | head -n 1)

        if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo_info "Found port $port from $config_file for a primary inbound."
            echo "$port"
            return 0
        fi
        # If still not found, try any inbound's listen_port
        port=$(jq -r '.inbounds[0].listen_port // ""' "$config_file" 2>/dev/null)
         if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo_info "Found port $port from first inbound in $config_file."
            echo "$port"
            return 0
        fi
    fi

    echo_warning "Could not automatically determine Sing-box listening port."
    read -rp "Please enter the Sing-box listening port you want to tunnel (e.g., 443, 8080, 2053): " manual_port
    if [[ "$manual_port" =~ ^[0-9]+$ && "$manual_port" -gt 0 && "$manual_port" -le 65535 ]]; then
        echo "$manual_port"
        return 0
    else
        echo_error "Invalid port entered."
        return 1
    fi
}

# Function to install Cloudflare Tunnel service
install_cloudflare_tunnel_service() {
    check_root
    if [[ ! -f "${SING_BOX_CONFIG_PATH}config.json" ]]; then
        echo_error "Sing-box does not appear to be installed. Please install Sing-box first."
        return 1
    fi

    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        echo_warning "Cloudflared executable already exists at ${CLOUDFLARED_BIN}."
        read -rp "Skip downloading and proceed with service setup? (Y/n): " skip_download
        skip_download=${skip_download:-Y}
        if [[ "${skip_download,,}" == "n" ]]; then
            read -rp "Re-download and overwrite ${CLOUDFLARED_BIN}? (y/N): " overwrite_cf
            overwrite_cf=${overwrite_cf:-N}
            if [[ "${overwrite_cf,,}" == "y" ]]; then
                 sudo rm -f "${CLOUDFLARED_BIN}"
                 install_cloudflared_executable || return 1
            else
                echo_info "Using existing Cloudflared binary."
            fi
        else
             echo_info "Using existing Cloudflared binary."
        fi
    else
        install_cloudflared_executable || return 1
    fi

    if systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service"; then
        echo_warning "Cloudflared service seems to be already installed."
        read -rp "Uninstall the existing service and reinstall? (y/N): " reinstall_service
        reinstall_service=${reinstall_service:-N}
        if [[ "${reinstall_service,,}" == "y" ]]; then
            echo_info "Stopping and uninstalling existing Cloudflared service..."
            sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}" >/dev/null 2>&1
            sudo "${CLOUDFLARED_BIN}" service uninstall >/dev/null 2>&1
            sudo rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
            sudo rm -f "/lib/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
            sudo systemctl daemon-reload
            echo_success "Existing Cloudflared service uninstalled."
        else
            echo_info "Skipping Cloudflared service reinstallation. You can manage the existing service from the menu."
            return 0
        fi
    fi

    local singbox_port
    singbox_port=$(get_singbox_listen_port)
    if [[ $? -ne 0 || -z "$singbox_port" ]]; then
        echo_error "Failed to get Sing-box port. Aborting tunnel setup."
        return 1
    fi
    echo_info "Sing-box is detected/configured to be listening on port: ${YELLOW}${singbox_port}${PLAIN}"

    echo_line
    echo_info "You need a Cloudflare Tunnel Token to proceed."
    echo_info "1. Go to Cloudflare Zero Trust Dashboard: ${GREEN}https://one.dash.cloudflare.com/${PLAIN}"
    echo_info "2. Navigate to ${YELLOW}Access -> Tunnels${PLAIN}."
    echo_info "3. Click '${BLUE}Create a tunnel${PLAIN}', choose '${CYAN}Cloudflared${PLAIN}' connector type."
    echo_info "4. Give your tunnel a name (e.g., singbox-server) and click '${BLUE}Save tunnel${PLAIN}'."
    echo_info "5. On the next page ('Install connector'), select your OS (e.g., Linux -> Debian/Ubuntu, 64-bit)."
    echo_info "6. ${RED}COPY THE TOKEN${PLAIN} from the command shown (it's the long string after 'cloudflared service install ...')."
    echo_line
    read -rp "Paste your Cloudflare Tunnel Token here: " cf_token
    if [[ -z "$cf_token" ]]; then
        echo_error "No token provided. Aborting."
        return 1
    fi

    echo_info "Installing Cloudflared service with token..."
    if sudo "${CLOUDFLARED_BIN}" service install "${cf_token}"; then
        echo_success "Cloudflared service installed successfully."
        sudo systemctl enable "${CLOUDFLARED_SERVICE_NAME}" >/dev/null 2>&1
        sudo systemctl start "${CLOUDFLARED_SERVICE_NAME}"
        
        echo_info "Waiting a few seconds for the tunnel to establish..."
        sleep 5 
        
        echo_line
        echo_success "Cloudflare Tunnel service is set up."
        echo_info "${RED}IMPORTANT NEXT STEPS IN CLOUDFLARE DASHBOARD:${PLAIN}"
        echo_info "1. Go back to your tunnel in ${YELLOW}Access -> Tunnels${PLAIN} in the Cloudflare dashboard."
        echo_info "   (The tunnel might take a moment to show as 'Healthy')."
        echo_info "2. Click '${BLUE}Configure${PLAIN}' for your tunnel."
        echo_info "3. Go to the '${CYAN}Public Hostnames${PLAIN}' tab."
        echo_info "4. Click '${BLUE}Add a public hostname${PLAIN}'."
        echo_info "   - ${YELLOW}Subdomain:${PLAIN} (e.g., mysb, vpn) Your chosen prefix."
        echo_info "   - ${YELLOW}Domain:${PLAIN}    Select your domain from the dropdown."
        echo_info "   - ${YELLOW}Path:${PLAIN}      (Leave empty if Sing-box handles paths, or specify if needed, e.g., /vless)"
        echo_info "   - ${YELLOW}Service Type:${PLAIN} Select ${GREEN}HTTP${PLAIN} (Usually. Cloudflare handles external HTTPS)."
        echo_info "   - ${YELLOW}Service URL:${PLAIN}  ${GREEN}localhost:${singbox_port}${PLAIN} (or http://localhost:${singbox_port})"
        echo_info "   - Under 'Additional application settings' -> 'TLS', you can optionally enable '${CYAN}No TLS Verify${PLAIN}' "
        echo_info "     if your local Sing-box service uses a self-signed cert AND you chose HTTPS type (not common for this default setup)."
        echo_info "5. Click '${BLUE}Save hostname${PLAIN}'."
        echo_line
        echo_info "Cloudflare will automatically create a CNAME record for this hostname pointing to your tunnel."
        echo_info "Your Sing-box should then be accessible via ${GREEN}https://<your_chosen_subdomain>.<your_domain>${PLAIN}"
        echo_info "(Cloudflare provides the HTTPS certificate for your public hostname)."
        echo_line
        echo_info "You can check the status with: ${CYAN}systemctl status ${CLOUDFLARED_SERVICE_NAME}${PLAIN}"
        echo_info "And logs with: ${CYAN}journalctl -u ${CLOUDFLARED_SERVICE_NAME} -f${PLAIN}"
    else
        echo_error "Cloudflared service installation failed. Check logs above."
        echo_error "You might need to run: journalctl -u ${CLOUDFLARED_SERVICE_NAME} or check system logs."
        echo_error "Ensure the token was correct and that ${CLOUDFLARED_BIN} has execute permissions."
    fi
}

# Function to uninstall Cloudflare Tunnel service
uninstall_cloudflare_tunnel_service() {
    check_root
    echo_info "Attempting to uninstall Cloudflare Tunnel..."

    if systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service"; then
        echo_info "Stopping Cloudflared service..."
        sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}"
        echo_info "Disabling Cloudflared service..."
        sudo systemctl disable "${CLOUDFLARED_SERVICE_NAME}" >/dev/null 2>&1
        
        if [[ -f "$CLOUDFLARED_BIN" ]]; then
            echo_info "Uninstalling service using ${CLOUDFLARED_BIN}..."
            sudo "${CLOUDFLARED_BIN}" service uninstall # This should clean up systemd entries
        else
            echo_warning "${CLOUDFLARED_BIN} not found. Manually removing systemd files if they exist."
        fi
        sudo rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
        sudo rm -f "/lib/systemd/system/${CLOUDFLARED_SERVICE_NAME}.service"
        sudo systemctl daemon-reload
        echo_success "Cloudflared service uninstalled."
    else
        echo_info "Cloudflared service does not appear to be installed."
    fi

    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        read -rp "Do you want to remove the Cloudflared executable (${CLOUDFLARED_BIN})? (y/N): " remove_bin
        remove_bin=${remove_bin:-N}
        if [[ "${remove_bin,,}" == "y" ]]; then
            sudo rm -f "${CLOUDFLARED_BIN}"
            echo_success "Cloudflared executable removed."
        fi
    fi

    read -rp "Do you want to remove Cloudflared configuration files (${CLOUDFLARED_CONFIG_DIR}, /root/.cloudflared)? (y/N): " remove_configs
    remove_configs=${remove_configs:-N}
    if [[ "${remove_configs,,}" == "y" ]]; then
        sudo rm -rf "${CLOUDFLARED_CONFIG_DIR}"
        sudo rm -rf "/root/.cloudflared" # Credentials and cert.pem are often here
        echo_success "Cloudflared configuration files removed."
    fi
    
    echo_info "Cloudflare Tunnel uninstallation process complete."
    echo_warning "You may also want to delete the tunnel from your Cloudflare Zero Trust dashboard."
}


# Manage Cloudflare Tunnel Menu
manage_cloudflare_tunnel() {
    echo_line
    echo_color "${GREEN}" "Cloudflare Tunnel Management"
    echo_color "${CYAN}" "------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} Install Cloudflare Tunnel Service"
    echo -e "  ${GREEN}2.${PLAIN} Uninstall Cloudflare Tunnel Service"
    echo -e "  ${GREEN}3.${PLAIN} Start Cloudflare Tunnel Service"
    echo -e "  ${GREEN}4.${PLAIN} Stop Cloudflare Tunnel Service"
    echo -e "  ${GREEN}5.${PLAIN} Restart Cloudflare Tunnel Service"
    echo -e "  ${GREEN}6.${PLAIN} View Cloudflare Tunnel Status"
    echo -e "  ${GREEN}7.${PLAIN} View Cloudflare Tunnel Logs"
    echo -e "  ${GREEN}0.${PLAIN} Back to Main Menu"
    echo_color "${CYAN}" "------------------------------------"
    read -rp "Please enter your choice [0-7]: " sub_choice

    local service_exists=false
    if systemctl list-unit-files | grep -q "^${CLOUDFLARED_SERVICE_NAME}.service"; then
        service_exists=true
    fi

    case "$sub_choice" in
    1)
        install_cloudflare_tunnel_service
        ;;
    2)
        uninstall_cloudflare_tunnel_service
        ;;
    3)
        if $service_exists; then
            sudo systemctl start "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Cloudflared service started." || echo_error "Failed to start Cloudflared service."
        else
            echo_error "Cloudflared service is not installed."
        fi
        ;;
    4)
        if $service_exists; then
            sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Cloudflared service stopped." || echo_error "Failed to stop Cloudflared service."
        else
            echo_error "Cloudflared service is not installed."
        fi
        ;;
    5)
        if $service_exists; then
            sudo systemctl restart "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Cloudflared service restarted." || echo_error "Failed to restart Cloudflared service."
        else
            echo_error "Cloudflared service is not installed."
        fi
        ;;
    6)
        if $service_exists; then
            sudo systemctl status "${CLOUDFLARED_SERVICE_NAME}" --no-pager
        else
            echo_error "Cloudflared service is not installed."
        fi
        ;;
    7)
        if $service_exists; then
            sudo journalctl -u "${CLOUDFLARED_SERVICE_NAME}" -f --no-pager
        else
            echo_error "Cloudflared service is not installed."
        fi
        ;;
    0)
        return
        ;;
    *)
        echo_error "Invalid choice."
        ;;
    esac
    if [[ "$sub_choice" != "0" ]]; then
        press_to_continue
    fi
}

# Placeholder for existing sing-box functions (from original sb.sh)
# These functions would be defined here in the actual script.
# For brevity, I'm not re-listing all of them but they are essential.

install_sing_box() { echo_info "Placeholder for install_sing_box function"; }
uninstall_sing_box() { echo_info "Placeholder for uninstall_sing_box function"; }
manage_sing_box_service() { echo_info "Placeholder for manage_sing_box_service function"; }
manage_sing_box_config() { echo_info "Placeholder for manage_sing_box_config function"; }
manage_users() { echo_info "Placeholder for manage_users function"; }
generate_client_config() { echo_info "Placeholder for generate_client_config function"; }
view_logs() { echo_info "Placeholder for view_logs function"; }
update_script() { echo_info "Placeholder for update_script function"; }
update_sing_box_core() { echo_info "Placeholder for update_sing_box_core function"; }
# Add any other functions from the original sb.sh

# Main Menu
main_menu() {
    clear
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${GREEN}"  " sing-box Multi-User Management Script  Version: ${VERSION}"
    echo_color "${BLUE}"   " Author: gusarg84 (Original by frank-cn-2000)"
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${CYAN}"   "Current system time: $(date +"%Y-%m-%d %H:%M:%S")"
    echo_line
    echo -e "  ${GREEN}1.${PLAIN} Install Sing-box"
    echo -e "  ${GREEN}2.${PLAIN} Uninstall Sing-box"
    echo -e "  ${GREEN}3.${PLAIN} Manage Sing-box Service"
    echo -e "  ${GREEN}4.${PLAIN} Manage Sing-box Configuration"
    echo -e "  ${GREEN}5.${PLAIN} Manage Users"
    echo -e "  ${GREEN}6.${PLAIN} Generate Client Configuration / QR Code"
    echo -e "  ${GREEN}7.${PLAIN} View Sing-box Logs"
    echo -e "  ${GREEN}8.${PLAIN} Update Sing-box Core"
    echo -e "  ${GREEN}9.${PLAIN} Update This Script"
    echo -e "  ${GREEN}10.${PLAIN} Manage Cloudflare Tunnel ${RED}(New!)${PLAIN}" # New Option
    # If you had other options like Warp, adjust numbering accordingly
    echo_line
    echo -e "  ${GREEN}0.${PLAIN} Exit Script"
    echo_color "${BLUE}" "------------------------------------------------------------------"
    read -rp "Please enter your choice [0-10]: " choice # Adjusted range

    case "$choice" in
    1) install_sing_box ;;
    2) uninstall_sing_box ;;
    3) manage_sing_box_service ;;
    4) manage_sing_box_config ;;
    5) manage_users ;;
    6) generate_client_config ;;
    7) view_logs ;;
    8) update_sing_box_core ;;
    9) update_script ;;
    10) manage_cloudflare_tunnel ;; # New case
    0)
        echo_success "Exiting script. Goodbye!"
        exit 0
        ;;
    *)
        echo_error "Invalid choice, please try again."
        press_to_continue
        ;;
    esac

    # Loop back to main menu if not exiting
    if [[ "$choice" != "0" ]]; then
        main_menu
    fi
}

# --- Script Initialization ---
check_root
check_os
check_dependencies # Ensure this is called

# Start main menu
main_menu
