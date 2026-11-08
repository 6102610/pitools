#!/usr/bin/env bash
set -euo pipefail

RPI_OUI_REGEX="^(98:fe:54|dc:a6:32|e4:5f:01|28:cd:c1|d8:3a:dd|b8:27:eb)"

echo "=========================================================="
echo "         Scansione Raspberry Pi (OUI Hex Matching)"
echo "=========================================================="

# 1. Rilevamento IP e Subnet dell'adattatore fisico Windows
WIN_IP=$(powershell.exe -NoProfile -Command "
  Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { \$_.InterfaceAlias -notmatch 'vEthernet|Loopback' -and \$_.IPAddress -notlike '169.254*' -and \$_.IPAddress -notlike '127.*' } |
  Select-Object -ExpandProperty IPAddress -First 1
" 2>/dev/null | tr -d '\r\n')

if [ -z "$WIN_IP" ]; then
    echo "[!] Impossibile determinare l'IP host Windows. Fallback: 192.168.0.0/24"
    SUBNET_PREFIX="192.168.0"
else
    SUBNET_PREFIX=$(echo "$WIN_IP" | cut -d. -f1-3)
    echo "[+] Subnet fisica attiva: ${SUBNET_PREFIX}.0/24 (Host Windows: $WIN_IP)"
fi

echo "[*] Forzatura popolamento ARP su host Windows e scansione porta 22..."

# 2. Scansione rapida porte 22 da WSL2 (genera traffico L3 verso la rete fisica)
ACTIVE_IPS=()
for i in {1..254}; do
    TARGET_IP="${SUBNET_PREFIX}.$i"
    (
        if nc -z -w 1 "$TARGET_IP" 22 2>/dev/null; then
            echo "$TARGET_IP" >> /tmp/pifind_active.tmp
        fi
    ) &
    if (( i % 64 == 0 )); then wait; fi
done
wait

touch /tmp/pifind_active.tmp
mapfile -t ACTIVE_IPS < <(sort -u /tmp/pifind_active.tmp 2>/dev/null || true)
rm -f /tmp/pifind_active.tmp

printf "\n%-16s %-18s %-12s %-15s %-20s\n" "IP ADDRESS" "MAC ADDRESS" "OUI STATUS" "SSH (PORT 22)" "HOSTNAME"
echo "-------------------------------------------------------------------------------------"

FOUND_COUNT=0

# Se abbiamo trovato host con porta 22 aperta, interroghiamo Windows per ciascuno
for IP in "${ACTIVE_IPS[@]}"; do
    [ -z "$IP" ] && continue

    # Forza Windows a inviare un pacchetto ARP verso l'IP rilevato
    powershell.exe -NoProfile -Command "Test-Connection -ComputerName $IP -Count 1 -Quiet" >/dev/null 2>&1 || true

    # Recupera il MAC da Windows (arp -a o Get-NetNeighbor)
    RAW_MAC=$(powershell.exe -NoProfile -Command "
      (Get-NetNeighbor -IPAddress '$IP' -AddressFamily IPv4 2>\$null | Select-Object -ExpandProperty LinkLayerAddress -First 1)
    " 2>/dev/null | tr -d '\r\n')

    # Fallback su arp.exe standard se Get-NetNeighbor fallisce
    if [ -z "$RAW_MAC" ]; then
        RAW_MAC=$(powershell.exe -NoProfile -Command "arp -a $IP" 2>/dev/null | grep -E "([0-9a-fA-F]{2}[-:]){5}[0-9a-fA-F]{2}" | awk '{print $2}' | tr -d '\r\n')
    fi

    [ -z "$RAW_MAC" ] && continue

    # Normalizza formato MAC in esadecimale standard (xx:xx:xx:xx:xx:xx)
    CLEAN_MAC=$(echo "$RAW_MAC" | tr '[:upper:]' '[:lower:]' | tr '-' ':')

    # Controllo OUI
    if echo "$CLEAN_MAC" | grep -Ei "$RPI_OUI_REGEX" >/dev/null 2>&1; then
        FOUND_COUNT=$((FOUND_COUNT + 1))
        
        # Risoluzione hostname
        HOST=$(getent hosts "$IP" 2>/dev/null | awk '{print $2}' || true)
        [ -z "$HOST" ] && HOST="-"

        printf "%-16s %-18s %-12s %-15s %-20s\n" "$IP" "$CLEAN_MAC" "MATCH (RPi)" "OPEN" "$HOST"
    fi
done

echo "-------------------------------------------------------------------------------------"
echo "[✓] Scansione completata: $FOUND_COUNT dispositivo/i Raspberry Pi rilevato/i."
