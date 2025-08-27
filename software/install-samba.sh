#!/usr/bin/env bash
# =============================================================================
# Samba LXC Container Setup (Proxmox VE)
# - Creates Debian 12 unprivileged LXC
# - Bind-mounts host media path into the container
# - Installs Samba inside the container
# - Configures an SMB share (RW), forcing ops as root inside CT
# - Does NOT change host ownership/permissions
# - Prints container ROOT credentials and SMB details
# =============================================================================
set -o errexit -o nounset -o pipefail

# ---------- CONFIG ----------
CT_ID="112"
CT_HOSTNAME="samba"
CT_PASSWORD=""                 # Will prompt if empty; this is the container *root* password
CT_CORES="1"
CT_MEMORY="512"
CT_DISK="4"
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
UNPRIVILEGED="1"

OS_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"

HOST_MEDIA="/mnt/bjorne"       # Existing path on Proxmox host
CT_MEDIA="/media/bjorne"       # Path inside container

SHARE_NAME="bjorne"
READ_ONLY="no"
GUEST_OK="no"
SMB_USER="nasuser"
SMB_PASS="${SMB_PASS:-}"       # Set via env or will prompt

# ---------- Helpers ----------
Y='\033[1;33m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
info(){ echo -e "${Y}[INFO]${N} $*"; }
ok(){   echo -e "${G}[OK]${N} $*"; }
err(){  echo -e "${R}[ERROR]${N} $*"; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || err "Run as root on the Proxmox host."; [[ -f /etc/pve/.version ]] || err "Run on a Proxmox VE host."; }
ct_exec(){ pct exec "$CT_ID" -- bash -lc "$*"; }

# ---------- Flow ----------
require_root
pct status "$CT_ID" &>/dev/null && err "CT $CT_ID already exists."

# Template
info "Ensuring template..."
pveam update
pveam list "$TEMPLATE_STORAGE" | grep -q "$OS_TEMPLATE" || pveam download "$TEMPLATE_STORAGE" "$OS_TEMPLATE"
ok "Template ready."

# Prompt for CT root password if empty
if [[ -z "$CT_PASSWORD" ]]; then
  read -s -p "Enter ROOT password for new container: " CT_PASSWORD; echo
  [[ ${#CT_PASSWORD} -ge 6 ]] || err "Container root password must be at least 6 characters."
fi

# Create CT
info "Creating LXC $CT_ID ($CT_HOSTNAME)..."
pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --password "$CT_PASSWORD" \
  --cores "$CT_CORES" \
  --memory "$CT_MEMORY" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --features "nesting=1" \
  --unprivileged "$UNPRIVILEGED" \
  --onboot 1
ok "Container created."

# Bind mount
[[ -d "$HOST_MEDIA" ]] || err "Host path $HOST_MEDIA does not exist."
info "Binding $HOST_MEDIA -> $CT_MEDIA"
pct set "$CT_ID" -mp0 "$HOST_MEDIA,mp=$CT_MEDIA,backup=0"
ok "Bind mount added."

# Start
info "Starting container..."
pct start "$CT_ID"; sleep 5
ok "Container started."

# Install Samba
info "Installing Samba inside CT..."
ct_exec "apt-get update -y && apt-get upgrade -y"
ct_exec "apt-get install -y samba"
ok "Samba installed."

# Create SMB user (unless guest)
if [[ "$GUEST_OK" != "yes" ]]; then
  info "Creating Samba system user '$SMB_USER' (no shell, no home)..."
  ct_exec "id '$SMB_USER' &>/dev/null || useradd -M -s /usr/sbin/nologin '$SMB_USER'"
  if [[ -z "$SMB_PASS" ]]; then
    read -s -p "Enter Samba password for $SMB_USER: " SMB_PASS; echo
    [[ ${#SMB_PASS} -ge 6 ]] || err "Samba password must be at least 6 characters."
  fi
  info "Setting Samba password..."
  ct_exec "printf '%s\n%s\n' '$SMB_PASS' '$SMB_PASS' | smbpasswd -s -a '$SMB_USER' >/dev/null"
fi

# Configure share (force ops as root inside CT; no host chown)
info "Configuring share..."
ct_exec "mkdir -p '$CT_MEDIA'"
ct_exec "[ -f /etc/samba/smb.conf.bak ] || cp /etc/samba/smb.conf /etc/samba/smb.conf.bak"
ct_exec "sed -i '/^\\[$SHARE_NAME\\]\$/,/^\\s*\$/d' /etc/samba/smb.conf"
ct_exec "cat >> /etc/samba/smb.conf <<'EOF'

[$SHARE_NAME]
   path = $CT_MEDIA
   browseable = yes
   read only = $READ_ONLY
   guest ok = $GUEST_OK
   valid users = $SMB_USER
   create mask = 0664
   directory mask = 0775
   force user = root
   force group = root
EOF"
ct_exec "systemctl enable smbd >/dev/null && systemctl restart smbd"
ct_exec "systemctl enable nmbd >/dev/null || true; systemctl restart nmbd || true"
ok "Share ready."

# Output
CT_IP="$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')"
echo
ok "=== SAMBA LXC SETUP COMPLETE ==="
echo "Container ID:     $CT_ID"
echo "Hostname:         $CT_HOSTNAME"
echo "IP Address:       ${CT_IP:-<unknown>}"
echo "Root username:    root"
echo "Root password:    ${CT_PASSWORD}"
echo
echo "Bind mount:       Host $HOST_MEDIA  ->  CT $CT_MEDIA"
echo
echo "SMB Share:        $SHARE_NAME"
echo "Read-only:        $READ_ONLY"
echo "Guest access:     $GUEST_OK"
if [[ "$GUEST_OK" != "yes" ]]; then
  echo "SMB username:     $SMB_USER"
  echo "SMB password:     ${SMB_PASS:-<prompted>}"
else
  echo "SMB credentials:  Not required (guest)"
fi
echo
echo "Connect examples:"
echo "  macOS/Linux:    smbclient //$CT_IP/$SHARE_NAME -U $SMB_USER"
echo "  iPad Files:     Server: $CT_IP, Share: $SHARE_NAME, User: $SMB_USER"
echo
echo "Admin access:"
echo "  From Proxmox host:  pct enter $CT_ID    # root shell (no password)"
