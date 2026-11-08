#!/bin/sh
set -eu

interface="${1:?OpenVPN did not provide its tunnel interface}"

# Use the interface that holds the default route instead of assuming eth0.
wan="$(ip route show default | awk '{print $5; exit}')"
[ -n "$wan" ] || { printf '%s\n' "No default route found; cannot configure NAT." >&2; exit 1; }

# Add each rule only if it is missing, so a restart does not duplicate it.
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$wan" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$wan" -j MASQUERADE

iptables -C FORWARD -i "$interface" -o "$wan" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$interface" -o "$wan" -j ACCEPT

iptables -C FORWARD -i "$wan" -o "$interface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$wan" -o "$interface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
