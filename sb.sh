#!/bin/bash

#========================================================
# Project: sing-box mult-user management script
# Version: 1.0.4 (Updated with Cloudflare Tunnel & improved deps)
# Author: gusarg84 <gusarg84@gmail.com> (Cloudflare integration)
# Original Base Author: frank-cn-2000 <https://github.com/frank-cn-2000/sing-box-yg>
# Cloudflare Tunnel based on logic from szgz/proxy
#========================================================

VERSION="1.0.4" # Script version
SCRIPT_UPDATE_DATE="2024-05-02" # Script update date

# Global Variables
# Colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# Paths
SING_BOX_CONFIG_PATH="/usr/local/etc/sing-box/"
SING_BOX_INFO_PATH="/etc/sing-box-yg/" # Used by original script for storing info
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
        # For CentOS, RHEL, AlmaLinux, Rocky etc.
        OS_RELEASE=$(grep -oE '^(CentOS|AlmaLinux|Rocky|Red Hat Enterprise Linux)' /etc/redhat-release | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/red hat enterprise linux/rhel/')
        [[ -z "$OS_RELEASE" ]] && OS_RELEASE=$(cat /etc/redhat-release | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]') # Fallback
        OS_VERSION=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
    else
        echo_error "Unsupported OS detection method."
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


# Check dependencies
check_dependencies() {
    local dependencies=("curl" "wget" "jq" "openssl" "uuid-runtime") # uuid-runtime for uuidgen command
    local missing_deps=()
    echo_info "Checking for required dependencies: ${dependencies[*]}"
    for dep in "${dependencies[@]}"; do
        # For uuid-runtime, we actually check for the command `uuidgen`
        if [[ "$dep" == "uuid-runtime" ]]; then
            if ! command -v "uuidgen" &>/dev/null; then
                missing_deps+=("$dep") # Add the package name we'll try to install
            fi
        elif ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo_warning "Missing dependencies or commands: ${missing_deps[*]}"
        # Attempt to install based on OS
        if [[ "$OS_RELEASE" == "ubuntu" || "$OS_RELEASE" == "debian" || "$OS_RELEASE" == "raspbian" ]]; then
            echo_info "Attempting to install missing dependencies for Debian/Ubuntu based system..."
            echo_info "Running apt update (this may take a moment)..."
            if ! sudo apt update; then
                echo_error "apt update failed. Please check your network and apt sources."
                echo_warning "You might need to run 'sudo apt update' manually and then re-run this script."
            fi
            echo_info "Attempting to install: ${missing_deps[*]}"
            if ! sudo apt install -y "${missing_deps[@]}"; then
                echo_error "Failed to install one or more dependencies using apt: ${missing_deps[*]}"
                echo_warning "Please try installing them manually and then re-run the script."
            else
                echo_success "Successfully attempted to install: ${missing_deps[*]}"
            fi
        elif [[ "$OS_RELEASE" == "centos" || "$OS_RELEASE" == "almalinux" || "$OS_RELEASE" == "rocky" || "$OS_RELEASE" == "rhel" ]]; then
            echo_info "Attempting to install missing dependencies for RHEL based system..."
            echo_info "Running yum makecache (this may take a moment)..."
            sudo yum makecache
            
            local rhel_deps_to_install=()
            for dep_item in "${missing_deps[@]}"; do
                if [[ "$dep_item" == "uuid-runtime" ]]; then
                    # On RHEL-like systems, uuidgen is part of util-linux
                    if ! rpm -q util-linux &>/dev/null || ! command -v uuidgen &>/dev/null; then
                        rhel_deps_to_install+=("util-linux")
                    fi
                else
                    rhel_deps_to_install+=("$dep_item")
                fi
            done
            # Remove duplicates just in case
            rhel_deps_to_install=($(echo "${rhel_deps_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

            if [[ ${#rhel_deps_to_install[@]} -gt 0 ]]; then
                echo_info "Attempting to install with yum: ${rhel_deps_to_install[*]}"
                # Ensure EPEL is enabled if jq or other common tools are missing (often needed for jq)
                if [[ " ${rhel_deps_to_install[*]} " =~ " jq " ]] && ! rpm -q epel-release &>/dev/null && [[ "$OS_VERSION" =~ ^[789] ]]; then
                    echo_info "EPEL repository not found or jq is missing. Attempting to install EPEL release..."
                    sudo yum install -y epel-release
                    sudo yum makecache # Refresh cache after adding EPEL
                fi

                 if ! sudo yum install -y "${rhel_deps_to_install[@]}"; then
                    echo_error "Failed to install one or more dependencies using yum: ${rhel_deps_to_install[*]}"
                    echo_warning "Please try installing them manually and then re-run the script."
                 else
                    echo_success "Successfully attempted to install with yum: ${rhel_deps_to_install[*]}"
                 fi
            else
                echo_info "No new packages identified for installation via yum for the listed missing commands."
            fi
        else
            echo_error "Unsupported OS for automatic dependency installation: ${OS_RELEASE}"
            echo_warning "Please install the following dependencies/commands manually: ${missing_deps[*]}"
            exit 1
        fi

        # Re-check after attempting installation
        local still_missing_commands=()
        for dep_pkg_name in "${dependencies[@]}"; do
            local cmd_to_check="$dep_pkg_name"
            if [[ "$dep_pkg_name" == "uuid-runtime" ]]; then
                cmd_to_check="uuidgen"
            fi
            if ! command -v "$cmd_to_check" &>/dev/null; then
                still_missing_commands+=("$cmd_to_check (expected from $dep_pkg_name or equivalent)")
            fi
        done

        if [[ ${#still_missing_commands[@]} -gt 0 ]]; then
            echo_error "Critical commands still missing after installation attempt: ${still_missing_commands[*]}"
            echo_error "Please ensure these commands are available and re-run the script."
            exit 1
        fi
        echo_success "All required dependencies appear to be installed and commands available."
    else
        echo_success "All required dependencies are already installed and commands available."
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
            echo_error "Download failed using curl. Please check your network or the URL: ${download_url}"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -qO "${CLOUDFLARED_BIN}" "${download_url}"; then
            echo_success "Cloudflared downloaded via wget."
        else
            echo_error "Download failed using wget. Please check your network or the URL: ${download_url}"
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
        port=$(jq -r '.reality_listen_port // .listen_port // .inbounds[0].listen_port // ""' "$info_file" 2>/dev/null)
        if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo "$port"
            return 0
        fi
    fi

    if [[ -f "$config_file" ]]; then
        port=$(jq -r '
            .inbounds[] |
            select(.type=="vmess" or .type=="vless" or .type=="trojan" or .type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or .type=="mixed") |
            .listen_port |
            select(. != null) |
            tostring' "$config_file" | head -n 1)

        if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo_info "Found port $port from a primary inbound in $config_file."
            echo "$port"
            return 0
        fi
        port=$(jq -r '.inbounds[0].listen_port // ""' "$config_file" 2>/dev/null)
         if [[ -n "$port" && "$port" != "null" && "$port" != "" ]]; then
            echo_info "Found port $port from the first inbound in $config_file."
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
        echo_error "Invalid port entered: $manual_port"
        return 1
    fi
}

# Function to install Cloudflare Tunnel service
install_cloudflare_tunnel_service() {
    check_root
    if [[ ! -f "${SING_BOX_CONFIG_PATH}config.json" ]]; then
        echo_error "Sing-box does not appear to be installed. Please install Sing-box first."
        press_to_continue
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
        press_to_continue
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
        press_to_continue
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
    press_to_continue
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
    press_to_continue
}


# Manage Cloudflare Tunnel Menu
manage_cloudflare_tunnel() {
    clear
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
        press_to_continue
        ;;
    4)
        if $service_exists; then
            sudo systemctl stop "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Cloudflared service stopped." || echo_error "Failed to stop Cloudflared service."
        else
            echo_error "Cloudflared service is not installed."
        fi
        press_to_continue
        ;;
    5)
        if $service_exists; then
            sudo systemctl restart "${CLOUDFLARED_SERVICE_NAME}" && echo_success "Cloudflared service restarted." || echo_error "Failed to restart Cloudflared service."
        else
            echo_error "Cloudflared service is not installed."
        fi
        press_to_continue
        ;;
    6)
        if $service_exists; then
            sudo systemctl status "${CLOUDFLARED_SERVICE_NAME}" --no-pager
        else
            echo_error "Cloudflared service is not installed."
        fi
        press_to_continue
        ;;
    7)
        if $service_exists; then
            echo_info "Displaying logs for ${CLOUDFLARED_SERVICE_NAME}. Press Ctrl+C to exit."
            sudo journalctl -u "${CLOUDFLARED_SERVICE_NAME}" -f --no-pager
        else
            echo_error "Cloudflared service is not installed."
        fi
        # No press_to_continue here as journalctl -f needs to be exited manually
        ;;
    0)
        return
        ;;
    *)
        echo_error "Invalid choice."
        press_to_continue
        ;;
    esac
    # Loop back to cloudflare menu if not returning to main
    if [[ "$sub_choice" != "0" ]]; then
        manage_cloudflare_tunnel
    fi
}

# Placeholder for existing sing-box functions (from original sb.sh)
# These functions MUST be properly defined in the actual script you use.
# For brevity, I'm not re-listing all of them. Ensure they are present.
# --- BEGINNING OF PLACEHOLDER SING-BOX FUNCTIONS ---
install_sing_box() { echo_warning "Function 'install_sing_box' is a placeholder. Implement or merge from original script."; press_to_continue; }
uninstall_sing_box() { echo_warning "Function 'uninstall_sing_box' is a placeholder. Implement or merge from original script."; press_to_continue; }
manage_sing_box_service() { echo_warning "Function 'manage_sing_box_service' is a placeholder. Implement or merge from original script."; press_to_continue; }
manage_sing_box_config() { echo_warning "Function 'manage_sing_box_config' is a placeholder. Implement or merge from original script."; press_to_continue; }
manage_users() { echo_warning "Function 'manage_users' is a placeholder. Implement or merge from original script."; press_to_continue; }
generate_client_config() { echo_warning "Function 'generate_client_config' is a placeholder. Implement or merge from original script."; press_to_continue; }
view_logs() { echo_warning "Function 'view_logs' is a placeholder. Implement or merge from original script."; press_to_continue; }
update_script() {
    echo_info "Checking for script updates..."
    # Example update mechanism - adapt to your actual script source
    local current_script_url="https://raw.githubusercontent.com/szgz/proxy/main/sb.sh" # Example URL
    local temp_script="/tmp/sb_update.sh"
    if curl -Lso "$temp_script" "$current_script_url"; then
        # Basic check: see if downloaded script is different and has a version string
        if grep -q "VERSION=" "$temp_script" && ! cmp -s "$0" "$temp_script"; then
            echo_success "New version found. Replacing current script."
            # Make sure the new script is executable
            chmod +x "$temp_script"
            # Replace current script with the new one
            if mv "$temp_script" "$0"; then
                echo_success "Script updated successfully. Please re-run the script."
                exit 0
            else
                echo_error "Failed to replace the script. Check permissions."
                rm -f "$temp_script"
            fi
        else
            echo_info "You are already using the latest version or the update check failed."
            rm -f "$temp_script"
        fi
    else
        echo_error "Failed to download the update script. Check network or URL."
    fi
    press_to_continue
}
update_sing_box_core() { echo_warning "Function 'update_sing_box_core' is a placeholder. Implement or merge from original script."; press_to_continue; }
# --- END OF PLACEHOLDER SING-BOX FUNCTIONS ---

# Main Menu
main_menu() {
    clear
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${GREEN}"  " sing-box Multi-User Management Script  Version: ${VERSION}"
    echo_color "${BLUE}"   " Script Date: ${SCRIPT_UPDATE_DATE}"
    echo_color "${YELLOW}" "=================================================================="
    echo_color "${CYAN}"   "Current system time: $(date +"%Y-%m-%d %H:%M:%S")"
    echo_line
    echo -e "  ${GREEN}1.${PLAIN} Install Sing-box"
    echo -e "  ${GREEN}2.${PLAIN} Uninstall Sing-box"
    echo -e "  ${GREEN}3.${PLAIN} Manage Sing-box Service"
    echo -e "  ${GREEN}4.${PLAIN} Manage Sing-box Configuration"
    echo -e "  ${GREEN}5.${PLAIN} Manage Users (Placeholder)"
    echo -e "  ${GREEN}6.${PLAIN} Generate Client Configuration / QR Code (Placeholder)"
    echo -e "  ${GREEN}7.${PLAIN} View Sing-box Logs (Placeholder)"
    echo -e "  ${GREEN}8.${PLAIN} Update Sing-box Core (Placeholder)"
    echo -e "  ${GREEN}9.${PLAIN} Update This Script"
    echo -e "  ${GREEN}10.${PLAIN} Manage Cloudflare Tunnel ${RED}(New!)${PLAIN}"
    echo_line
    echo -e "  ${GREEN}0.${PLAIN} Exit Script"
    echo_color "${BLUE}" "------------------------------------------------------------------"
    read -rp "Please enter your choice [0-10]: " choice

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
    10) manage_cloudflare_tunnel ;;
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
clear # Clear screen before starting
echo_info "Initializing Sing-box Management Script..."
check_os
check_dependencies # Crucial step

# Start main menu
main_menu
