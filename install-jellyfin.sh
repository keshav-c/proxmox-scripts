#!/usr/bin/env bash
# =============================================================================
# Jellyfin LXC Container Setup Script for Proxmox VE
# Simple, readable automation with extensive comments
# =============================================================================

# Exit on any error to prevent partial installations
set -o errexit
set -o nounset
set -o pipefail

# ============================================
# CONFIGURATION - Modify these for your setup
# ============================================
# Container settings
CT_ID="111"                 # Container ID (will prompt if empty)
CT_HOSTNAME="jellyfin"      # Name for your Jellyfin server
CT_PASSWORD=""              # Root password (will prompt if empty)
CT_CORES="2"                # CPU cores to allocate
CT_MEMORY="4096"            # RAM in MB (4GB recommended)
CT_DISK="32"                # System disk size in GB
CT_STORAGE="local-lvm"      # Where to store container disk
CT_BRIDGE="vmbr0"           # Network bridge to use

# USB mount settings
USB_DEVICE="/dev/sdb1"      # Your USB drive partition
USB_MOUNT="/mnt/bjorne"  # Where to mount on host
MEDIA_PATH="/media/bjorne"     # Path inside container

# Template to use (Debian 12 recommended)
OS_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ============================================
# HELPER FUNCTIONS
# ============================================

# Display colored messages
msg_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running on Proxmox
check_proxmox() {
    if [[ ! -f /etc/pve/.version ]]; then
        msg_error "This script must be run on a Proxmox VE host"
    fi
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
    fi
    msg_ok "Running on Proxmox VE"
}

# Get container ID from user
get_container_id() {
    if [[ -z "$CT_ID" ]]; then
        read -p "Enter Container ID (100-999): " CT_ID
        # Validate the ID
        if [[ ! "$CT_ID" =~ ^[0-9]+$ ]] || [[ "$CT_ID" -lt 100 ]]; then
            msg_error "Invalid Container ID"
        fi
    fi
    # Check if ID already exists
    if pct status "$CT_ID" &> /dev/null; then
        msg_error "Container $CT_ID already exists"
    fi
}

