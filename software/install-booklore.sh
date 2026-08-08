#!/bin/bash

set -euo pipefail

CT_ID="114"
CT_HOSTNAME="books"
CT_CORES="2"
CT_MEMORY="4096"
CT_SWAP="1024"
CT_DISK="24"
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"

OS_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"

HOST_LIBRARY_SOURCE="/mnt/bigbjorne/media/books"
HOST_SAMPLE_ROOT="/mnt/bigbjorne/media/booklore-sample"
HOST_SAMPLE_BOOKS="$HOST_SAMPLE_ROOT/books"
HOST_BOOKDROP="$HOST_SAMPLE_ROOT/bookdrop"
CT_BOOKS="/srv/booklore/books"
CT_BOOKDROP="/srv/booklore/bookdrop"
BOOKLORE_ROOT="/opt/booklore"

BOOKLORE_IMAGE="ghcr.io/booklore-app/booklore:v2.3.1"
MARIADB_IMAGE="lscr.io/linuxserver/mariadb:11.4.8"

info() {
  printf '[INFO] %s\n' "$*"
}

ok() {
  printf '[OK] %s\n' "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

ct_exec() {
  pct exec "$CT_ID" -- bash -lc "$1"
}

require_host() {
  [[ $EUID -eq 0 ]] || fail "Run this script as root on the Proxmox host."
  [[ -f /etc/pve/.version ]] || fail "This is not a Proxmox VE host."
  [[ -d "$HOST_LIBRARY_SOURCE" ]] || fail "Missing source library: $HOST_LIBRARY_SOURCE"
  [[ -f "$HOST_LIBRARY_SOURCE/library-metadata.csv" ]] || fail "Missing library-metadata.csv"
  [[ -f "$HOST_LIBRARY_SOURCE/collection-memberships.csv" ]] || fail "Missing collection-memberships.csv"
  pct status "$CT_ID" &>/dev/null && fail "Container $CT_ID already exists."
  [[ ! -e "$HOST_SAMPLE_ROOT" ]] || fail "$HOST_SAMPLE_ROOT already exists. Remove it explicitly before retrying."
}

prepare_sample_library() {
  info "Preparing 20-book sample library"
  mkdir -p "$HOST_SAMPLE_BOOKS" "$HOST_BOOKDROP"

  python3 - "$HOST_LIBRARY_SOURCE" "$HOST_SAMPLE_BOOKS" "$HOST_SAMPLE_ROOT/sample-manifest.csv" <<'PY'
import csv
import json
import os
import shutil
import sys

source_dir, destination_dir, manifest_path = sys.argv[1:]
targets = [
    "Fiction",
    "Math",
    "Web Development",
    "Machine Learning",
    "C Programming",
    "Java Programming",
    "JavaScript Programming",
    "Go Programming",
    "Database",
    "Linux",
    "Networks",
    "Algorithms",
    "History",
    "Philosophy",
    "Economics",
    "Politics",
    "Finance",
    "DevOps",
    "Architecture",
    "Web Security",
]

with open(os.path.join(source_dir, "library-metadata.csv"), newline="", encoding="utf-8-sig") as handle:
    books = list(csv.DictReader(handle))

for book in books:
    book["collections"] = json.loads(book.get("collections_json") or "[]")

selected = []
used = set()
for index, collection in enumerate(targets):
    desired_format = "epub" if index % 2 == 0 else "pdf"
    candidates = [
        book for book in books
        if book["filename"] not in used
        and any(item.get("title") == collection for item in book["collections"])
        and os.path.isfile(os.path.join(source_dir, book["filename"]))
    ]
    candidates.sort(key=lambda book: (
        book.get("format") != desired_format,
        book.get("title", "").casefold(),
        book["filename"].casefold(),
    ))
    if not candidates:
        raise SystemExit(f"No available book found for collection: {collection}")
    book = candidates[0]
    selected.append((collection, book))
    used.add(book["filename"])

for selected_for, book in selected:
    source = os.path.join(source_dir, book["filename"])
    destination = os.path.join(destination_dir, book["filename"])
    shutil.copyfile(source, destination)
    if os.path.getsize(source) != os.path.getsize(destination):
        raise SystemExit(f"Size mismatch while copying {book['filename']}")

with open(manifest_path, "w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle)
    writer.writerow(["filename", "title", "author", "format", "selected_for", "collections"])
    for selected_for, book in selected:
        writer.writerow([
            book["filename"],
            book.get("title", ""),
            book.get("author", ""),
            book.get("format", ""),
            selected_for,
            json.dumps(book["collections"], ensure_ascii=False),
        ])

print(f"Prepared {len(selected)} books")
PY

  [[ $(find "$HOST_SAMPLE_BOOKS" -maxdepth 1 -type f | wc -l) -eq 20 ]] || fail "Sample library does not contain 20 files."
  ok "Sample library ready at $HOST_SAMPLE_BOOKS"
}

ensure_template() {
  info "Checking Debian template"
  if ! pveam list "$TEMPLATE_STORAGE" | grep -Fq "$OS_TEMPLATE"; then
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$OS_TEMPLATE"
  fi
  ok "Template ready"
}

create_container() {
  info "Creating unprivileged LXC $CT_ID"
  pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp,type=veth" \
    --features "nesting=1,keyctl=1" \
    --unprivileged 1 \
    --onboot 1

  pct set "$CT_ID" -mp0 "$HOST_SAMPLE_BOOKS,mp=$CT_BOOKS,backup=0"
  pct set "$CT_ID" -mp1 "$HOST_BOOKDROP,mp=$CT_BOOKDROP,backup=0"
  ok "Container and bind mounts configured"
}

start_container() {
  info "Starting LXC $CT_ID"
  pct start "$CT_ID"
  for _ in {1..30}; do
    if pct exec "$CT_ID" -- true &>/dev/null; then
      ok "Container started"
      return
    fi
    sleep 1
  done
  fail "Container did not become ready."
}

install_docker() {
  info "Installing Docker Engine and Avahi"
  ct_exec "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y ca-certificates curl openssl avahi-daemon"
  ct_exec "install -m 0755 -d /etc/apt/keyrings; curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; chmod a+r /etc/apt/keyrings/docker.asc"
  ct_exec 'source /etc/os-release; printf "Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n" "$VERSION_CODENAME" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.sources'
  ct_exec "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  ct_exec "systemctl enable --now docker avahi-daemon"
  ok "Docker and Avahi installed"
}

write_compose_config() {
  local temporary_dir compose_file env_file timezone db_password root_password
  temporary_dir=$(mktemp -d)
  compose_file="$temporary_dir/docker-compose.yml"
  env_file="$temporary_dir/.env"
  timezone=$(cat /etc/timezone 2>/dev/null || printf 'Etc/UTC')
  db_password=$(openssl rand -hex 32)
  root_password=$(openssl rand -hex 32)

  cat > "$compose_file" <<EOF
services:
  booklore:
    image: $BOOKLORE_IMAGE
    container_name: booklore
    environment:
      USER_ID: "1000"
      GROUP_ID: "1000"
      TZ: \${TZ}
      DATABASE_URL: jdbc:mariadb://mariadb:3306/booklore
      DATABASE_USERNAME: booklore
      DATABASE_PASSWORD: \${DB_PASSWORD}
      DISK_TYPE: LOCAL
    depends_on:
      mariadb:
        condition: service_healthy
    ports:
      - "6060:6060"
    volumes:
      - $BOOKLORE_ROOT/data:/app/data
      - $CT_BOOKS:/books
      - $CT_BOOKDROP:/bookdrop
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://localhost:6060/api/v1/healthcheck"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: unless-stopped

  mariadb:
    image: $MARIADB_IMAGE
    container_name: booklore-mariadb
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: \${TZ}
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: booklore
      MYSQL_USER: booklore
      MYSQL_PASSWORD: \${DB_PASSWORD}
    volumes:
      - $BOOKLORE_ROOT/mariadb/config:/config
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped
EOF

  cat > "$env_file" <<EOF
TZ=$timezone
DB_PASSWORD=$db_password
MYSQL_ROOT_PASSWORD=$root_password
EOF

  ct_exec "mkdir -p $BOOKLORE_ROOT/data $BOOKLORE_ROOT/mariadb/config; chown -R 1000:1000 $BOOKLORE_ROOT"
  pct push "$CT_ID" "$compose_file" "$BOOKLORE_ROOT/docker-compose.yml"
  pct push "$CT_ID" "$env_file" "$BOOKLORE_ROOT/.env"
  ct_exec "chmod 600 $BOOKLORE_ROOT/.env; chmod 644 $BOOKLORE_ROOT/docker-compose.yml"
  rm -rf "$temporary_dir"
  ok "Compose configuration written"
}

launch_booklore() {
  info "Pulling BookLore and MariaDB images"
  ct_exec "cd $BOOKLORE_ROOT; docker compose pull"
  info "Starting BookLore"
  ct_exec "cd $BOOKLORE_ROOT; docker compose up -d"
  ok "BookLore stack started"
}

show_result() {
  local container_ip
  container_ip=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
  printf '\n'
  ok "BookLore installation complete"
  printf 'Container:      %s (%s)\n' "$CT_ID" "$CT_HOSTNAME"
  printf 'Address:        http://books.local:6060\n'
  printf 'IP fallback:    http://%s:6060\n' "$container_ip"
  printf 'Sample books:   %s\n' "$HOST_SAMPLE_BOOKS"
  printf 'BookDrop:       %s\n' "$HOST_BOOKDROP"
  printf 'Sample manifest: %s\n' "$HOST_SAMPLE_ROOT/sample-manifest.csv"
  printf '\nCreate the admin account, then create a Book Per File library using /books.\n'
}

main() {
  require_host
  prepare_sample_library
  ensure_template
  create_container
  start_container
  install_docker
  write_compose_config
  launch_booklore
  show_result
}

main "$@"
