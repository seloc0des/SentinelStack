#!/usr/bin/env bash
set -euo pipefail

# NB: these run from main(), after arg parsing, so --help works as a normal user
check_preconditions() {
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
}

APT_UPDATED=0
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

log() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '%s\n' "Error: $*" >&2
  exit 1
}

# timestamped backup, so we never silently destroy a working config.
# Path lands in LAST_BACKUP so callers can roll back.
LAST_BACKUP=""
backup_file() {
  local f="$1"
  LAST_BACKUP=""
  [[ -f "$f" ]] || return 0
  # pid suffix: two backups in the same second must not collide
  local dest="${f}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "$f" "$dest"
  LAST_BACKUP="$dest"
  log "Backed up ${f} -> ${dest}"
}

ensure_apt_update() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    log 'Updating package index (apt-get update)...'
    apt-get update
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
  # matches the deployed selodevserv stack; override if you're building a new box
  VPN_NETWORK='10.66.66.0/24'
  VPN_MTU='1340'
  CLIENT_NAME='client1'
  POLICY_ROUTE_TABLE='51821'
  USE_POLICY_ROUTING=1
  FORCE_SERVER_CONFIG=0

  require_arg() {
    local opt="$1"
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
      die "Missing value for ${opt}"
    fi
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-ip)
        require_arg "$1" "${2:-}"; SERVER_IP="$2"; shift 2 ;;
      --pihole-password)
        require_arg "$1" "${2:-}"; PIHOLE_PASSWORD="$2"; shift 2 ;;
      --vpn-interface)
        require_arg "$1" "${2:-}"; VPN_INTERFACE="$2"; shift 2 ;;
      --vpn-port)
        require_arg "$1" "${2:-}"; VPN_PORT="$2"; shift 2 ;;
      --vpn-network)
        require_arg "$1" "${2:-}"; VPN_NETWORK="$2"; shift 2 ;;
      --vpn-mtu)
        require_arg "$1" "${2:-}"; VPN_MTU="$2"; shift 2 ;;
      --client-name)
        require_arg "$1" "${2:-}"; CLIENT_NAME="$2"; shift 2 ;;
      --policy-route-table)
        require_arg "$1" "${2:-}"; POLICY_ROUTE_TABLE="$2"; shift 2 ;;
      --no-policy-routing)
        USE_POLICY_ROUTING=0; shift ;;
      --force-server-config)
        FORCE_SERVER_CONFIG=1; shift ;;
      --help|-h)
        cat <<'EOF'
Usage: sudo ./install_privacystack.sh [options]

Options:
  --server-ip <IPv4>        Public IPv4 address of this server (used in client configs)
  --pihole-password <pass>  Password for the Pi-hole admin interface (auto-generated if omitted)
  --vpn-interface <name>    WireGuard interface name (default: wg0)
  --vpn-port <port>         WireGuard UDP listen port (default: 51820)
  --vpn-network <cidr>      WireGuard VPN network in CIDR format (default: 10.66.66.0/24)
  --vpn-mtu <bytes>         WireGuard interface MTU (default: 1340)
  --client-name <name>      Label for the generated WireGuard client (default: client1)
  --policy-route-table <n>  Numbered routing table for VPN egress (default: 51821)
  --no-policy-routing       Skip the dedicated routing table (use the system default route)
  --force-server-config     Regenerate the server [Interface] block. DESTROYS EXISTING PEERS.
  --help                    Display this help message

By default an existing server config is never rewritten -- the client is added as a
new peer instead. That is the whole point: re-running this must not orphan your devices.
EOF
        exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

require_commands() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required command(s): ${missing[*]}. Please install the required dependencies and re-run the installer."
  fi
}

detect_primary_interface() {
  local iface
  iface=$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$iface" ]] || die 'Unable to detect the primary network interface. Please set it manually after installation.'
  printf '%s' "$iface"
}

detect_lan_gateway() {
  ip -4 route list default 2>/dev/null | awk '{print $3; exit}'
}

detect_lan_cidr() {
  local iface="$1"
  ip -4 -o route list scope link dev "$iface" 2>/dev/null | awk '{print $1; exit}'
}

detect_public_ip() {
  curl -4s --max-time 10 https://api.ipify.org 2>/dev/null || true
}

generate_password() {
  openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
}

