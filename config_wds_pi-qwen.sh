#!/bin/bash

################################################################################
# CONFIGURADOR AUTOMÁTICO DE WDS BRIDGE - RASPBERRY PI
# Autor: Assistente IA
# Requisitos: wlan1 (USB) com suporte a 4addr, wlan0 (Interno), eth0
################################################################################

# --- CONFIGURAÇÕES DE REDE (EDITE AQUI) ---
WIFI_SSID="1S1S"
WIFI_PASS="D@LcS0uZ@"
WIFI_COUNTRY="BR"
# ------------------------------------------

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== INICIANDO CONFIGURAÇÃO WDS BRIDGE ===${NC}"

# 1. Verificação de Root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Erro: Execute este script com sudo (sudo ./config_wds_pi.sh)${NC}"
  exit 1
fi

# 2. Backup de Configurações Existentes
echo -e "${YELLOW}>> Criando backup das configurações de rede...${NC}"
cp /etc/network/interfaces /etc/network/interfaces.bak 2>/dev/null
cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.bak 2>/dev/null
cp /etc/dhcpcd.conf /etc/dhcpcd.conf.bak 2>/dev/null

# 3. Detecção de Interfaces
echo -e "${YELLOW}>> Verificando interfaces de rede...${NC}"
if ! ip link show wlan1 > /dev/null 2>&1; then
    echo -e "${RED}ERRO CRÍTICO: Interface wlan1 (USB) não encontrada. Conecte o adaptador e reinicie.${NC}"
    exit 1
fi

# 4. Verificação de Suporte 4-Address (CRÍTICO)
echo -e "${YELLOW}>> Testando suporte a 4-Address em wlan1...${NC}"
# Tenta ativar 4addr temporariamente para teste
if ! iw dev wlan1 set 4addr on 2>/dev/null; then
    echo -e "${RED}ERRO CRÍTICO: O adaptador wlan1 NÃO suporta 4-Address (WDS).${NC}"
    echo -e "${RED}A bridge transparente não funcionará. Verifique o modelo do adaptador USB.${NC}"
    exit 1
else
    # Desativa para limpar, será ativado no boot
    iw dev wlan1 set 4addr off 2>/dev/null
    echo -e "${GREEN}OK: wlan1 suporta 4-Address.${NC}"
fi

# 5. Compatibilidade com Raspberry Pi OS Bookworm
# O Bookworm usa NetworkManager por padrão e ignora /etc/network/interfaces
OS_VERSION=$(cat /etc/os-release | grep "VERSION_CODENAME" | cut -d= -f2)
if [ "$OS_VERSION" == "bookworm" ]; then
    echo -e "${YELLOW}>> Detectado Raspberry Pi OS Bookworm. Ajustando dependências...${NC}"
    apt-get update
    apt-get install -y ifupdown
    # Desabilitar NetworkManager para conflitar menos com ifupdown neste cenário específico
    systemctl stop NetworkManager
    systemctl disable NetworkManager
fi

# 6. Instalação de Pacotes Necessários
echo -e "${YELLOW}>> Instalando pacotes de bridge e Wi-Fi...${NC}"
apt-get update
apt-get install -y bridge-utils wpasupplicant wireless-tools iw

# 7. Configurar wpa_supplicant
echo -e "${YELLOW}>> Configurando wpa_supplicant para wlan1...${NC}"
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
    mode=0
    key_mgmt=WPA-PSK
}
EOF

# 8. Configurar Interfaces de Rede (Bridge)
# NOTA: wlan0 foi removido da bridge pois não suporta 4addr em modo cliente.
echo -e "${YELLOW}>> Configurando /etc/network/interfaces para Bridge (br0)...${NC}"
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

# Bridge Principal (Une Ethernet e Wi-Fi USB WDS)
auto br0
iface br0 inet dhcp
    bridge_ports eth0 wlan1
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0

# Ethernet
allow-hotplug eth0
iface eth0 inet manual

# Wi-Fi USB (WDS Uplink)
allow-hotplug wlan1
iface wlan1 inet manual
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
    pre-up iw dev wlan1 set 4addr on

# Wi-Fi Interno (NÃO ADICIONADO À BRIDGE POR FALTA DE 4ADDR)
# Se quiser usar wlan0 para clientes locais, configure como Access Point (Hostapd)
allow-hotplug wlan0
iface wlan0 inet manual
EOF

# 9. Desabilitar dhcpcd (Conflito com interfaces)
echo -e "${YELLOW}>> Desabilitando gerenciador dhcpcd...${NC}"
systemctl stop dhcpcd
systemctl disable dhcpcd

# 10. Habilitar Encaminhamento IP (Segurança/Redundância)
echo -e "${YELLOW}>> Habilitando IP Forward no sysctl...${NC}"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# 11. Habilitar serviço de networking
systemctl enable networking

echo -e "${GREEN}=== CONFIGURAÇÃO FINALIZADA COM SUCESSO ===${NC}"
echo -e "${YELLOW}IMPORTANTE:${NC}"
echo "1. O roteador TP-Link deve estar configurado para aceitar WDS/4addr."
echo "2. O wlan0 (interno) NÃO está na bridge para evitar falhas de conexão."
echo "3. Reinicie o Raspberry Pi agora: sudo reboot"

read -p "Deseja reiniciar agora? (s/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    reboot
fi