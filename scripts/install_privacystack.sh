#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '%s\n' 'This installer must be run as root.' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  printf '%s\n' 'Unsupported system: /etc/os-release not found.' >&2
  exit 1
fi

. /etc/os-release
if [[ ${ID_LIKE:-} != *debian* && ${ID:-} != debian && ${ID:-} != ubuntu ]]; then
  printf '%s\n' 'Unsupported distribution. This installer currently targets Debian/Ubuntu systems.' >&2
  exit 1
fi

APT_UPDATED=0
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf '%s\n' "Error: $*" >&2
  exit 1
}

ensure_apt_update() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    log 'Updating package index (apt-get update)...'
    apt-get update -y
    APT_UPDATED=1
  fi
}

install_packages() {
  ensure_apt_update
  apt-get install -y "$@"
}

parse_args() {
  SERVER_IP=""
  PIHOLE_PASSWORD=""
  VPN_INTERFACE='wg0'
  VPN_PORT='51820'
  VPN_NETWORK='10.8.0.0/24'
  CLIENT_NAME='client1'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-ip)
        SERVER_IP="$2"
        shift 2
        ;;
      --pihole-password)
        PIHOLE_PASSWORD="$2"
        shift 2
        ;;
      --vpn-interface)
        VPN_INTERFACE="$2"
        shift 2
        ;;
      --vpn-port)
        VPN_PORT="$2"
        shift 2
        ;;
      --vpn-network)
        VPN_NETWORK="$2"
        shift 2
        ;;
      --client-name)
        CLIENT_NAME="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'EOF'
Usage: sudo ./install_privacystack.sh [options]

Options:
  --server-ip <IPv4>        Public IPv4 address of this server (used in client configs)
  --pihole-password <pass>  Password for the Pi-hole admin interface (auto-generated if omitted)
  --vpn-interface <name>    WireGuard interface name (default: wg0)
  --vpn-port <port>         WireGuard UDP listen port (default: 51820)
  --vpn-network <cidr>      WireGuard VPN network in CIDR format (default: 10.8.0.0/24)
  --client-name <name>      Label for the first generated WireGuard client (default: client1)
  --help                    Display this help message
EOF
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    install_packages "${missing[@]}"
  fi
}

detect_primary_interface() {
  local iface
  iface=$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')
  if [[ -z "$iface" ]]; then
    die 'Unable to detect the primary network interface. Please set it manually after installation.'
  fi
  printf '%s' "$iface"
}