calculate_vpn_addresses() {
  local cidr base oct1 oct2 oct3 oct4
  cidr=${VPN_NETWORK#*/}
  base=${VPN_NETWORK%/*}
  IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$base"

  [[ "$VPN_NETWORK" == */* ]] || die 'Invalid --vpn-network: missing /prefix. Use format like 10.66.66.0/24.'
  for o in "$oct1" "$oct2" "$oct3" "$oct4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || die "Invalid --vpn-network: '${base}' is not a dotted-quad IPv4 address."
    (( o <= 255 )) || die "Invalid --vpn-network: octet '${o}' is out of range."
  done
  [[ "$cidr" =~ ^[0-9]+$ ]] && (( cidr >= 8 && cidr <= 30 )) \
    || die "Invalid --vpn-network prefix '/${cidr}'. Expected /8 to /30."
  (( oct4 <= 252 )) || die 'The base address provided leaves insufficient room for server/client allocation.'

  SERVER_WG_ADDRESS="${oct1}.${oct2}.${oct3}.$((oct4 + 1))/${cidr}"
  SERVER_DNS_IP="${oct1}.${oct2}.${oct3}.$((oct4 + 1))"
  # /32 on the client: the server is the only thing it should treat as on-link
  CLIENT_WG_ADDRESS="${oct1}.${oct2}.${oct3}.$((oct4 + 2))/32"
  CLIENT_ALLOWED_IPS="${oct1}.${oct2}.${oct3}.$((oct4 + 2))/32"
}

configure_unbound() {
  log 'Installing and configuring Unbound (recursive DNS resolver)...'
  install_packages unbound unbound-anchor wget

  # Leave /var/lib/unbound owned by the unbound user. Chowning it to root breaks
  # RFC5011 rollover -- unbound can no longer rewrite root.key, and DNSSEC quietly
  # dies the next time the root KSK rolls.
  install -d -m 755 /etc/unbound/unbound.conf.d
  if [[ ! -d /var/lib/unbound ]]; then
    install -d -o unbound -g unbound -m 755 /var/lib/unbound 2>/dev/null \
      || install -d -m 755 /var/lib/unbound
  fi
  refresh_root_hints

  local conf=/etc/unbound/unbound.conf.d/pi-hole.conf
  backup_file "$conf"
  local rollback="$LAST_BACKUP"
  cat <<'EOF' >/etc/unbound/unbound.conf.d/pi-hole.conf
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # Pi-hole on localhost is the only client that should ever reach us.
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

    root-hints: "/var/lib/unbound/root.hints"
    # RFC5011 keeps this rolled automatically; don't hand-edit it
    auto-trust-anchor-file: "/var/lib/unbound/root.key"

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    val-permissive-mode: no
    val-clean-additional: yes
    unwanted-reply-threshold: 10000000

    # 1232 dodges most path-MTU fragmentation grief
    edns-buffer-size: 1232

    prefetch: yes
    prefetch-key: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
    rrset-roundrobin: yes
    rrset-cache-size: 64m
    msg-cache-size: 32m
    num-threads: 1

    # DNS rebinding protection: never accept RFC1918 answers from public zones.
    # If you host a public name that legitimately points inside, add it with
    # `private-domain: "example.lan"` rather than dropping these.
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    # no subnetcache module -> no warning spam
    module-config: "validator iterator"
EOF

  # Never leave the resolver in a state we know is broken -- put the old file back.
  unbound_rollback() {
    if [[ -n "$rollback" && -f "$rollback" ]]; then
      cp -a "$rollback" "$conf"
      systemctl restart unbound 2>/dev/null || true
      warn "Restored the previous Unbound config from ${rollback}."
    else
      rm -f "$conf"
      systemctl restart unbound 2>/dev/null || true
      warn "Removed the new Unbound drop-in (there was no previous config to restore)."
    fi
  }

  if ! unbound-checkconf >/dev/null 2>&1; then
    unbound_rollback
    die 'Unbound config failed validation; refusing to run a broken resolver.'
  fi

  systemctl enable unbound
  if ! systemctl restart unbound; then
    unbound_rollback
    die 'Unbound failed to start with the new config.'
  fi
}

refresh_root_hints() {
  local tmp
  tmp=$(mktemp)
  if wget -qO "$tmp" https://www.internic.net/domain/named.root && [[ -s "$tmp" ]]; then
    install -o unbound -g unbound -m 644 "$tmp" /var/lib/unbound/root.hints 2>/dev/null \
      || install -m 644 "$tmp" /var/lib/unbound/root.hints
  else
    warn 'Could not fetch root.hints; keeping the existing copy.'
  fi
  rm -f "$tmp"
}