# Get root password for container
get_password() {
    if [[ -z "$CT_PASSWORD" ]]; then
        read -s -p "Enter root password for container: " CT_PASSWORD
        echo
        if [[ ${#CT_PASSWORD} -lt 6 ]]; then
            msg_error "Password must be at least 6 characters"
        fi
    fi
}

# ============================================
# MAIN SETUP FUNCTIONS
# ============================================

# Download OS template if needed
download_template() {
    msg_info "Checking OS template..."
    
    # Update template list
    pveam update
    
    # Download if not present
    if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$OS_TEMPLATE"; then
        msg_info "Downloading $OS_TEMPLATE"
        pveam download "$TEMPLATE_STORAGE" "$OS_TEMPLATE"
    fi
    msg_ok "Template ready"
}

# Create the LXC container
create_container() {
    msg_info "Creating LXC container $CT_ID"
    
    # Create container with our settings
    pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}" \
        --hostname "$CT_HOSTNAME" \
        --password "$CT_PASSWORD" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --rootfs "${CT_STORAGE}:${CT_DISK}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
        --features "nesting=1" \
        --unprivileged 1 \
        --onboot 1
    
    msg_ok "Container created"
}

# Mount USB drive on host
setup_usb_mount() {
    msg_info "Setting up USB drive mount"
    
    # Create mount point
    mkdir -p "$USB_MOUNT"
    
    # Get UUID for persistent mounting
    USB_UUID=$(blkid -s UUID -o value "$USB_DEVICE")
    
    if [[ -z "$USB_UUID" ]]; then
        msg_error "Could not find USB device $USB_DEVICE"
    fi
    
    # Check filesystem type
    FS_TYPE=$(blkid -s TYPE -o value "$USB_DEVICE")
    msg_info "Detected filesystem: $FS_TYPE"
    
    # Add to fstab if not already there
    if ! grep -q "$USB_UUID" /etc/fstab; then
        if [[ "$FS_TYPE" == "ntfs" ]]; then
            # Install NTFS support
            apt-get update && apt-get install -y ntfs-3g
            echo "UUID=$USB_UUID $USB_MOUNT ntfs-3g defaults,nofail 0 2" >> /etc/fstab
        elif [[ "$FS_TYPE" == "exfat" ]]; then
            # Install exFAT support
            msg_info "Installing exFAT support"
            apt-get update && apt-get install -y exfatprogs exfat-fuse
            # For exFAT, we need specific mount options for permissions
            echo "UUID=$USB_UUID $USB_MOUNT exfat defaults,nofail,uid=100000,gid=100000,umask=000 0 0" >> /etc/fstab
        else
            echo "UUID=$USB_UUID $USB_MOUNT $FS_TYPE defaults,nofail 0 2" >> /etc/fstab
        fi
        msg_ok "Added USB mount to fstab"
    fi
    
    # Mount the drive
    mount -a
    msg_ok "USB drive mounted at $USB_MOUNT"
}

# Add mount point to container
add_container_mount() {
    msg_info "Adding media mount to container"
    
    # Add bind mount to container config
    echo "mp0: $USB_MOUNT,mp=$MEDIA_PATH,backup=0" >> "/etc/pve/lxc/${CT_ID}.conf"
    
    msg_ok "Mount point configured"
}

# Start container and install Jellyfin
install_jellyfin() {
    msg_info "Starting container"
    pct start "$CT_ID"
    
    # Wait for container to be ready
    sleep 5
    
    msg_info "Installing Jellyfin"
    
    # Update system
    pct exec "$CT_ID" -- apt-get update
    pct exec "$CT_ID" -- apt-get upgrade -y
    
    # Install dependencies
    pct exec "$CT_ID" -- apt-get install -y curl gnupg
    
    # Run official Jellyfin install script
    pct exec "$CT_ID" -- bash -c "curl https://repo.jellyfin.org/install-debuntu.sh | bash"
    
    # Enable and start service
    pct exec "$CT_ID" -- systemctl enable jellyfin
    pct exec "$CT_ID" -- systemctl start jellyfin
    
    msg_ok "Jellyfin installed and running"
}

# Fix permissions for unprivileged container
fix_permissions() {
    msg_info "Configuring permissions"
    
    # Get Jellyfin user ID in container (usually 100-999)
    JELLYFIN_UID=$(pct exec "$CT_ID" -- id -u jellyfin)
    JELLYFIN_GID=$(pct exec "$CT_ID" -- id -g jellyfin)
    
    # Calculate mapped IDs (add 100000 for unprivileged)
    HOST_UID=$((100000 + JELLYFIN_UID))
    HOST_GID=$((100000 + JELLYFIN_GID))
    
    msg_info "Setting ownership to $HOST_UID:$HOST_GID on host"
    chown -R "$HOST_UID:$HOST_GID" "$USB_MOUNT"
    
    msg_ok "Permissions configured"
}

# Display completion information
show_completion() {
    # Get container IP
    CONTAINER_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
    
    echo
    msg_ok "=== JELLYFIN SETUP COMPLETE ==="
    echo
    echo "Container ID:     $CT_ID"
    echo "IP Address:       $CONTAINER_IP"
    echo "Web Interface:    http://$CONTAINER_IP:8096"
    echo "Media Location:   $MEDIA_PATH (in container)"
    echo "USB Mount:        $USB_MOUNT (on host)"
    echo
    echo "Next steps:"
    echo "1. Open http://$CONTAINER_IP:8096 in your browser"
    echo "2. Complete the Jellyfin setup wizard"
    echo "3. Add media library pointing to $MEDIA_PATH"
    echo
}

# ============================================
# MAIN EXECUTION
# ============================================

main() {
    echo "==================================="
    echo "Jellyfin LXC Setup for Proxmox VE"
    echo "==================================="
    echo
    
    # Run setup steps in order
    check_proxmox
    get_container_id
    get_password
    download_template
    create_container
    setup_usb_mount
    add_container_mount
    install_jellyfin
    fix_permissions
    show_completion
}

# Run the main function
main