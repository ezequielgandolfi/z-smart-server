#!/bin/bash

# Definitions
REPO="ezequielgandolfi/z-smart-server"
INSTALL_DIR=""
CURRENT_VERSION=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

get_node_version() {
    if command -v node &> /dev/null; then
        node -v | cut -d'v' -f2
    else
        echo ""
    fi
}

check_node_compatible() {
    local version=$(get_node_version)
    if [ -z "$version" ]; then return 1; fi
    local major=$(echo "$version" | cut -d'.' -f1)
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
            if command -v brew &> /dev/null; then
                brew install node
            else
                log_error "Homebrew not found."
            fi
            ;;
        2)
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install 22
            nvm use 22
            nvm alias default 22
            ;;
    esac
}

detect_installation() {
    # Check current directory
    if [ -f "package.json" ] && grep -q "z-smart-server" "package.json"; then
        INSTALL_DIR=$(pwd)
        CURRENT_VERSION=$(grep '"version":' package.json | cut -d'"' -f4)
        return 0
    fi
    # Search common paths? No, keep simple.
    return 1
}

fetch_latest_release_url() {
    # Returns "TAG_NAME DOWNLOAD_URL"
    # Using python or grep/sed/awk to parse JSON if jq not available
    # Assuming minimal system, grep/sed is safer.
    
    local release_json=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
    local tag=$(echo "$release_json" | grep '"tag_name":' | head -1 | cut -d'"' -f4)
    # Finding the browser_download_url for the zip file
    # Assuming it's the first asset or matching zip
    local url=$(echo "$release_json" | grep '"browser_download_url":' | grep '.zip' | head -1 | cut -d'"' -f4)
    
    echo "$tag $url"
}

install_app() {
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
    # Cleanup zip structure
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
    if [ -f "scripts/migrate-runner.js" ]; then
        node scripts/migrate-runner.js "migrations" "$CURRENT_VERSION" "$new_ver"
    else
        log_warn "Migration runner not found."
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

manage_service() {
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        log_warn "Only supported on Linux."
        return
    fi
    
    echo "1) Enable Run on Startup"
    echo "2) Disable Run on Startup"
    read -p "Choice: " opt
    
    local service_file="/etc/systemd/system/z-smart-server.service"
    
    if [ "$opt" == "1" ]; then
        sudo bash -c "cat > $service_file" <<EOF
[Unit]
Description=Z Smart Server
After=network.target

[Service]
ExecStart=$(which node) $INSTALL_DIR/src/server.js
WorkingDirectory=$INSTALL_DIR
Restart=always
User=$USER
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable z-smart-server
        sudo systemctl start z-smart-server
        log_info "Service enabled."
    elif [ "$opt" == "2" ]; then
        sudo systemctl stop z-smart-server
        sudo systemctl disable z-smart-server
        sudo rm "$service_file"
        sudo systemctl daemon-reload
        log_info "Service disabled."
    fi
}

while true; do
    detect_installation
    echo ""
    echo "=============================="
    echo " Z Smart Server Manager"
    echo "=============================="
    if [ -n "$INSTALL_DIR" ]; then
        echo "Detected installation at: $INSTALL_DIR (v$CURRENT_VERSION)"
    else
        echo "No installation detected in current directory."
    fi
    
    echo "------------------------------"
    i=1
    
    # Option 1: Install Node
    if ! check_node_compatible; then
        echo "$i) Install Node.js (Required)"
        opt_node=$i
        ((i++))
    else
        opt_node=-1
    fi
    
    # Option 2: Install/Update/Uninstall
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
    
    # Option 3: Service
    if [ -n "$INSTALL_DIR" ] && [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "$i) Startup Settings"
        opt_service=$i
        ((i++))
    else
        opt_service=-1
    fi
    
    echo "$i) Exit"
    opt_exit=$i
    
    read -p "Select option: " choice
    
    if [ "$choice" == "$opt_node" ]; then install_node;
    elif [ "$choice" == "$opt_install" ]; then install_app;
    elif [ "$choice" == "$opt_update" ]; then update_app;
    elif [ "$choice" == "$opt_uninstall" ]; then uninstall_app;
    elif [ "$choice" == "$opt_service" ]; then manage_service;
    elif [ "$choice" == "$opt_exit" ]; then break;
    else echo "Invalid choice."; fi
done
