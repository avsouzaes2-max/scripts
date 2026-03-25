#!/bin/bash
set -e

echo "[1/10] Atualizando sistema..."
apt update && apt upgrade -y

echo "[2/10] Instalando dependências..."
apt install hostapd dnsmasq -y
systemctl stop hostapd
systemctl stop dnsmasq

echo "[3/10] Configurando wpa_supplicant..."
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=BR

network={
    ssid="NOME_DO_WIFI_TPLINK"
    psk="SENHA_DO_WIFI"
}
EOF

echo "[4/10] Criando hostapd.conf..."
cat > /etc/hostapd/hostapd.conf <<EOF
interface=ap0
driver=nl80211
ssid=Repeater-Raspberry
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=12345678
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

echo "[5/10] Configurando dnsmasq..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
cat > /etc/dnsmasq.conf <<EOF
interface=ap0
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.250,255.255.255.0,24h
EOF

echo "[6/10] Habilitando IP forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

echo "[7/10] Configurando NAT..."
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables-save > /etc/iptables.ipv4.nat

cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.ipv4.nat
EOF
chmod +x /etc/network/if-up.d/iptables

echo "[8/10] Criando serviço ap0..."
cat > /etc/systemd/system/ap0.service <<EOF
[Unit]
Description=Create virtual AP interface
After=network-pre.target
Before=hostapd.service
Wants=hostapd.service

[Service]
Type=oneshot
ExecStart=/sbin/iw dev wlan0 interface add ap0 type __ap
ExecStop=/sbin/iw dev ap0 del
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable ap0.service

echo "[9/10] Habilitando serviços..."
systemctl enable hostapd
systemctl enable dnsmasq

echo "[10/10] Reinicie o Raspberry Pi para aplicar tudo."