# proxmox-scripts

My proxmox scripts

## Delete a container

```sh
pct stop container_id
pct destroy container_id
```

### Samba related useful ops

```sh
# Change Samba password (inside CT)
pct exec 112 -- bash -lc "smbpasswd nasuser"

# Restart Samba (inside CT)
pct exec 112 -- systemctl restart smbd

# List shares (from another machine)
smbclient -L //<CT_IP>/ -U nasuser
```
