#!/usr/bin/env bash
# =============================================================================
# Minimal Samba setup for serving files over SMB on Debian/Proxmox
# - Installs Samba
# - Creates a user with no shell
# - Exposes a share (path/name via variables), read-only or read-write
# - Prints connection info (IP, port, share, username, password)
# =============================================================================
set -o errexit -o nounset -o pipefail

# ---------------------------
# CONFIG — tweak as you like
# ---------------------------
SHARE_NAME="bjorne"              # What the share will be called on the network
SHARE_PATH="/mnt/bjorne"         # Folder to serve
SMB_USER="nasuser"               # Samba login username
SMB_PASS=""                      # Leave empty to be prompted
READ_ONLY="no"                   # "yes" or "no"
GUEST_OK="no"                    # "yes" (no credentials) or "no"

# ---------------------------
# Helpers
# ---------------------------
info(){ echo -e "\e[33m[INFO]\e[0m $*"; }
ok(){   echo -e "\e[32m[OK]\e[0m $*"; }
err(){  echo -e "\e[31m[ERROR]\e[0m $*" ; exit 1; }

require_root(){
  [[ $EUID -eq 0 ]] || err "Run as root"
}

detect_ip(){
  # Pick the first non-loopback IPv4 address
  ip -4 -o addr show | awk '!/ lo /{print $4}' | cut -d/ -f1 | head -n1
}

# ---------------------------
# Main
# ---------------------------
require_root

info "Updating apt and installing samba…"
apt-get update -y
apt-get install -y samba

# Ensure share path exists
if [[ ! -d "$SHARE_PATH" ]]; then
  info "Creating $SHARE_PATH"
  mkdir -p "$SHARE_PATH"
fi

# Backup smb.conf once
if [[ ! -f /etc/samba/smb.conf.bak ]]; then
  cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
  ok "Backed up /etc/samba/smb.conf to .bak"
fi

# Create user (only if not guest & user doesn't exist)
if [[ "$GUEST_OK" != "yes" ]]; then
  if ! id "$SMB_USER" &>/dev/null; then
    info "Creating system user $SMB_USER (no shell, no home)…"
    useradd -M -s /usr/sbin/nologin "$SMB_USER"
  fi
  if [[ -z "$SMB_PASS" ]]; then
      read -s -p "Enter Samba password for $SMB_USER: " SMB_PASS
      echo
      if [[ ${#SMB_PASS} -lt 6 ]]; then
          err "Password must be at least 6 characters"
      fi
  fi
  info "Setting Samba password for $SMB_USER"
  printf "%s\n%s\n" "$SMB_PASS" "$SMB_PASS" | smbpasswd -s -a "$SMB_USER" >/dev/null
fi

# Ensure share path perms/ownership for RW usage
chmod -R 0775 "$SHARE_PATH"
chown -R "$SMB_USER:$SMB_USER" "$SHARE_PATH"
chmod g+s "$SHARE_PATH"

# Write (or replace) the share definition
info "Configuring Samba share [$SHARE_NAME] -> $SHARE_PATH"
# Remove any existing block with same name
sed -i "/^\[$SHARE_NAME\]$/,/^\s*$/d" /etc/samba/smb.conf

cat >> /etc/samba/smb.conf <<EOF

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   read only = $READ_ONLY
   guest ok = $GUEST_OK
   valid users = $SMB_USER
   create mask = 0664
   directory mask = 0775
   force user = $SMB_USER
   force group = $SMB_USER
EOF

# Restart Samba
systemctl enable smbd >/dev/null
systemctl restart smbd

SMB_IP="$(detect_ip || true)"
SMB_PORT="445"  # (NetBIOS 139 also exists; modern clients use 445)

ok "Samba is configured."

echo
echo "================= CONNECT INFO ================="
echo "Server IP:       ${SMB_IP:-<your-host-ip>}"
echo "Port:            ${SMB_PORT}"
echo "Share name:      ${SHARE_NAME}"
echo "Share path:      ${SHARE_PATH}"
echo "Read-only:       ${READ_ONLY}"
echo "Guest access:    ${GUEST_OK}"
if [[ "$GUEST_OK" != "yes" ]]; then
  echo "Username:        ${SMB_USER}"
  echo "Password:        ${SMB_PASS}"
else
  echo "Credentials:     Not required (guest access enabled)"
fi
echo "Example (macOS/Unix):  smbclient //${SMB_IP}/${SHARE_NAME} -U ${SMB_USER}"
echo "On iPad: AddNew -> SMB -> Server: ${SMB_IP}, Share: ${SHARE_NAME}"
echo "================================================"
