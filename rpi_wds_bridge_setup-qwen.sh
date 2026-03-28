#!/usr/bin/env bash
# =============================================================================
# rpi_wds_bridge_setup.sh
# Configuração automatizada de Bridge Wi-Fi (WDS via wlan1 USB) no Raspberry Pi
# Autor: Techne Solutions | Alexandre
# =============================================================================

set -euo pipefail

# ── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✔]${RESET} $*"; }
info() { echo -e "${CYAN}[i]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✘]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }
sep()  { echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"; }

# ── Variáveis configuráveis ───────────────────────────────────────────────────
SSID="${SSID:-}"
PSK="${PSK:-}"
COUNTRY="${COUNTRY:-BR}"

IFACE_WLAN_USB="${IFACE_WLAN_USB:-}"   # ex: wlan1 — será auto-detectado se vazio
IFACE_WLAN_INT="${IFACE_WLAN_INT:-}"   # ex: wlan0 — será auto-detectado se vazio
IFACE_ETH="${IFACE_ETH:-}"             # ex: eth0  — será auto-detectado se vazio
BRIDGE="${BRIDGE:-br0}"

WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${BRIDGE}.conf"
NET_IFACES="/etc/network/interfaces"
SYSCTL_CONF="/etc/sysctl.conf"
BACKUP_DIR="/etc/network/backup_$(date +%Y%m%d_%H%M%S)"

# ── Verificações iniciais ────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Execute como root: sudo $0"
}

check_os() {
    grep -qi "raspberry\|raspbian\|debian" /etc/os-release 2>/dev/null \
        || warn "OS não reconhecido como Raspberry Pi OS / Debian — continuando mesmo assim."
}

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${CYAN}"
    cat <<'EOF'
  ____  ____  _   __        ______  ____    ____       _     _            
 |  _ \|  _ \(_) / /_      / /  _ \/ ___|  | __ ) _ __(_) __| | __ _  ___ 
 | |_) | |_) | || '_ \    / /| |_) \___ \  |  _ \| '__| |/ _` |/ _` |/ _ \
 |  _ <|  __/| || (_) |  / / |  __/ ___) | | |_) | |  | | (_| | (_| |  __/
 |_| \_\_|  |_||_|\___/  /_/  |_|   |____/  |____/|_|  |_|\__,_|\__, |\___|
                                                                  |___/     
EOF
    echo -e "${RESET}"
    echo -e "  ${BOLD}Configuração automatizada de Bridge Wi-Fi WDS — Techne Solutions${RESET}"
    sep
}

# ── Detecção automática de interfaces ────────────────────────────────────────
detect_interfaces() {
    sep
    info "Detectando interfaces de rede..."
    echo

    # Ethernet
    if [[ -z "$IFACE_ETH" ]]; then
        IFACE_ETH=$(ip -o link show | awk -F': ' '{print $2}' \
            | grep -E '^eth|^en' | head -1 || true)
    fi

    # Wi-Fi interfaces
    local wifi_ifaces
    wifi_ifaces=$(ip -o link show | awk -F': ' '{print $2}' \
        | grep -E '^wlan' || true)

    if [[ -z "$wifi_ifaces" ]]; then
        die "Nenhuma interface Wi-Fi detectada. Verifique o hardware."
    fi

    local wifi_count
    wifi_count=$(echo "$wifi_ifaces" | wc -l)

    if [[ $wifi_count -lt 2 ]]; then
        err "Apenas $wifi_count interface Wi-Fi encontrada. São necessárias 2 (interna + USB)."
        die "Conecte o adaptador USB Wi-Fi e tente novamente."
    fi

    # wlan0 = interna, wlan1 = USB (ou detecta pelo driver)
    if [[ -z "$IFACE_WLAN_INT" ]]; then
        IFACE_WLAN_INT=$(echo "$wifi_ifaces" | head -1)
    fi
    if [[ -z "$IFACE_WLAN_USB" ]]; then
        IFACE_WLAN_USB=$(echo "$wifi_ifaces" | tail -1)
    fi

    log "Ethernet  : ${BOLD}${IFACE_ETH:-NÃO ENCONTRADA}${RESET}"
    log "Wi-Fi Int : ${BOLD}$IFACE_WLAN_INT${RESET} (placa interna do Pi)"
    log "Wi-Fi USB : ${BOLD}$IFACE_WLAN_USB${RESET} (adaptador USB)"
    log "Bridge    : ${BOLD}$BRIDGE${RESET}"
    echo
}

# ── Verificação de suporte a 4-address (WDS) ─────────────────────────────────
check_4addr_support() {
    sep
    info "Verificando suporte a modo 4-address (WDS) em $IFACE_WLAN_USB..."
    echo

    local supports_wds=false

    # Testa via iw
    if iw dev "$IFACE_WLAN_USB" set 4addr on &>/dev/null; then
        supports_wds=true
        iw dev "$IFACE_WLAN_USB" set 4addr off &>/dev/null || true
    fi

    if $supports_wds; then
        log "${BOLD}$IFACE_WLAN_USB${RESET} suporta modo 4-address (WDS). Prosseguindo com bridge transparente."
        WDS_MODE=true
    else
        warn "${BOLD}$IFACE_WLAN_USB${RESET} NÃO suporta 4-address."
        warn "O modo bridge Wi-Fi puro não funcionará — o roteador irá bloquear pacotes com MACs diferentes."
        echo
        warn "AÇÃO RECOMENDADA: Use NAT (masquerade) no lugar de bridge para wlan1."
        warn "Este script irá configurar bridge para eth0/wlan0 locais e NAT para wlan1 USB."
        echo
        WDS_MODE=false
    fi
}

# ── Solicitar credenciais Wi-Fi interativamente ──────────────────────────────
prompt_wifi_credentials() {
    sep
    info "Configuração da rede Wi-Fi do TP-Link"
    echo

    if [[ -z "$SSID" ]]; then
        read -rp "  SSID (nome da rede Wi-Fi): " SSID
    else
        info "SSID via variável de ambiente: $SSID"
    fi

    [[ -n "$SSID" ]] || die "SSID não pode estar vazio."

    if [[ -z "$PSK" ]]; then
        read -rsp "  Senha Wi-Fi: " PSK
        echo
    else
        info "PSK via variável de ambiente: [oculta]"
    fi

    [[ -n "$PSK" ]] || die "Senha não pode estar vazia."

    echo
    log "Credenciais capturadas."
}

# ── Backup das configurações atuais ──────────────────────────────────────────
backup_configs() {
    sep
    info "Fazendo backup das configurações existentes em $BACKUP_DIR ..."

    mkdir -p "$BACKUP_DIR"

    [[ -f "$NET_IFACES" ]] && cp "$NET_IFACES" "$BACKUP_DIR/"
    [[ -f "$SYSCTL_CONF" ]] && cp "$SYSCTL_CONF" "$BACKUP_DIR/"
    [[ -f /etc/dhcpcd.conf ]] && cp /etc/dhcpcd.conf "$BACKUP_DIR/" || true

    # Backup de qualquer wpa_supplicant existente
    find /etc/wpa_supplicant/ -name "*.conf" -exec cp {} "$BACKUP_DIR/" \; 2>/dev/null || true

    log "Backup salvo em: ${BOLD}$BACKUP_DIR${RESET}"
}

# ── Instalação de dependências ────────────────────────────────────────────────
install_deps() {
    sep
    info "Instalando dependências..."

    apt-get update -qq
    apt-get install -y \
        bridge-utils \
        wpasupplicant \
        wireless-tools \
        iw \
        net-tools \
        iptables \
        iptables-persistent \
        rfkill \
        2>/dev/null

    log "Dependências instaladas."
}

# ── Desabilitar serviços conflitantes ─────────────────────────────────────────
disable_conflicting_services() {
    sep
    info "Desabilitando serviços conflitantes (dhcpcd, NetworkManager, wpa_supplicant global)..."

    local services=("dhcpcd" "NetworkManager" "wpa_supplicant")
    for svc in "${services[@]}"; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log "Desabilitado: $svc"
        else
            info "Serviço não ativo/encontrado: $svc — ignorado."
        fi
    done

    # Desbloquear Wi-Fi via rfkill
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock all  2>/dev/null || true
    log "rfkill: Wi-Fi desbloqueado."
}

# ── Configurar wpa_supplicant ─────────────────────────────────────────────────
configure_wpa_supplicant() {
    sep
    info "Configurando wpa_supplicant para $IFACE_WLAN_USB → SSID: $SSID ..."

    # Gera hash PSK seguro
    local hashed_psk
    hashed_psk=$(wpa_passphrase "$SSID" "$PSK" | grep -E '^\s+psk=' | grep -v '#' | tr -d ' ')

    cat > "$WPA_CONF" <<EOF
# Gerado por rpi_wds_bridge_setup.sh — $(date)
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$COUNTRY

network={
    ssid="$SSID"
    $hashed_psk
    mode=0
    key_mgmt=WPA-PSK
    proto=WPA2
    pairwise=CCMP
    group=CCMP
}
EOF

    chmod 600 "$WPA_CONF"
    log "wpa_supplicant configurado: ${BOLD}$WPA_CONF${RESET}"
}

# ── Configurar /etc/network/interfaces ───────────────────────────────────────
configure_network_interfaces() {
    sep
    info "Configurando /etc/network/interfaces ..."

    if $WDS_MODE; then
        # ── MODO BRIDGE TRANSPARENTE (wlan1 suporta 4-address) ──────────────
        cat > "$NET_IFACES" <<EOF
# Gerado por rpi_wds_bridge_setup.sh — $(date)
# MODO: Bridge transparente WDS (4-address suportado em $IFACE_WLAN_USB)

auto lo
iface lo inet loopback

# ── Bridge principal (recebe DHCP do roteador TP-Link) ──
auto $BRIDGE
iface $BRIDGE inet dhcp
    bridge_ports $IFACE_ETH $IFACE_WLAN_INT $IFACE_WLAN_USB
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 30
    bridge_waitport 0

# ── Ethernet: membro da bridge ──
allow-hotplug $IFACE_ETH
iface $IFACE_ETH inet manual
    pre-up ip link set \$IFACE promisc on || true

# ── Wi-Fi interno: membro da bridge ──
allow-hotplug $IFACE_WLAN_INT
iface $IFACE_WLAN_INT inet manual

# ── Wi-Fi USB: conecta ao TP-Link com 4-address (WDS) ──
allow-hotplug $IFACE_WLAN_USB
iface $IFACE_WLAN_USB inet manual
    pre-up iw dev $IFACE_WLAN_USB set 4addr on || true
    pre-up wpa_supplicant -B -D nl80211,wext -i $IFACE_WLAN_USB -c $WPA_CONF -P /run/wpa_supplicant-$IFACE_WLAN_USB.pid || true
    post-down wpa_cli -i $IFACE_WLAN_USB terminate || true
EOF
        log "interfaces configurado em modo BRIDGE TRANSPARENTE (WDS)."

    else
        # ── MODO NAT/MASQUERADE (wlan1 NÃO suporta 4-address) ───────────────
        cat > "$NET_IFACES" <<EOF
# Gerado por rpi_wds_bridge_setup.sh — $(date)
# MODO: Bridge local (eth0+wlan0) + NAT via wlan1 USB (sem suporte a 4-address)

auto lo
iface lo inet loopback

# ── Wi-Fi USB: uplink para o roteador TP-Link (obtém IP por DHCP) ──
auto $IFACE_WLAN_USB
iface $IFACE_WLAN_USB inet dhcp
    pre-up rfkill unblock wifi || true
    pre-up wpa_supplicant -B -D nl80211,wext -i $IFACE_WLAN_USB -c $WPA_CONF -P /run/wpa_supplicant-$IFACE_WLAN_USB.pid || true
    post-down wpa_cli -i $IFACE_WLAN_USB terminate || true

# ── Bridge local (une eth0 + wlan0 internos) ──
auto $BRIDGE
iface $BRIDGE inet static
    address 192.168.50.1
    netmask 255.255.255.0
    bridge_ports $IFACE_ETH $IFACE_WLAN_INT
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 30

# ── Ethernet: membro da bridge ──
allow-hotplug $IFACE_ETH
iface $IFACE_ETH inet manual

# ── Wi-Fi interno (AP ou membro de bridge local) ──
allow-hotplug $IFACE_WLAN_INT
iface $IFACE_WLAN_INT inet manual
EOF
        log "interfaces configurado em modo NAT (bridge local + masquerade via wlan1)."
    fi
}

# ── Configurar sysctl (ip_forward) ────────────────────────────────────────────
configure_sysctl() {
    sep
    info "Ativando IP forwarding em $SYSCTL_CONF ..."

    # Remove entradas antigas e adiciona limpa
    sed -i '/^#*\s*net\.ipv4\.ip_forward/d' "$SYSCTL_CONF"
    sed -i '/^#*\s*net\.ipv6\.conf\.all\.forwarding/d' "$SYSCTL_CONF"

    cat >> "$SYSCTL_CONF" <<EOF

# ── Adicionado por rpi_wds_bridge_setup.sh — $(date) ──
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
# Evita que o kernel filtre pacotes em bridge
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-arptables=0
EOF

    sysctl -p "$SYSCTL_CONF" &>/dev/null || true
    log "IP forwarding ativado."
}

# ── Configurar iptables (apenas no modo NAT) ──────────────────────────────────
configure_iptables_nat() {
    if $WDS_MODE; then
        return  # Bridge transparente não precisa de NAT
    fi

    sep
    info "Configurando iptables NAT/MASQUERADE (wlan1 → br0) ..."

    # Limpar regras existentes
    iptables -t nat -F
    iptables -F FORWARD

    # MASQUERADE: pacotes saindo via wlan1 USB para a internet
    iptables -t nat -A POSTROUTING -o "$IFACE_WLAN_USB" -j MASQUERADE

    # Permitir encaminhamento entre bridge local e uplink USB
    iptables -A FORWARD -i "$BRIDGE" -o "$IFACE_WLAN_USB" -j ACCEPT
    iptables -A FORWARD -i "$IFACE_WLAN_USB" -o "$BRIDGE" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Salvar regras para persistência
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        log "Regras iptables salvas via netfilter-persistent."
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null \
            || warn "iptables-save falhou — instale iptables-persistent manualmente."
    fi

    log "NAT/MASQUERADE configurado."

    # Nota sobre DHCP no modo NAT
    echo
    warn "MODO NAT ATIVO: Os hosts conectados via eth0/wlan0 precisam de um servidor DHCP."
    warn "Instale dnsmasq para servir DHCP na faixa 192.168.50.0/24:"
    echo
    echo -e "  ${BOLD}sudo apt install dnsmasq${RESET}"
    echo -e "  Adicione em /etc/dnsmasq.conf:"
    echo -e "    interface=$BRIDGE"
    echo -e "    dhcp-range=192.168.50.100,192.168.50.200,255.255.255.0,24h"
    echo -e "    dhcp-option=3,192.168.50.1"
    echo
}

# ── Criar serviço systemd para wpa_supplicant por interface ───────────────────
create_wpa_service() {
    sep
    info "Criando serviço systemd dedicado para wpa_supplicant ($IFACE_WLAN_USB) ..."

    cat > "/etc/systemd/system/wpa_supplicant@${IFACE_WLAN_USB}.service" <<EOF
[Unit]
Description=WPA Supplicant — $IFACE_WLAN_USB
After=network.target
Wants=network.target

[Service]
Type=forking
PIDFile=/run/wpa_supplicant-$IFACE_WLAN_USB.pid
ExecStartPre=/sbin/iw dev $IFACE_WLAN_USB set 4addr $(if $WDS_MODE; then echo on; else echo off; fi) || true
ExecStart=/sbin/wpa_supplicant -B -D nl80211,wext \
    -i $IFACE_WLAN_USB \
    -c $WPA_CONF \
    -P /run/wpa_supplicant-$IFACE_WLAN_USB.pid
ExecStop=/sbin/wpa_cli -i $IFACE_WLAN_USB terminate || true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "wpa_supplicant@${IFACE_WLAN_USB}.service" 2>/dev/null || true
    log "Serviço wpa_supplicant@${IFACE_WLAN_USB} habilitado."
}

# ── Criar script de diagnóstico ───────────────────────────────────────────────
create_diag_script() {
    local diag_path="/usr/local/bin/rpi-bridge-diag"

    cat > "$diag_path" <<DIAG
#!/usr/bin/env bash
# Diagnóstico rápido da bridge Wi-Fi — gerado por rpi_wds_bridge_setup.sh
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
ok()  { echo -e "\${GREEN}[✔]\${RESET} \$*"; }
bad() { echo -e "\${RED}[✘]\${RESET} \$*"; }
inf() { echo -e "\${CYAN}[i]\${RESET} \$*"; }

echo -e "\${CYAN}═══ Diagnóstico Bridge Wi-Fi RPi ═══\${RESET}"

echo; inf "── Interfaces ──"
ip -br link show

echo; inf "── Endereços IP ──"
ip -br addr show

echo; inf "── Bridge $BRIDGE ──"
if brctl show $BRIDGE 2>/dev/null; then
    ok "Bridge $BRIDGE está ativa."
else
    bad "Bridge $BRIDGE não encontrada."
fi

echo; inf "── Rota padrão ──"
ip route show default

echo; inf "── wpa_supplicant ($IFACE_WLAN_USB) ──"
if wpa_cli -i $IFACE_WLAN_USB status 2>/dev/null | grep -q "COMPLETED"; then
    ok "Conectado ao AP."
    wpa_cli -i $IFACE_WLAN_USB status 2>/dev/null | grep -E "ssid|bssid|ip_address|key_mgmt"
else
    bad "wpa_supplicant não conectado ou não encontrado."
fi

echo; inf "── Teste de conectividade ──"
if ping -c 2 -W 2 8.8.8.8 &>/dev/null; then
    ok "Ping 8.8.8.8 OK (internet acessível)."
else
    bad "Ping 8.8.8.8 falhou."
fi

echo; inf "── Modo 4-address ($IFACE_WLAN_USB) ──"
iw dev $IFACE_WLAN_USB info 2>/dev/null | grep -i "4addr\|addr4" \
    && ok "4addr ativo." || inf "4addr não detectado (normal se modo NAT)."

echo; echo -e "\${CYAN}═══════════════════════════════════\${RESET}"
DIAG

    chmod +x "$diag_path"
    log "Script de diagnóstico criado: ${BOLD}rpi-bridge-diag${RESET}"
}

# ── Resumo final ──────────────────────────────────────────────────────────────
print_summary() {
    sep
    echo
    echo -e "  ${BOLD}${GREEN}✔ Configuração concluída!${RESET}"
    echo
    echo -e "  ${BOLD}Modo      :${RESET} $(if $WDS_MODE; then echo 'Bridge transparente (WDS 4-address)'; else echo 'NAT/Masquerade (wlan1 sem 4-address)'; fi)"
    echo -e "  ${BOLD}Uplink    :${RESET} $IFACE_WLAN_USB → SSID: $SSID"
    echo -e "  ${BOLD}Bridge    :${RESET} $BRIDGE ($IFACE_ETH + $IFACE_WLAN_INT)"
    echo -e "  ${BOLD}wpa conf  :${RESET} $WPA_CONF"
    echo -e "  ${BOLD}Backup    :${RESET} $BACKUP_DIR"
    echo
    echo -e "  ${BOLD}Próximos passos:${RESET}"
    echo -e "    1. ${BOLD}sudo reboot${RESET}"
    echo -e "    2. Após reiniciar: ${BOLD}rpi-bridge-diag${RESET}"
    if ! $WDS_MODE; then
        echo -e "    3. ${BOLD}sudo apt install dnsmasq${RESET} para DHCP nos hosts locais"
    fi
    echo
    sep
}

# ── Confirmação interativa ─────────────────────────────────────────────────────
confirm_proceed() {
    echo
    read -rp "  Pressione [ENTER] para continuar ou Ctrl+C para abortar..."
    echo
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════
main() {
    banner
    check_root
    check_os

    detect_interfaces
    check_4addr_support
    prompt_wifi_credentials

    sep
    echo -e "  ${YELLOW}Resumo do que será feito:${RESET}"
    echo -e "  • Backup de configurações atuais"
    echo -e "  • apt install: bridge-utils wpasupplicant wireless-tools iw iptables-persistent"
    echo -e "  • Desabilitar: dhcpcd, NetworkManager, wpa_supplicant global"
    echo -e "  • Escrever: $WPA_CONF"
    echo -e "  • Escrever: $NET_IFACES"
    echo -e "  • Ativar IP forwarding em $SYSCTL_CONF"
    if ! $WDS_MODE; then
        echo -e "  • Configurar iptables NAT/MASQUERADE"
    fi
    echo -e "  • Criar serviço systemd wpa_supplicant@$IFACE_WLAN_USB"
    echo -e "  • Criar script de diagnóstico: rpi-bridge-diag"
    confirm_proceed

    backup_configs
    install_deps
    disable_conflicting_services
    configure_wpa_supplicant
    configure_network_interfaces
    configure_sysctl
    configure_iptables_nat
    create_wpa_service
    create_diag_script
    print_summary

    read -rp "  Reiniciar agora? [s/N]: " resp
    if [[ "${resp,,}" == "s" ]]; then
        log "Reiniciando em 3 segundos..."
        sleep 3
        reboot
    else
        info "Reinicie manualmente com: ${BOLD}sudo reboot${RESET}"
    fi
}

main "$@"
