#!/bin/bash

set -e

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; }

[ "$EUID" -ne 0 ] && err "Execute como root" && exit 1

################################################################################
# BACKUP
################################################################################

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/backup-rede-$TIMESTAMP"

info "Criando backup em $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"

backup_file() {
    if [ -f "$1" ]; then
        cp "$1" "$BACKUP_DIR/"
        info "Backup: $1"
    fi
}

################################################################################
# VARIÁVEIS
################################################################################

SSID="1S1S"
PASSWORD="D@LcS0uZ@"
GATEWAY="192.168.10.1"
RPI_IP="192.168.10.105"

################################################################################
# BACKUP DOS ARQUIVOS
################################################################################

backup_file /etc/network/interfaces
backup_file /etc/wpa_supplicant/wpa_supplicant.conf
backup_file /etc/sysctl.conf
backup_file /etc/systemd/system/pseudo-bridge.service
backup_file /usr/local/bin/pseudo-bridge.sh

################################################################################
# INSTALAÇÃO
################################################################################

info "Instalando pacotes..."
apt update -qq
apt install -y wpasupplicant parprouted dhcp-helper

################################################################################
# CONFIG WIFI
################################################################################

info "Configurando WiFi..."
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=BR

network={
    ssid="$SSID"
    psk="$PASSWORD"
}
EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

################################################################################
# REDE
################################################################################

info "Configurando rede..."

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet static
    address $RPI_IP
    netmask 255.255.255.0
    gateway $GATEWAY
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

auto eth0
iface eth0 inet manual
EOF

################################################################################
# SYSCTL
################################################################################

info "Configurando IP forwarding..."
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

sysctl -p >/dev/null

################################################################################
# SCRIPT BRIDGE
################################################################################

info "Criando script principal..."

cat > /usr/local/bin/pseudo-bridge.sh <<'EOF'
#!/bin/bash

sleep 5

ip link set wlan0 up
ip link set eth0 up

if ! iw dev wlan0 link | grep -q "Connected"; then
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
    sleep 5
fi

echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp
echo 1 > /proc/sys/net/ipv4/conf/wlan0/proxy_arp
echo 1 > /proc/sys/net/ipv4/conf/eth0/proxy_arp

pkill parprouted 2>/dev/null || true
parprouted wlan0 eth0 &

pkill dhcp-helper 2>/dev/null || true
dhcp-helper -b wlan0 &

exit 0
EOF

chmod +x /usr/local/bin/pseudo-bridge.sh

################################################################################
# SYSTEMD
################################################################################

info "Criando serviço..."

cat > /etc/systemd/system/pseudo-bridge.service <<EOF
[Unit]
Description=Pseudo Bridge WiFi-Ethernet
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pseudo-bridge.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

################################################################################
# ENABLE
################################################################################

systemctl daemon-reload
systemctl enable pseudo-bridge.service
systemctl enable wpa_supplicant

################################################################################
# FINAL
################################################################################

echo ""
info "======================================"
info " BACKUP salvo em:"
echo " $BACKUP_DIR"
info "======================================"
echo ""

warn "Para restaurar manualmente:"
echo "cp $BACKUP_DIR/* /etc/... (ajuste conforme necessário)"
echo ""

warn "Reiniciando em 10 segundos..."
sleep 10
reboot
