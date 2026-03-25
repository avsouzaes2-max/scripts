#!/bin/bash

set -e

echo "[+] Configurando Raspberry Pi como pseudo-bridge (Wi-Fi -> Ethernet)"

# Interfaces
WLAN="wlan0"
ETH="eth0"

# Rede
LAN_NET="192.168.10.0/24"

echo "[+] Ativando IP Forwarding"
sysctl -w net.ipv4.ip_forward=1

echo "[+] Configurando Proxy ARP"
sysctl -w net.ipv4.conf.all.proxy_arp=1
sysctl -w net.ipv4.conf.$WLAN.proxy_arp=1
sysctl -w net.ipv4.conf.$ETH.proxy_arp=1

echo "[+] Ajustando comportamento ARP"
sysctl -w net.ipv4.conf.all.arp_filter=1
sysctl -w net.ipv4.conf.all.arp_ignore=2

echo "[+] Limpando IP da interface Ethernet"
ip addr flush dev $ETH

echo "[+] Garantindo que wlan0 esteja via DHCP"
dhclient -v $WLAN || true

echo "[+] Adicionando rota local explícita"
ip route add $LAN_NET dev $ETH || true

echo "[+] Ajustando regras de firewall (permitir forwarding)"
iptables -C FORWARD -i $ETH -o $WLAN -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i $ETH -o $WLAN -j ACCEPT

iptables -C FORWARD -i $WLAN -o $ETH -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i $WLAN -o $ETH -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[+] Configuração aplicada com sucesso"