# root server addresses change maybe once a decade, but stale hints are free to avoid
install_root_hints_timer() {
  log 'Installing monthly root.hints refresh timer...'
  cat <<'EOF' >/etc/systemd/system/unbound-root-hints.service
[Unit]
Description=Refresh Unbound root hints
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root
ExecStartPost=/bin/chown unbound:unbound /var/lib/unbound/root.hints
ExecStartPost=/bin/systemctl try-reload-or-restart unbound
EOF

  cat <<'EOF' >/etc/systemd/system/unbound-root-hints.timer
[Unit]
Description=Monthly Unbound root hints refresh

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=6h

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now unbound-root-hints.timer
}

install_pihole() {
  if command -v pihole >/dev/null 2>&1; then
    log 'Pi-hole already installed. Skipping installation step.'
    return
  fi

  log 'Installing Pi-hole (network-wide ad/tracker blocker)...'
  install_packages curl ca-certificates

  local installer
  installer=$(mktemp -t pihole-install.XXXXXX.sh)
  curl -sSL https://install.pi-hole.net -o "$installer"
  chmod 700 "$installer"
  export PIHOLE_SKIP_OS_CHECK=true
  bash "$installer" --unattended
  rm -f "$installer"
}

pihole_major_version() {
  pihole -v 2>/dev/null | sed -n 's/.*Core version is v\([0-9]*\).*/\1/p' | head -1
}

configure_pihole() {
  command -v pihole >/dev/null 2>&1 || die 'Pi-hole command not found after installation step. Aborting.'

  local major
  major=$(pihole_major_version)
  log "Configuring Pi-hole (detected major version: ${major:-unknown}) to resolve via Unbound..."

  if [[ "$major" == "6" ]]; then
    # v6 dropped `pihole -a <subcommand>` entirely; config lives in pihole.toml
    pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]'
    # LOCAL answers clients on any directly-attached subnet, which is what makes
    # VPN peers on wg0 work. Binding to a single NIC silently breaks them.
    pihole-FTL --config dns.listeningMode 'LOCAL'
    # Unbound already validates; doing it twice just burns CPU
    pihole-FTL --config dns.dnssec false
    pihole setpassword "$PIHOLE_PASSWORD" >/dev/null
  elif [[ "$major" == "5" ]]; then
    pihole -a setdns 127.0.0.1#5335
    pihole -a -p "$PIHOLE_PASSWORD" >/dev/null
  else
    die "Unrecognised Pi-hole version '${major:-unknown}'. Refusing to guess at the config CLI."
  fi

  install -m 600 /dev/null /root/.pihole_webpassword
  printf '%s\n' "$PIHOLE_PASSWORD" >/root/.pihole_webpassword

  systemctl restart pihole-FTL
  verify_pihole_upstream
}

# A config write that gets silently ignored would leave Pi-hole resolving through
# whatever it used before -- which is exactly the DNS leak this stack exists to stop.
# So read it back rather than trusting the setter. Note `pihole-FTL --config
# dns.upstreams` renders arrays as "[]", so the API is the only honest reader.
verify_pihole_upstream() {
  local i out=""
  for i in $(seq 1 15); do
    out=$(pihole api config/dns/upstreams 2>/dev/null || true)
    [[ "$out" == *'127.0.0.1#5335'* ]] && { log 'Confirmed: Pi-hole is forwarding to Unbound on 127.0.0.1#5335.'; return 0; }
    sleep 1
  done
  warn 'Could not confirm the Unbound upstream via the Pi-hole API.'
  warn 'Check it by hand:  pihole api config/dns/upstreams'
  warn 'Expected to see:   127.0.0.1#5335'
  die 'Refusing to report success while Pi-hole may be bypassing Unbound.'
}

wireguard_server_config_exists() {
  [[ -f "/etc/wireguard/${VPN_INTERFACE}.conf" ]]
}

build_postup_rules() {
  local rules
  rules="iptables -t nat -A POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE"
  rules+="; iptables -A FORWARD -i ${VPN_INTERFACE} -j ACCEPT"
  rules+="; iptables -A FORWARD -o ${VPN_INTERFACE} -j ACCEPT"
  if [[ $USE_POLICY_ROUTING -eq 1 ]]; then
    rules+="; ip rule add from ${VPN_NETWORK} table ${POLICY_ROUTE_TABLE}"
    rules+="; ip route add ${VPN_NETWORK} dev ${VPN_INTERFACE} table ${POLICY_ROUTE_TABLE}"
    [[ -n "$LAN_CIDR" ]] && rules+="; ip route add ${LAN_CIDR} dev ${PRIMARY_INTERFACE} table ${POLICY_ROUTE_TABLE}"
    [[ -n "$LAN_GATEWAY" ]] && rules+="; ip route add default via ${LAN_GATEWAY} dev ${PRIMARY_INTERFACE} table ${POLICY_ROUTE_TABLE}"
  fi
  printf '%s' "$rules"
}