detect_public_ip() {
  local ip
  ip=$(curl -4s https://api.ipify.org 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
  fi
}

generate_password() {
  openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
}

calculate_vpn_addresses() {
  local cidr base oct1 oct2 oct3 oct4
  cidr=${VPN_NETWORK#*/}
  base=${VPN_NETWORK%/*}
  IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$base"
  if [[ -z "$cidr" || -z "$oct1" || -z "$oct2" || -z "$oct3" || -z "$oct4" ]]; then
    die 'Invalid --vpn-network provided. Use format like 10.8.0.0/24.'
  fi
  if (( oct4 > 252 )); then
    die 'The base address provided leaves insufficient room for server/client allocation.'
  fi
  SERVER_WG_ADDRESS="${oct1}.${oct2}.${oct3}.$((oct4 + 1))/${cidr}"
  CLIENT_WG_ADDRESS="${oct1}.${oct2}.${oct3}.$((oct4 + 2))/${cidr}"
  CLIENT_ALLOWED_IPS="${oct1}.${oct2}.${oct3}.$((oct4 + 2))/32"
  SERVER_DNS_IP="${oct1}.${oct2}.${oct3}.$((oct4 + 1))"
}

configure_unbound() {
  log 'Installing and configuring Unbound (recursive DNS resolver)...'
  install_packages unbound unbound-anchor
  install_packages wget

  install -d -o root -g root -m 755 /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root

  cat <<'EOF' >/etc/unbound/unbound.conf.d/pi-hole.conf
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow
    access-control: 169.254.0.0/16 allow
    root-hints: "/var/lib/unbound/root.hints"
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-dnssec-stripped: yes
    prefetch: yes
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    rrset-cache-size: 256m
    msg-cache-size: 128m
    unwanted-reply-threshold: 10000000
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
EOF

  systemctl enable unbound
  systemctl restart unbound
}

install_pihole() {
  if command -v pihole >/dev/null 2>&1; then
    log 'Pi-hole already installed. Skipping installation step.'
    return
  fi

  log 'Installing Pi-hole (network-wide ad/tracker blocker)...'
  install_packages curl ca-certificates

  curl -sSL https://install.pi-hole.net -o /tmp/basic-install.sh
  chmod +x /tmp/basic-install.sh
  export PIHOLE_SKIP_OS_CHECK=true
  bash /tmp/basic-install.sh --unattended
}

configure_pihole() {
  require_commands pihole

  log 'Configuring Pi-hole to use Unbound and apply supplied settings...'
  local interface
  interface=$(detect_primary_interface)
  pihole -a setinterface "$interface"
  pihole -a setdns 127.0.0.1#5335
  pihole -a -p "$PIHOLE_PASSWORD"
  touch /root/.pihole_webpassword
  chmod 600 /root/.pihole_webpassword
  printf '%s' "$PIHOLE_PASSWORD" >/root/.pihole_webpassword
  systemctl restart pihole-FTL
}

configure_wireguard() {
  log 'Installing and configuring WireGuard (secure VPN tunnel)...'
  install_packages wireguard wireguard-tools qrencode iptables-persistent

  umask 077
  install -d -m 700 /etc/wireguard
  install -d -m 700 /etc/wireguard/clients

  local server_private_key_path="/etc/wireguard/${VPN_INTERFACE}_server.key"
  local server_public_key_path="/etc/wireguard/${VPN_INTERFACE}_server.pub"
  local client_private_key_path="/etc/wireguard/clients/${CLIENT_NAME}.key"
  local client_public_key_path="/etc/wireguard/clients/${CLIENT_NAME}.pub"
  local client_psk_path="/etc/wireguard/clients/${CLIENT_NAME}.psk"

  if [[ ! -f "$server_private_key_path" ]]; then
    wg genkey | tee "$server_private_key_path" | wg pubkey >"$server_public_key_path"
  fi
  if [[ ! -f "$client_private_key_path" ]]; then
    wg genkey | tee "$client_private_key_path" | wg pubkey >"$client_public_key_path"
  fi
  if [[ ! -f "$client_psk_path" ]]; then
    wg genpsk >"$client_psk_path"
  fi

  local server_private_key client_private_key client_public_key client_psk server_public_key
  server_private_key=$(cat "$server_private_key_path")
  server_public_key=$(cat "$server_public_key_path")
  client_private_key=$(cat "$client_private_key_path")
  client_public_key=$(cat "$client_public_key_path")
  client_psk=$(cat "$client_psk_path")

  cat <<EOF >/etc/wireguard/${VPN_INTERFACE}.conf
[Interface]
Address = ${SERVER_WG_ADDRESS}
ListenPort = ${VPN_PORT}
PrivateKey = ${server_private_key}
SaveConfig = true
PostUp = iptables -t nat -A POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE; iptables -A FORWARD -i ${PRIMARY_INTERFACE} -o ${VPN_INTERFACE} -j ACCEPT; iptables -A FORWARD -i ${VPN_INTERFACE} -o ${PRIMARY_INTERFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE; iptables -D FORWARD -i ${PRIMARY_INTERFACE} -o ${VPN_INTERFACE} -j ACCEPT; iptables -D FORWARD -i ${VPN_INTERFACE} -o ${PRIMARY_INTERFACE} -j ACCEPT

[Peer]
# ${CLIENT_NAME}
PublicKey = ${client_public_key}
PresharedKey = ${client_psk}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
EOF

  cat <<EOF >/etc/wireguard/clients/${CLIENT_NAME}.conf
[Interface]
PrivateKey = ${client_private_key}
Address = ${CLIENT_WG_ADDRESS}
DNS = ${SERVER_DNS_IP}

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${client_psk}
Endpoint = ${SERVER_IP}:${VPN_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  install -d -m 755 /var/lib/privacy-stack
  qrencode -t ansiutf8 < /etc/wireguard/clients/${CLIENT_NAME}.conf >/var/lib/privacy-stack/${CLIENT_NAME}.qr

  cat <<'EOF' >/etc/sysctl.d/99-privacy-stack.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null

  systemctl enable "wg-quick@${VPN_INTERFACE}"
  systemctl restart "wg-quick@${VPN_INTERFACE}"
}

summarise() {
  cat <<EOF
\n==================== Installation Summary ====================
Pi-hole admin URL: http://$(hostname -I | awk '{print $1}')/admin
Pi-hole admin password: ${PIHOLE_PASSWORD}
Stored at: /root/.pihole_webpassword

WireGuard server interface: ${VPN_INTERFACE}
WireGuard server listens on UDP port: ${VPN_PORT}
WireGuard client profile: /etc/wireguard/clients/${CLIENT_NAME}.conf
WireGuard client QR (ANSI): /var/lib/privacy-stack/${CLIENT_NAME}.qr
To display the QR code: cat /var/lib/privacy-stack/${CLIENT_NAME}.qr
===============================================================
EOF
}

main() {
  parse_args "$@"

  require_commands ip awk curl openssl

  PRIMARY_INTERFACE=$(detect_primary_interface)

  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(detect_public_ip)
  fi
  if [[ -z "$SERVER_IP" ]]; then
    if [[ -t 0 ]]; then
      read -rp 'Enter the public IPv4 address for WireGuard clients to reach: ' SERVER_IP
    fi
  fi
  [[ -z "$SERVER_IP" ]] && die 'Server public IP is required. Provide via --server-ip.'

  if [[ -z "$PIHOLE_PASSWORD" ]]; then
    PIHOLE_PASSWORD=$(generate_password)
  fi

  calculate_vpn_addresses

  configure_unbound
  install_pihole
  configure_pihole
  configure_wireguard

  summarise
}

main "$@"
