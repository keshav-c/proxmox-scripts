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

### Jackett torrent search

- LXC: `115` (`torrentsearch`), unprivileged Debian 12
- Resources: 1 core, 512 MB RAM, 512 MB swap, 8 GB `local-lvm` root disk
- Address: `http://torrentsearch.local:9117`
- Jackett: `v0.24.2353` installed in `/opt/Jackett`
- Service: `jackett.service`, running as the `jackett` system user
- State: `/var/lib/jackett/.config/Jackett`
- Media mounts: none
- qBittorrent integration: official `jackett.py` search plugin in CT `113`
- Credentials: `credentials/jackett.txt` (gitignored)
- Configuration archive: `credentials/jackett-config.tar.gz` (gitignored)

Jackett indexers are selected independently in its Web UI. The qBittorrent
plugin queries all configured Jackett indexers through Jackett's Torznab API.

Configured public indexers as of 2026-08-08:

- General: kickasstorrents.ws, LimeTorrents, The Pirate Bay, TheRARBG,
  TorrentDownload, TorrentGalaxyClone, and Zamunda RIP
- Adult: MyPornClub, OpenSharing, PornoTorrent, RinTor.NeT, sosulki, and xxxtor
- Japanese/JAV: Free JAV Torrent, Nyaa.si, OneJAV, sukebei.nyaa.si,
  Tokyo Toshokan, and U3C3

Nyaa uses `https://nyaa.mom/` and Sukebei uses
`https://sukebei.nyaa.mom/`; their primary `.si` endpoints reset TLS
connections from the LXC. A real general/adult search and a JAV-oriented
search completed across all configured indexers without connection errors.
Public-indexer availability is still expected to vary over time.

Tested but not configured:

- RuTor: the basic test can pass, but keyword searches reset the TLS connection
- Byrutor: returns malformed placeholder rows through qBittorrent's search plugin
- CS.RIN.RU: no Jackett definition; it is a forum rather than a Torznab-style indexer

Useful checks from the Proxmox host:

```sh
pct exec 115 -- systemctl status jackett
pct exec 115 -- journalctl -u jackett --no-pager
pct exec 113 -- curl -sS http://127.0.0.1:8080/api/v2/search/plugins
```
