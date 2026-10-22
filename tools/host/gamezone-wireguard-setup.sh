#!/bin/bash
# Productify Gamezone: host side of the Productify Connect WireGuard tunnel.
# Reference for backend/gamezone/vast_template/gamezone_kiosk_onstart.sh (run as root, after Sunshine is set up).
#
# Why: Vast.ai maps ports randomly, but Moonlight/Sunshine need fixed TCP+UDP ports. The template maps
# one identity UDP port (same number outside and inside); WireGuard listens there and Sunshine's
# standard ports are only reachable inside the tunnel.
#
# Env:
#   GZ_WG_PORT   UDP port WireGuard listens on. Must be the *actual* identity-mapped port Vast assigned
#                (the template asks for "-p 741641:741641/udp"; Vast exposes the real number in the
#                instance's port map / env - confirm on test VM T-K2 before relying on this).
#   GZ_WG_NET    tunnel /24, default 10.77.0 (host .1, client .2)
#
# STATUS: draft, not yet run on a rented VM.
set -euo pipefail

WG_PORT="${GZ_WG_PORT:?set GZ_WG_PORT to the identity-mapped UDP port}"
NET="${GZ_WG_NET:-10.77.0}"

export DEBIAN_FRONTEND=noninteractive
if ! command -v wg >/dev/null; then
  # The Vast desktop image ships without apt lists; tolerate flaky third-party repos in update.
  apt-get -o DPkg::Lock::Timeout=600 update -qq || true
  apt-get -o DPkg::Lock::Timeout=600 install -y -qq wireguard-tools iptables >/dev/null
fi

# Vast's desktop VM image runs tailscaled (logged out) on the identity port (/etc/default/tailscaled).
# Gamezone uses that port for WireGuard instead.
if systemctl is-active --quiet tailscaled; then
  systemctl disable --now tailscaled
fi

umask 077
mkdir -p /etc/wireguard
[ -f /etc/wireguard/host.key ] || wg genkey > /etc/wireguard/host.key
wg pubkey < /etc/wireguard/host.key > /etc/wireguard/host.pub

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${NET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat /etc/wireguard/host.key)
EOF
systemctl enable --now wg-quick@wg0

# Sunshine's ports: reachable only through wg0 (and loopback). Everything else on them is dropped.
SUN_TCP="47984,47989,47990,48010"
SUN_UDP="47998:48000,48002,48010"
for chain in "-p tcp -m multiport --dports $SUN_TCP" "-p udp -m multiport --dports $SUN_UDP"; do
  iptables -C INPUT -i wg0 $chain -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i wg0 $chain -j ACCEPT
  iptables -C INPUT -i lo  $chain -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i lo  $chain -j ACCEPT
  iptables -C INPUT $chain -j DROP 2>/dev/null || iptables -A INPUT $chain -j DROP
done
iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport "$WG_PORT" -j ACCEPT

# Per-session peer management, called by the Productify backend over SSH:
#   gamezone-wg-peer add <client_public_key>     -> prints the client's tunnel address
#   gamezone-wg-peer remove-all                  -> at session end
cat > /usr/local/sbin/gamezone-wg-peer <<EOF
#!/bin/bash
set -euo pipefail
case "\${1:-}" in
  add)
    [[ "\${2:-}" =~ ^[A-Za-z0-9+/]{43}=\$ ]] || { echo "bad key" >&2; exit 2; }
    for p in \$(wg show wg0 peers); do wg set wg0 peer "\$p" remove; done   # one player per machine
    wg set wg0 peer "\$2" allowed-ips ${NET}.2/32
    echo ${NET}.2/32 ;;
  remove-all)
    for p in \$(wg show wg0 peers); do wg set wg0 peer "\$p" remove; done ;;
  *) echo "usage: \$0 add <pubkey> | remove-all" >&2; exit 2 ;;
esac
EOF
chmod 700 /usr/local/sbin/gamezone-wg-peer

printf 'WG_PUBLIC_KEY=%s\nWG_PORT=%s\nWG_HOST_ADDRESS=%s.1\n' "$(cat /etc/wireguard/host.pub)" "$WG_PORT" "$NET" >> /root/gamezone-secrets
echo "[gamezone] wireguard ready on udp/$WG_PORT"
