#!/bin/bash

################################################################################
# Script de Configuração WiFi Bridge - Raspberry Pi 3B
# Conecta via WiFi ao TP-Link e redistribui via Ethernet
# Autor: Claude (Anthropic)
# Data: 2026-03-25
################################################################################

set -e  # Sai em caso de erro

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função para mensagens
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    print_error "Este script precisa ser executado como root (sudo)"
    exit 1
fi

print_info "=== Configuração WiFi Bridge para Raspberry Pi 3B ==="
echo ""

# Solicitar credenciais WiFi
read -p "Digite o SSID da rede WiFi TP-Link: " WIFI_SSID
read -sp "Digite a senha do WiFi: " WIFI_PASSWORD
echo ""
echo ""

# Confirmar configuração
print_warn "Configuração a ser aplicada:"
echo "  - SSID WiFi: $WIFI_SSID"
echo "  - Bridge: wlan0 + eth0 → br0"
echo "  - DHCP: Fornecido pelo TP-Link (192.168.10.1)"
echo ""
read -p "Confirma a configuração? (s/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    print_error "Configuração cancelada pelo usuário"
    exit 1
fi

print_info "Iniciando configuração..."

################################################################################
# 1. INSTALAR PACOTES NECESSÁRIOS
################################################################################
print_info "Instalando pacotes necessários..."
apt update -qq
apt install -y bridge-utils wpasupplicant parprouted dhcp-helper iptables-persistent 2>&1 | grep -v "Reading\|Building"

################################################################################
# 2. PARAR SERVIÇOS CONFLITANTES
################################################################################
print_info "Parando serviços conflitantes..."
systemctl stop dhcpcd 2>/dev/null || true
systemctl disable dhcpcd 2>/dev/null || true
systemctl stop wpa_supplicant 2>/dev/null || true

################################################################################
# 3. CONFIGURAR WPA_SUPPLICANT
################################################################################
print_info "Configurando WPA Supplicant (WiFi)..."
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=BR

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASSWORD"
    key_mgmt=WPA-PSK
}
EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

################################################################################
# 4. CONFIGURAR INTERFACES DE REDE
################################################################################
print_info "Configurando interfaces de rede..."
cp /etc/network/interfaces /etc/network/interfaces.bkp001
cat > /etc/network/interfaces <<'EOF'
# Loopback
auto lo
iface lo inet loopback

# Ethernet (parte da bridge)
auto eth0
iface eth0 inet manual

# WiFi (parte da bridge)
allow-hotplug wlan0
iface wlan0 inet manual
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

# Bridge (recebe IP via DHCP do TP-Link)
auto br0
iface br0 inet dhcp
    bridge_ports eth0 wlan0
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
EOF

################################################################################
# 5. CRIAR SCRIPT AUXILIAR DE INICIALIZAÇÃO
################################################################################
print_info "Criando script de inicialização da bridge..."
cat > /usr/local/bin/setup-bridge.sh <<'BRIDGE_SCRIPT'
#!/bin/bash
# Script auxiliar para configurar a bridge

# Aguardar interfaces estarem disponíveis
sleep 5

# Garantir que as interfaces estão UP
ip link set eth0 up
ip link set wlan0 up

# Conectar WiFi se necessário
if ! iw dev wlan0 link | grep -q "Connected"; then
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
    sleep 3
fi

# Criar bridge se não existir
if ! ip link show br0 &>/dev/null; then
    brctl addbr br0
    brctl addif br0 eth0
    brctl addif br0 wlan0
    brctl stp br0 off
    ip link set br0 up
fi

# Renovar DHCP
dhclient -r br0 2>/dev/null || true
dhclient br0

exit 0
BRIDGE_SCRIPT

chmod +x /usr/local/bin/setup-bridge.sh

################################################################################
# 6. CRIAR SERVIÇO SYSTEMD
################################################################################
print_info "Criando serviço systemd..."
cat > /etc/systemd/system/wifi-bridge.service <<'EOF'
[Unit]
Description=WiFi to Ethernet Bridge Service
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-bridge.sh
ExecStop=/sbin/ip link set br0 down

[Install]
WantedBy=multi-user.target
EOF

################################################################################
# 7. HABILITAR SERVIÇOS
################################################################################
print_info "Habilitando serviços..."
systemctl daemon-reload
systemctl enable wifi-bridge.service
systemctl enable wpa_supplicant

################################################################################
# 8. CONFIGURAR IP FORWARDING (garantia)
################################################################################
print_info "Configurando IP forwarding..."
cat >> /etc/sysctl.conf <<EOF

# WiFi Bridge - IP Forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl -p >/dev/null 2>&1

################################################################################
# 9. CRIAR SCRIPT DE VERIFICAÇÃO
################################################################################
print_info "Criando script de verificação..."
cat > /usr/local/bin/check-bridge.sh <<'CHECK_SCRIPT'
#!/bin/bash
echo "=== Status da Bridge WiFi-Ethernet ==="
echo ""
echo "--- Bridge (br0) ---"
ip addr show br0 | grep -E "inet |state"
echo ""
echo "--- Interfaces da Bridge ---"
brctl show
echo ""
echo "--- Status WiFi (wlan0) ---"
iw dev wlan0 link
echo ""
echo "--- Testes de Conectividade ---"
echo -n "Gateway (TP-Link): "
ping -c 1 -W 2 192.168.10.1 >/dev/null 2>&1 && echo "OK ✓" || echo "FALHOU ✗"
echo -n "Internet (Google DNS): "
ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "OK ✓" || echo "FALHOU ✗"
CHECK_SCRIPT

chmod +x /usr/local/bin/check-bridge.sh

################################################################################
# 10. BACKUP DE CONFIGURAÇÕES
################################################################################
print_info "Criando backup das configurações originais..."
mkdir -p /root/network-backup
cp /etc/network/interfaces.orig /root/network-backup/ 2>/dev/null || true
cp /etc/dhcpcd.conf /root/network-backup/ 2>/dev/null || true

################################################################################
# CONCLUSÃO
################################################################################
echo ""
print_info "==================================================================="
print_info "         CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!"
print_info "==================================================================="
echo ""
print_warn "PRÓXIMOS PASSOS:"
echo "  1. Conecte o cabo Ethernet do Raspberry Pi ao Switch/Hub"
echo "  2. Reinicie o sistema: sudo reboot"
echo "  3. Após reiniciar, verifique o status: sudo check-bridge.sh"
echo ""
print_warn "COMANDOS ÚTEIS:"
echo "  - Verificar status: sudo check-bridge.sh"
echo "  - Ver logs: sudo journalctl -u wifi-bridge -f"
echo "  - Reiniciar bridge: sudo systemctl restart wifi-bridge"
echo "  - Desabilitar bridge: sudo systemctl disable wifi-bridge"
echo ""
print_info "O sistema será reiniciado em 10 segundos..."
print_warn "Pressione Ctrl+C para cancelar o reboot automático"
echo ""

sleep 10
reboot

