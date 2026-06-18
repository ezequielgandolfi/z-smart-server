#!/bin/bash

# Definitions
REPO="ezequielgandolfi/z-smart-server"
INSTALL_DIR=""
CURRENT_VERSION=""
DISTRO_ID=""
DISTRO_NAME=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}"
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
    fi
}

is_linux() {
    [[ "$OSTYPE" == linux-gnu* ]]
}

is_debian_like() {
    [[ "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "ubuntu" ]]
}

user_has_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if groups | grep -qE '(^| )sudo( |$)|(^| )wheel( |$)'; then
        return 0
    fi
    return 1
}

require_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if ! user_has_sudo; then
        log_error "This action requires sudo. Use 'Configure sudo access' first."
        return 1
    fi
    if ! sudo -v; then
        log_error "Could not obtain sudo privileges."
        return 1
    fi
    return 0
}

load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh"
    fi
}

resolve_node_path() {
    load_nvm
    local node_path=""
    node_path=$(command -v node 2>/dev/null)
    if [ -z "$node_path" ]; then
        node_path=$(command -v nodejs 2>/dev/null)
    fi
    if [ -n "$node_path" ]; then
        if command -v readlink &>/dev/null; then
            node_path=$(readlink -f "$node_path" 2>/dev/null || echo "$node_path")
        elif command -v realpath &>/dev/null; then
            node_path=$(realpath "$node_path" 2>/dev/null || echo "$node_path")
        fi
    fi
    echo "$node_path"
}

get_node_version() {
    load_nvm
    local node_path version
    node_path=$(command -v node 2>/dev/null || command -v nodejs 2>/dev/null)
    if [ -z "$node_path" ]; then
        echo ""
        return
    fi
    version=$("$node_path" -v 2>/dev/null | cut -d'v' -f2)
    echo "$version"
}

check_node_compatible() {
    local version
    version=$(get_node_version)
    if [ -z "$version" ]; then return 1; fi
    local major
    major=$(echo "$version" | cut -d'.' -f1)
    if [ "$major" -ge 22 ]; then return 0; else return 1; fi
}

install_node() {
    echo "--------------------------------"
    echo "Install Node.js"
    echo "--------------------------------"
    echo "1) Homebrew (macOS/Linux)"
    echo "2) Standalone (NVM)"
    echo "3) Cancel"
    read -p "Select option: " opt

    case $opt in
        1)
            if command -v brew &>/dev/null; then
                brew install node
            else
                log_error "Homebrew not found."
            fi
            ;;
        2)
            if ! command -v curl &>/dev/null; then
                log_error "curl is required. Install system packages first."
                return
            fi
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            # shellcheck disable=SC1090
            [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
            nvm install 22
            nvm use 22
            nvm alias default 22
            ;;
    esac
}

configure_sudo_access() {
    if user_has_sudo; then
        log_info "User '$USER' already has sudo group membership."
        return
    fi

    if ! is_debian_like; then
        log_warn "Automatic sudo setup is only supported on Debian/Ubuntu."
        return
    fi

    echo "--------------------------------"
    echo "Configure sudo access"
    echo "--------------------------------"
    log_info "On Debian, the default user is often not in the sudo group."
    log_info "This will switch to root (su), install sudo if needed, and add '$USER' to the sudo group."
    read -p "Continue? (y/n): " confirm
    if [[ $confirm != "y" ]]; then return; fi

    su -c "
        set -e
        apt-get update
        if ! command -v sudo >/dev/null 2>&1; then
            apt-get install -y sudo
        fi
        usermod -aG sudo '$USER'
    "

    if [ $? -ne 0 ]; then
        log_error "Failed to configure sudo access."
        return
    fi

    log_info "Sudo access configured for '$USER'."
    log_warn "Group membership takes effect after re-login, or run: newgrp sudo"
    read -p "Re-launch manager with sudo group active now? (y/n): " activate
    if [[ $activate == "y" ]]; then
        log_info "Re-launching..."
        exec sg sudo -c "$0"
    fi
}