build_postdown_rules() {
  local rules
  rules="iptables -t nat -D POSTROUTING -o ${PRIMARY_INTERFACE} -j MASQUERADE"
  rules+="; iptables -D FORWARD -i ${VPN_INTERFACE} -j ACCEPT"
  rules+="; iptables -D FORWARD -o ${VPN_INTERFACE} -j ACCEPT"
  if [[ $USE_POLICY_ROUTING -eq 1 ]]; then
    rules+="; ip rule del from ${VPN_NETWORK} table ${POLICY_ROUTE_TABLE}"
    rules+="; ip route del ${VPN_NETWORK} dev ${VPN_INTERFACE} table ${POLICY_ROUTE_TABLE} 2>/dev/null || true"
    [[ -n "$LAN_CIDR" ]] && rules+="; ip route del ${LAN_CIDR} dev ${PRIMARY_INTERFACE} table ${POLICY_ROUTE_TABLE} 2>/dev/null || true"
    [[ -n "$LAN_GATEWAY" ]] && rules+="; ip route del default via ${LAN_GATEWAY} dev ${PRIMARY_INTERFACE} table ${POLICY_ROUTE_TABLE} 2>/dev/null || true"
  fi
  printf '%s' "$rules"
}

write_server_config() {
  local server_private_key="$1"
  backup_file "/etc/wireguard/${VPN_INTERFACE}.conf"
  cat <<EOF >"/etc/wireguard/${VPN_INTERFACE}.conf"
[Interface]
Address = ${SERVER_WG_ADDRESS}
ListenPort = ${VPN_PORT}
PrivateKey = ${server_private_key}
MTU = ${VPN_MTU}
# SaveConfig must stay false: with it on, wg-quick rewrites this file on stop and
# eats the peer comments below.
SaveConfig = false
PostUp = $(build_postup_rules)
PostDown = $(build_postdown_rules)
EOF
}

append_peer() {
  local name="$1" pubkey="$2" psk="$3" allowed="$4"
  local conf="/etc/wireguard/${VPN_INTERFACE}.conf"

  # Must use the same matching rule as existing_peer_address(), or we can decide a
  # peer is missing here while claiming its address there -- and write a duplicate.
  if peer_exists "$pubkey"; then
    log "Peer '${name}' already present in ${conf}. Leaving it alone."
    return
  fi

  backup_file "$conf"
  cat <<EOF >>"$conf"

[Peer]
# ${name}
PublicKey = ${pubkey}
PresharedKey = ${psk}
AllowedIPs = ${allowed}
EOF
  log "Added peer '${name}' to ${conf}"
}

# wg-quick accepts both "Key = val" and "Key=val", so both lookups below normalise
# before comparing. They must agree -- see the comment in append_peer().
_peer_awk='
  function val(line,   v) {
    sub(/^[ \t]+/, "", line)
    if (!match(line, /^[A-Za-z]+[ \t]*=[ \t]*/)) return ""
    v = substr(line, RLENGTH + 1)
    gsub(/[ \t\r]+$/, "", v)
    return v
  }
  function key(line,   k) {
    sub(/^[ \t]+/, "", line)
    if (!match(line, /^[A-Za-z]+/)) return ""
    return substr(line, 1, RLENGTH)
  }
'

peer_exists() {
  local pubkey="$1" conf="/etc/wireguard/${VPN_INTERFACE}.conf"
  [[ -f "$conf" ]] || return 1
  awk -v k="$pubkey" "$_peer_awk"'
    key($0) == "PublicKey" && val($0) == k { found = 1; exit }
    END { exit !found }
  ' "$conf"
}

# address already assigned to this pubkey, if it's enrolled
existing_peer_address() {
  local pubkey="$1" conf="/etc/wireguard/${VPN_INTERFACE}.conf"
  [[ -f "$conf" ]] || return 0
  awk -v k="$pubkey" "$_peer_awk"'
    key($0) == "PublicKey"  { found = (val($0) == k); next }
    found && key($0) == "AllowedIPs" { split(val($0), a, "/"); print a[1]; exit }
  ' "$conf"
}

