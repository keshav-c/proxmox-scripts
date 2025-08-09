#!/bin/bash
# Jellyfin Update Script

CT_ID="111"  # Change to your container ID

echo "Updating Jellyfin in container $CT_ID..."

# Update package lists
pct exec "$CT_ID" -- apt update

# Upgrade Jellyfin packages
pct exec "$CT_ID" -- apt upgrade -y jellyfin jellyfin-server jellyfin-web

# Restart Jellyfin service
pct exec "$CT_ID" -- systemctl restart jellyfin

# Check status
pct exec "$CT_ID" -- systemctl status jellyfin --no-pager

echo "Jellyfin update complete!"