install_system_packages() {
    if ! is_debian_like; then
        log_warn "System package installation is only supported on Debian/Ubuntu."
        return
    fi

    if ! require_sudo; then return; fi

    local required_pkgs=(curl unzip ca-certificates)
    local to_install=()

    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            to_install+=("$pkg")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        log_info "All required system packages are already installed."
        return
    fi

    log_info "Installing: ${to_install[*]}"
    sudo apt-get update
    sudo apt-get install -y "${to_install[@]}"
    log_info "System packages installed."
}

detect_installation() {
    if [ -f "package.json" ] && grep -q "z-smart-server" "package.json"; then
        INSTALL_DIR=$(pwd)
        CURRENT_VERSION=$(grep '"version":' package.json | cut -d'"' -f4)
        return 0
    fi
    return 1
}

fetch_latest_release_url() {
    local release_json tag url
    release_json=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
    tag=$(echo "$release_json" | grep '"tag_name":' | head -1 | cut -d'"' -f4)
    url=$(echo "$release_json" | grep '"browser_download_url":' | grep '.zip' | head -1 | cut -d'"' -f4)
    echo "$tag $url"
}

install_app() {
    load_nvm

    if ! command -v npm &>/dev/null; then
        log_error "npm not found. Install Node.js first."
        return
    fi

    read -p "Install location (default: $(pwd)): " target
    target=${target:-$(pwd)}
    mkdir -p "$target"

    log_info "Fetching release info..."
    read -r tag url <<< "$(fetch_latest_release_url)"

    if [ -z "$url" ] || [ "$url" == "null" ]; then
        log_error "Could not find release asset."
        return
    fi

    log_info "Downloading $tag from $url..."
    cd "$target" || return
    curl -L -o release.zip "$url"

    unzip -o release.zip
    if [ -d "z-smart-server" ]; then
        cp -R z-smart-server/* .
        rm -rf z-smart-server
    fi
    rm release.zip

    log_info "Installing dependencies..."
    npm install --production

    log_info "Installed successfully to $target"
    INSTALL_DIR="$target"
    CURRENT_VERSION="${tag#v}"
}

update_app() {
    load_nvm

    log_info "Updating app in $INSTALL_DIR..."
    cd "$INSTALL_DIR" || return

    read -r tag url <<< "$(fetch_latest_release_url)"
    local new_ver="${tag#v}"

    if [ "$new_ver" == "$CURRENT_VERSION" ]; then
        log_info "Already up to date."
        read -p "Reinstall anyway? (y/n): " confirm
        if [[ $confirm != "y" ]]; then return; fi
    fi

    log_info "Downloading update $tag..."
    curl -L -o release.zip "$url"
    unzip -o release.zip

    if [ -d "z-smart-server" ]; then
        cp -R z-smart-server/* .
        rm -rf z-smart-server
    fi
    rm release.zip

    log_info "Updating dependencies..."
    npm install --production

    log_info "Running migrations..."
    local node_path
    node_path=$(resolve_node_path)
    if [ -f "scripts/migrate-runner.js" ] && [ -n "$node_path" ]; then
        "$node_path" scripts/migrate-runner.js "migrations" "$CURRENT_VERSION" "$new_ver"
    else
        log_warn "Migration runner not found or Node.js not available."
    fi

    CURRENT_VERSION="$new_ver"
    log_info "Update complete."
}

uninstall_app() {
    read -p "Uninstall from $INSTALL_DIR? (y/n): " confirm
    if [[ $confirm == "y" ]]; then
        rm -rf "$INSTALL_DIR"/*
        log_info "Files removed."
        INSTALL_DIR=""
        CURRENT_VERSION=""
    fi
}

restart_app() {
    if ! is_linux; then
        log_warn "Only supported on Linux."
        return
    fi
    if ! require_sudo; then return; fi

    log_info "Restarting Z Smart Server..."
    if sudo systemctl restart z-smart-server; then
        log_info "Restarted successfully."
    else
        log_error "Failed to restart service."
    fi
}

manage_service() {
    if ! is_linux; then
        log_warn "Only supported on Linux."
        return
    fi
    if ! require_sudo; then return; fi

    local node_path
    node_path=$(resolve_node_path)
    if [ -z "$node_path" ] || [ ! -x "$node_path" ]; then
        log_error "Node.js not found. Install Node.js first."
        return
    fi

    echo "1) Enable Run on Startup"
    echo "2) Disable Run on Startup"
    read -p "Choice: " opt

    local service_file="/etc/systemd/system/z-smart-server.service"

    if [ "$opt" == "1" ]; then
        read -p "Service user (blank for current user '$USER'): " service_user
        service_user=${service_user:-$USER}

        if ! id "$service_user" &>/dev/null; then
            read -p "User '$service_user' does not exist. Create it? (y/n): " create_confirm
            if [[ $create_confirm != "y" ]]; then return; fi
            sudo adduser --disabled-password --gecos "Z Smart Server" "$service_user"
        fi

        if [ "$service_user" != "$USER" ] && [[ "$INSTALL_DIR" == "$HOME"/* ]]; then
            log_warn "Install directory is under your home folder. Ensure '$service_user' can read $INSTALL_DIR."
        fi

        log_info "Using Node.js at: $node_path"

        sudo bash -c "cat > $service_file" <<EOF
[Unit]
Description=Z Smart Server
After=network.target

[Service]
ExecStart=$node_path $INSTALL_DIR/src/server.js
WorkingDirectory=$INSTALL_DIR
Restart=always
User=$service_user
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable z-smart-server
        sudo systemctl start z-smart-server
        log_info "Service enabled (user: $service_user)."
    elif [ "$opt" == "2" ]; then
        sudo systemctl stop z-smart-server
        sudo systemctl disable z-smart-server
        sudo rm -f "$service_file"
        sudo systemctl daemon-reload
        log_info "Service disabled."
    fi
}

detect_distro

while true; do
    detect_installation
    echo ""
    echo "=============================="
    echo " Z Smart Server Manager"
    echo "=============================="
    if [ -n "$DISTRO_NAME" ]; then
        echo "System: $DISTRO_NAME"
    fi
    if [ -n "$INSTALL_DIR" ]; then
        echo "Detected installation at: $INSTALL_DIR (v$CURRENT_VERSION)"
    else
        echo "No installation detected in current directory."
    fi
    if is_linux && is_debian_like && ! user_has_sudo; then
        log_warn "Current user is not in the sudo group."
    fi

    echo "------------------------------"
    i=1

    if is_linux && is_debian_like && ! user_has_sudo; then
        echo "$i) Configure sudo access"
        opt_sudo=$i
        ((i++))
    else
        opt_sudo=-1
    fi

    if is_linux && is_debian_like; then
        echo "$i) Install system packages"
        opt_syspkgs=$i
        ((i++))
    else
        opt_syspkgs=-1
    fi

    if ! check_node_compatible; then
        echo "$i) Install Node.js (Required)"
        opt_node=$i
        ((i++))
    else
        opt_node=-1
    fi

    if [ -z "$INSTALL_DIR" ]; then
        echo "$i) Install Z Smart Server"
        opt_install=$i
        ((i++))
        opt_update=-1
        opt_uninstall=-1
    else
        echo "$i) Update Z Smart Server"
        opt_update=$i
        ((i++))
        echo "$i) Uninstall Z Smart Server"
        opt_uninstall=$i
        ((i++))
        opt_install=-1
    fi

    if [ -n "$INSTALL_DIR" ] && is_linux; then
        echo "$i) Startup Settings"
        opt_service=$i
        ((i++))
    else
        opt_service=-1
    fi

    if [ -n "$INSTALL_DIR" ] && is_linux; then
        echo "$i) Restart App"
        opt_restart=$i
        ((i++))
    else
        opt_restart=-1
    fi

    echo "$i) Exit"
    opt_exit=$i

    read -p "Select option: " choice

    if [ "$choice" == "$opt_sudo" ]; then configure_sudo_access
    elif [ "$choice" == "$opt_syspkgs" ]; then install_system_packages
    elif [ "$choice" == "$opt_node" ]; then install_node
    elif [ "$choice" == "$opt_install" ]; then install_app
    elif [ "$choice" == "$opt_update" ]; then update_app
    elif [ "$choice" == "$opt_uninstall" ]; then uninstall_app
    elif [ "$choice" == "$opt_service" ]; then manage_service
    elif [ "$choice" == "$opt_restart" ]; then restart_app
    elif [ "$choice" == "$opt_exit" ]; then break
    else echo "Invalid choice."; fi
done