next_free_client_address() {
  local conf="/etc/wireguard/${VPN_INTERFACE}.conf"
  local base oct1 oct2 oct3 oct4 candidate
  base=${VPN_NETWORK%/*}
  IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$base"

  local i
  for (( i = oct4 + 2; i <= 254; i++ )); do
    candidate="${oct1}.${oct2}.${oct3}.${i}"
    if ! grep -q "AllowedIPs = ${candidate}/32" "$conf" 2>/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "No free addresses left in ${VPN_NETWORK}."
}

configure_wireguard() {
  log 'Installing and configuring WireGuard (secure VPN tunnel)...'
  install_packages wireguard wireguard-tools qrencode

  umask 077
  install -d -m 700 /etc/wireguard
  install -d -m 700 /etc/wireguard/clients

  local server_private_key_path="/etc/wireguard/${VPN_INTERFACE}_server.key"
  local server_public_key_path="/etc/wireguard/${VPN_INTERFACE}_server.pub"
  local client_private_key_path="/etc/wireguard/clients/${CLIENT_NAME}.key"
  local client_public_key_path="/etc/wireguard/clients/${CLIENT_NAME}.pub"
  local client_psk_path="/etc/wireguard/clients/${CLIENT_NAME}.psk"

  # A half-finished earlier run can leave a .key with no .pub. Derive the missing
  # public key rather than dying on a `cat` further down.
  ensure_keypair() {
    local priv="$1" pub="$2"
    [[ -f "$priv" ]] || wg genkey >"$priv"
    [[ -s "$pub" ]] || wg pubkey <"$priv" >"$pub"
  }

  ensure_keypair "$server_private_key_path" "$server_public_key_path"
  ensure_keypair "$client_private_key_path" "$client_public_key_path"
  [[ -s "$client_psk_path" ]] || wg genpsk >"$client_psk_path"

  local server_private_key server_public_key client_private_key client_public_key client_psk
  server_private_key=$(cat "$server_private_key_path")
  server_public_key=$(cat "$server_public_key_path")
  client_private_key=$(cat "$client_private_key_path")
  client_public_key=$(cat "$client_public_key_path")
  client_psk=$(cat "$client_psk_path")

  if wireguard_server_config_exists && [[ $FORCE_SERVER_CONFIG -eq 0 ]]; then
    log "Existing ${VPN_INTERFACE} config found -- preserving it and its peers."
    local addr
    # If this client is already enrolled, reuse the address the server has for it.
    # Allocating a fresh one would hand the client a config the server disagrees with.
    addr=$(existing_peer_address "$client_public_key")
    if [[ -n "$addr" ]]; then
      log "Client '${CLIENT_NAME}' is already a peer at ${addr}; reusing that address."
    else
      addr=$(next_free_client_address)
    fi
    CLIENT_WG_ADDRESS="${addr}/32"
    CLIENT_ALLOWED_IPS="${addr}/32"
    # honour whatever address the running server actually has
    SERVER_DNS_IP=$(awk "$_peer_awk"'
      key($0) == "Address" { split(val($0), a, "/"); split(a[1], b, ","); print b[1]; exit }
    ' "/etc/wireguard/${VPN_INTERFACE}.conf")
    [[ -n "$SERVER_DNS_IP" ]] || die "Could not read the server Address from /etc/wireguard/${VPN_INTERFACE}.conf."
  else
    if wireguard_server_config_exists; then
      warn '--force-server-config given: regenerating the server config. Existing peers will be dropped.'
    fi
    write_server_config "$server_private_key"
  fi

  append_peer "$CLIENT_NAME" "$client_public_key" "$client_psk" "$CLIENT_ALLOWED_IPS"

  # No ::/0 here on purpose. wg0 has no IPv6 address and there is no ip6tables
  # MASQUERADE rule, so advertising ::/0 just black-holes v6 traffic on dual-stack
  # clients. Add real v6 support before putting it back.
  cat <<EOF >"/etc/wireguard/clients/${CLIENT_NAME}.conf"
[Interface]
PrivateKey = ${client_private_key}
Address = ${CLIENT_WG_ADDRESS}
DNS = ${SERVER_DNS_IP}
MTU = ${VPN_MTU}

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${client_psk}
Endpoint = ${SERVER_IP}:${VPN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  install -d -m 755 /var/lib/privacy-stack
  qrencode -t ansiutf8 <"/etc/wireguard/clients/${CLIENT_NAME}.conf" \
    >"/var/lib/privacy-stack/${CLIENT_NAME}.qr"

  cat <<'EOF' >/etc/sysctl.d/99-privacy-stack.conf
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null

  systemctl enable "wg-quick@${VPN_INTERFACE}"
  # reload beats restart: restarting drops every connected peer
  if systemctl is-active --quiet "wg-quick@${VPN_INTERFACE}"; then
    # Materialise the stripped config first. Feeding syncconf an empty stream --
    # which is what a failed `wg-quick strip` produces via process substitution --
    # would silently remove every peer from the running interface.
    local stripped
    stripped=$(mktemp)
    chmod 600 "$stripped"
    if wg-quick strip "$VPN_INTERFACE" >"$stripped" 2>/dev/null && grep -q '^\[Peer\]' "$stripped"; then
      wg syncconf "$VPN_INTERFACE" "$stripped"
      log "Applied peer changes to the live ${VPN_INTERFACE} without dropping sessions."
    else
      warn "Could not build a valid stripped config; leaving the running interface untouched."
      warn "Apply it yourself when convenient: systemctl restart wg-quick@${VPN_INTERFACE}"
    fi
    rm -f "$stripped"
  else
    systemctl start "wg-quick@${VPN_INTERFACE}"
  fi
}

# We don't punch holes in the firewall automatically -- that's the operator's call.
# But silently handing someone a VPN that can't be reached is worse, so say so loudly.
FIREWALL_HINT=""
check_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if ufw status 2>/dev/null | grep -q "${VPN_PORT}/udp"; then
      log "ufw is active and already allows ${VPN_PORT}/udp."
    else
      FIREWALL_HINT="sudo ufw allow ${VPN_PORT}/udp"
      warn "ufw is ACTIVE and has no rule for ${VPN_PORT}/udp -- clients will not connect."
      warn "Open it with:  ${FIREWALL_HINT}"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL_HINT="sudo firewall-cmd --permanent --add-port=${VPN_PORT}/udp && sudo firewall-cmd --reload"
    warn "firewalld is active. Ensure ${VPN_PORT}/udp is open:"
    warn "  ${FIREWALL_HINT}"
  fi
}

summarise() {
  cat <<EOF

==================== Installation Summary ====================
Pi-hole admin URL:  http://$(hostname -I | awk '{print $1}')/admin
Pi-hole password:   stored at /root/.pihole_webpassword (mode 600)
                    read it with: sudo cat /root/.pihole_webpassword

WireGuard interface:      ${VPN_INTERFACE} (MTU ${VPN_MTU})
WireGuard UDP port:       ${VPN_PORT}
Client profile:           /etc/wireguard/clients/${CLIENT_NAME}.conf
Client address:           ${CLIENT_WG_ADDRESS}
Client QR (ANSI):         /var/lib/privacy-stack/${CLIENT_NAME}.qr
Show the QR:              cat /var/lib/privacy-stack/${CLIENT_NAME}.qr
===============================================================
EOF

  if [[ -n "$FIREWALL_HINT" ]]; then
    cat <<EOF
!! ACTION REQUIRED: the host firewall is blocking WireGuard.
!! Clients cannot connect until you run:
!!   ${FIREWALL_HINT}
===============================================================
EOF
  fi
}

main() {
  parse_args "$@"
  check_preconditions

  command -v apt-get >/dev/null 2>&1 || die 'apt-get not found. This installer requires a Debian/Ubuntu system with apt.'
  command -v systemctl >/dev/null 2>&1 || die 'systemctl not found. This installer requires systemd to manage services.'

  install_packages ca-certificates curl openssl iproute2 gawk
  require_commands ip awk curl openssl

  PRIMARY_INTERFACE=$(detect_primary_interface)
  LAN_GATEWAY=$(detect_lan_gateway)
  LAN_CIDR=$(detect_lan_cidr "$PRIMARY_INTERFACE")

  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(detect_public_ip)
  fi
  if [[ -z "$SERVER_IP" && -t 0 ]]; then
    read -rp 'Enter the public IPv4 address for WireGuard clients to reach: ' SERVER_IP
  fi
  [[ -n "$SERVER_IP" ]] || die 'Server public IP is required. Provide via --server-ip.'

  [[ -n "$PIHOLE_PASSWORD" ]] || PIHOLE_PASSWORD=$(generate_password)

  calculate_vpn_addresses

  configure_unbound
  install_root_hints_timer
  install_pihole
  configure_pihole
  configure_wireguard
  check_firewall

  summarise
}

main "$@"
