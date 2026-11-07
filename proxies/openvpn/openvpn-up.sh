#!/bin/sh
set -eu

interface="${1:?OpenVPN did not provide its tunnel interface}"
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
iptables -A FORWARD -i "$interface" -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o "$interface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
