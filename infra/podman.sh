#!/bin/bash
# This script identifies the Debian version and installs the latest Podman version with Quadlet.
# The script is idempotent - it will skip steps that are already completed.
# 
# Steps:
# 1. Check if PODMAN_BIN is already configured in creds/node.conf - if yes, exit.
# 2. Check if Podman is installed - if yes, skip to verification at the end.
# 3. If Podman is not installed - check Docker (ask user if they want to use it).
# 4. If not exited earlier - check OS version and install Podman with Quadlet support.
# 5. Verify installation by running Alpine container and creating test Quadlet service, then clean up.

set -euo pipefail

# Source common functions and variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"

echo "=== Podman Installation ==="
echo ""

# Step 1: Check if PODMAN_BIN is already configured
PODMAN_BIN=$(get_conf_value "PODMAN_BIN")
if [[ -n "$PODMAN_BIN" ]]; then
    echo "Already configured to use $PODMAN_BIN"
    exit 0
fi

# Step 2: Check if Podman is installed
echo "Checking if Podman is installed..."
if command -v podman >/dev/null 2>&1; then
    echo "Podman is already installed."
    PODMAN_VERSION=$(podman --version 2>/dev/null || echo "unknown")
    echo "Version: $PODMAN_VERSION"
    echo "Proceeding to verification..."
    echo ""
else
    echo "Podman is not installed."
    
    # Step 3: Check Docker (ask user if they want to use it)
    if command -v docker >/dev/null 2>&1; then
        echo "Docker is found."
        read -p "Do you want to use Docker instead of Podman? [y/N]: " USE_DOCKER
        USE_DOCKER="${USE_DOCKER:-N}"
        
        if [[ "${USE_DOCKER,,}" == "y" ]] || [[ "${USE_DOCKER,,}" == "yes" ]]; then
            echo ""
            echo "Verifying Docker works..."
            if docker ps -a >/dev/null 2>&1; then
                echo "✓ Docker is working"
                set_conf_value "PODMAN_BIN" "docker"
                echo ""
                echo "Docker will be used instead of Podman."
                exit 0
            else
                echo "Error: Docker is installed but not working properly"
                echo "Please check Docker installation and permissions"
                exit 1
            fi
        fi
    fi
    
    # Step 4: Detect OS version and install Podman
    echo ""
    echo "Detecting OS version..."
    if [[ ! -f /etc/os-release ]]; then
        echo "Error: Cannot detect OS version (/etc/os-release not found)"
        exit 1
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "debian" ]]; then
        echo "Error: This script only supports Debian. Detected OS: $ID"
        exit 1
    fi
    
    DEBIAN_VERSION="${VERSION_CODENAME:-}"
    if [[ -z "$DEBIAN_VERSION" ]]; then
        # Try to get version from VERSION_ID
        if [[ -n "${VERSION_ID:-}" ]]; then
            case "$VERSION_ID" in
                "12")
                    DEBIAN_VERSION="bookworm"
                    ;;
                "13")
                    DEBIAN_VERSION="trixie"
                    ;;
                *)
                    echo "Error: Unsupported Debian version: $VERSION_ID"
                    echo "Only Debian Bookworm (12) and Trixie (13) are supported for now"
                    exit 1
                    ;;
            esac
        else
            echo "Error: Cannot determine Debian version"
            exit 1
        fi
    fi
    
    if [[ "$DEBIAN_VERSION" != "bookworm" ]] && [[ "$DEBIAN_VERSION" != "trixie" ]]; then
        echo "Error: Unsupported Debian version: $DEBIAN_VERSION"
        echo "Only Debian Bookworm and Trixie are supported for now"
        exit 1
    fi
    
    echo "✓ Detected Debian $DEBIAN_VERSION"
    
    # Install Podman with Quadlet support
    echo ""
    echo "Installing Podman with Quadlet support..."
    
    # Update package lists
    echo "Updating package lists..."
    apt-get update -qq
    
    # Install prerequisites
    echo "Installing prerequisites..."
    apt-get install -y -qq \
        curl \
        wget \
        gnupg \
        ca-certificates \
        >/dev/null 2>&1
    
    # Ask user which version to install
    echo ""
    echo "Choose Podman installation source:"
    echo "1) Stable version from Debian repositories (recommended)"
    echo "2) Latest version from Debian testing (forky) - includes Quadlet subcommands"
    read -p "Choose option [1-2] (default: 1): " INSTALL_OPTION
    INSTALL_OPTION="${INSTALL_OPTION:-1}"
    
    if [[ "$INSTALL_OPTION" == "2" ]]; then
        # Install from Debian testing (forky)
        echo "Installing Podman from Debian testing (forky)..."
        
        # Add Debian testing repository with low priority
        if [[ ! -f /etc/apt/sources.list.d/debian-testing.list ]]; then
            echo "deb http://deb.debian.org/debian forky main" > /etc/apt/sources.list.d/debian-testing.list
        fi
        
        # Set low priority for testing repository
        if [[ ! -f /etc/apt/preferences.d/podman-testing.pref ]]; then
            cat > /etc/apt/preferences.d/podman-testing.pref <<EOF
