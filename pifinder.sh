#!/usr/bin/env bash
set -e

# Prefissi OUI ufficiali Raspberry Pi Ltd / Trading / Foundation
# Include: 98:fe:54, 28:cd:c1, b8:27:eb, dc:a6:32, e4:5f:01, d8:3a:dd, 2c:cf:67
RPI_OUI="98:fe:54|28:cd:c1|b8:27:eb|dc:a6:32|e4:5f:01|d8:3a:dd|2c:cf:67"

echo "=========================================================="
echo "         Scansione Raspberry Pi nella Rete Locale         "
echo "=========================================================="

# 1. Rileva se stiamo girando in ambiente WSL o Linux nativo
IS_WSL=0
if grep -qi "microsoft" /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
    IS_WSL=1
fi

SUBNET=""
if [ $IS_WSL -eq 1 ]; then
    echo "[*] Ambiente WSL2 rilevato: interrogazione scheda fisica Windows..."
    WIN_IP_INFO=$(powershell.exe -NoProfile -Command "
        Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { \$_.InterfaceAlias -notmatch 'vEthernet|Loopback|WSL' -and \$_.IPAddress -notlike '169.254*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    " 2>/dev/null | tr -d '\r')

    if [ -n "$WIN_IP_INFO" ]; then
        SUBNET=$(echo "$WIN_IP_INFO" | cut -d'.' -f1-3)
        echo "[+] Subnet fisica rilevata: ${SUBNET}.0/24 (Host IP: ${WIN_IP_INFO})"
    fi
fi

# Fallback se Linux nativo o se PowerShell fallisce
if [ -z "$SUBNET" ]; then
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
    LOCAL_IP=$(ip -o -f inet addr show dev "$DEFAULT_IFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)
    if [ -n "$LOCAL_IP" ]; then
        SUBNET=$(echo "$LOCAL_IP" | cut -d'.' -f1-3)
        echo "[+] Subnet rilevata da Linux: ${SUBNET}.0/24 (IP: ${LOCAL_IP})"
    else
        read -rp "Impossibile determinare la subnet. Inserisci i primi 3 ottetti (es. 192.168.0): " SUBNET
    fi
fi

echo "[*] Scansione host attivi con porta SSH (22) aperta su ${SUBNET}.1 - 254..."

TMP_ACTIVE=$(mktemp)
trap 'rm -f "$TMP_ACTIVE"' EXIT

# Sweep rapido TCP porta 22 (timeout 400ms per IP)
for i in $(seq 1 254); do
    (
        IP="${SUBNET}.${i}"
        if timeout 0.4 bash -c "true &>/dev/null > /dev/tcp/${IP}/22" 2>/dev/null; then
            echo "$IP" >> "$TMP_ACTIVE"
        fi
    ) &
done
wait

ACTIVE_IPS=($(sort -V "$TMP_ACTIVE" 2>/dev/null || true))

if [ ${#ACTIVE_IPS[@]} -eq 0 ]; then
    echo "[-] Nessun host con porta 22 attiva trovato su ${SUBNET}.0/24."
    exit 0
fi

echo "----------------------------------------------------------------------------------"
printf "%-16s %-18s %-25s %-20s %s\n" "IP ADDRESS" "MAC ADDRESS" "VENDOR / BANNER" "HOSTNAME" "NOTE"
echo "----------------------------------------------------------------------------------"

PI_COUNT=0

for IP in "${ACTIVE_IPS[@]}"; do
    MAC=""
    if [ $IS_WSL -eq 1 ]; then
        MAC=$(powershell.exe -NoProfile -Command "
            Get-NetNeighbor -IPAddress '$IP' 2>\$null | Select-Object -ExpandProperty LinkLayerAddress
        " 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    else
        MAC=$(ip neigh show "$IP" 2>/dev/null | awk '{print $5}')
    fi
    MAC=${MAC:-"<non in arp>"}

    # FIX BANNER: Aggiunto '-a' (tratta come testo) per bypassare l'errore file binario su Dropbear
    BANNER=$(timeout 0.8 nc -nv -w 1 "$IP" 22 2>&1 | grep -a -i "SSH" | head -n1 | tr -d '\r' || true)

    # FIX FILTER: Esclude host non-Raspberry tramite MAC OUI e che non usano OpenSSH (es. Dropbear)
    if [[ ! "$MAC" =~ ^($RPI_OUI) ]] && [[ ! "$BANNER" =~ OpenSSH ]]; then
        continue
    fi

    ((PI_COUNT++))

    # Risoluzione hostname
    HOST=$(timeout 0.5 getent hosts "$IP" 2>/dev/null | awk '{print $2}' || true)
    if [ -z "$HOST" ]; then
        HOST=$(timeout 0.5 ping -c 1 -W 1 -a "$IP" 2>/dev/null | grep -oP 'from \K[^\s]+' || true)
        HOST=${HOST:-"-"}
    fi

    TAG="[RASPBERRY PI]"

    printf "%-16s %-18s %-25s %-20s %s\n" "$IP" "$MAC" "${BANNER:0:24}" "${HOST:0:19}" "$TAG"
done
echo "----------------------------------------------------------------------------------"
echo "[+] Trovati $PI_COUNT Raspberry Pi confermati."
