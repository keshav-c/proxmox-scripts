#!/bin/bash
# Save as /root/jellyfin-drive.sh

case "$1" in
  disconnect)
    echo "Stopping Jellyfin..."
    pct exec 111 -- systemctl stop jellyfin
    echo "Unmounting drive..."
    umount /mnt/bjorne
    echo "Safe to remove drive!"
    ;;
  connect)
    echo "Mounting drive..."
    mount /mnt/bjorne
    if [ $? -eq 0 ]; then
      echo "Starting Jellyfin..."
      pct exec 111 -- systemctl start jellyfin
      echo "Ready! Scan libraries in Jellyfin."
    else
      echo "Mount failed! Check if drive is connected."
    fi
    ;;
  *)
    echo "Usage: $0 {disconnect|connect}"
    ;;
esac