Package: *
Pin: release n=forky
Pin-Priority: 100
EOF
        fi
        
        apt-get update -qq
        
        # Install Podman from testing
        if apt-get install -y -t forky podman podman-compose >/dev/null 2>&1; then
            echo "✓ Podman installed from Debian testing (forky)"
        else
            echo "Error: Failed to install Podman from Debian testing"
            exit 1
        fi
    else
        # Install from stable Debian repositories
        echo "Installing Podman from Debian stable repositories..."
        if apt-get install -y -qq podman podman-compose >/dev/null 2>&1; then
            echo "✓ Podman installed from Debian repositories"
        else
            echo "Error: Failed to install Podman from Debian repositories"
            exit 1
        fi
    fi
    
    # Check if quadlet package exists separately (for newer versions)
    if apt-cache search podman-quadlet 2>/dev/null | grep -q podman-quadlet; then
        apt-get install -y -qq podman-quadlet >/dev/null 2>&1 || true
    fi
    
    echo "✓ Podman installed"
fi

# Step 5: Verify installation (for both existing and newly installed Podman)
echo ""
echo "Verifying Podman installation..."

# Check version
PODMAN_VERSION=$(podman --version 2>/dev/null || echo "unknown")
echo "Installed version: $PODMAN_VERSION"

# Test basic functionality
echo "Testing Podman functionality..."
if ! podman ps -a >/dev/null 2>&1; then
    echo "Error: Podman is installed but not working"
    exit 1
fi
echo "✓ Podman is working"

# Test container run
echo "Testing container run..."
if podman run --rm docker.io/library/alpine:latest echo "Podman test successful" >/dev/null 2>&1; then
    echo "✓ Container run test successful"
else
    echo "⚠ Warning: Container run test failed"
    exit 1
fi

# Test Quadlet (if systemd is available)
if command -v systemctl >/dev/null 2>&1; then
    echo "Testing Quadlet support..."
    TEST_SERVICE_NAME="test-quadlet"
    TEST_SERVICE_FILE="/etc/containers/systemd/${TEST_SERVICE_NAME}.container"
    
    # Create test Quadlet service file
    mkdir -p /etc/containers/systemd
    cat > "$TEST_SERVICE_FILE" <<'EOF'
[Unit]
Description=Test Podman Quadlet Service

[Container]
Image=docker.io/library/nginx:latest
AutoUpdate=never

[Service]
Restart=no
EOF
    
    # Reload systemd to pick up the new service
    systemctl daemon-reload
    
    # Check if service is recognized
    if systemctl list-unit-files | grep -q "${TEST_SERVICE_NAME}"; then
        echo "✓ Quadlet service recognized by systemd"
        
        # Try to enable and start the service
        if systemctl start "${TEST_SERVICE_NAME}.service" >/dev/null 2>&1; then
            # Check service status
            if systemctl status "${TEST_SERVICE_NAME}.service" >/dev/null 2>&1; then
                echo "✓ Quadlet service started successfully"
                QUADLET_WORKS=true
            else
                echo "⚠ Warning: Quadlet service failed to start"
            fi
        else
            echo "⚠ Warning: Failed to enable Quadlet service"
        fi
    else
        echo "⚠ Warning: Quadlet service not recognized by systemd"
    fi
    
    # Cleanup: Stop and disable test service
    systemctl stop "${TEST_SERVICE_NAME}.service" 2>/dev/null || true
    
    # Cleanup: Find and remove test service files
    for quadlet_dir in /etc/containers/systemd /usr/share/containers/systemd; do
        if [[ -d "$quadlet_dir" ]]; then
            find "$quadlet_dir" -name "*${TEST_SERVICE_NAME}*" -type f -exec rm -f {} \; 2>/dev/null || true
        fi
    done
    
    # Reload systemd after cleanup
    systemctl daemon-reload 2>/dev/null || true
    
    # Reset failed state
    systemctl reset-failed "${TEST_SERVICE_NAME}.service" 2>/dev/null || true
    
    # Verify service is removed
    if systemctl list-unit-files | grep -q "${TEST_SERVICE_NAME}"; then
        echo "⚠ Warning: Test service still present after cleanup"
    else
        echo "✓ Test service cleaned up successfully"
    fi
    
    if [[ "${QUADLET_WORKS:-false}" == "true" ]]; then
        echo "✓ Quadlet support verified"
    else
        echo "⚠ Warning: Could not verify Quadlet functionality"
        echo "Quadlet may still work, but verification failed"
    fi
else
    echo "⚠ systemd not available, skipping Quadlet test"
fi

# Save to node.conf
set_conf_value "PODMAN_BIN" "podman"
echo ""
echo "Podman installation completed successfully!"
