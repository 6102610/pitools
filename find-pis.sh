#!/usr/bin/env bash
set -euo pipefail

# Dipendenze consigliate: iproute2, arp-scan (oppure nmap / arp)
echo "=========================================================="
echo "         Scansione Raspberry Pi nella Rete Locale         "
echo "=========================================================="

# 1. Rileva interfaccia di default e subnet locale
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
if [[ -z "$DEFAULT_IFACE" ]]; then
    echo "[ERROR] Impossibile determinare l'interfaccia di rete primaria."
    exit 1
fi

LOCAL_CIDR=$(ip -o -f inet addr show dev "$DEFAULT_IFACE" | awk '{print $4}' | head -n1 || true)
echo "[*] Interfaccia attiva : $DEFAULT_IFACE"
echo "[*] Subnet rilevata     : $LOCAL_CIDR"
echo "----------------------------------------------------------"

# OUI noti Raspberry Pi (Raspberry Pi Ltd / Trading / Foundation)
# b8:27:eb, dc:a6:32, e4:5f:01, 28:cd:c1, d8:3a:dd, 2c:cf:67
RPI_OUI_REGEX="(b8:27:eb|dc:a6:32|e4:5f:01|28:cd:c1|d8:3a:dd|2c:cf:67)"

echo "Ricerca nodi in corso..."

FOUND=0

# Metodo 1: arp-scan (il più preciso e veloce se presente con privilegi sudo)
if command -v arp-scan >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
    while read -r ip mac desc; do
        if [[ "$mac" =~ $RPI_OUI_REGEX ]] || [[ "$desc" =~ [Rr]aspberry ]]; then
            HOSTNAME=$(getent hosts "$ip" | awk '{print $2}' || echo "n/a")
            printf "  [+] IP: %-15s | MAC: %-17s | Host: %s\n" "$ip" "$mac" "$HOSTNAME"
            FOUND=$((FOUND + 1))
        fi
    done < <(arp-scan --interface="$DEFAULT_IFACE" --localnet 2>/dev/null | grep -E "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")

# Metodo 2: Popolamento ARP cache tramite ping sweep e lettura ip neigh
else
    # Ping broadcast/sweep rapido per popolare la tabella ARP
    SUBNET_PREFIX=$(echo "$LOCAL_CIDR" | cut -d'.' -f1-3)
    
    echo "[*] Generazione traffico ARP sulla subnet $SUBNET_PREFIX.0/24..."
    for i in {1..254}; do
        ping -c 1 -W 1 "$SUBNET_PREFIX.$i" >/dev/null 2>&1 &
    done
    wait

    while read -r ip _ _ mac _; do
        if [[ "$mac" =~ $RPI_OUI_REGEX ]]; then
            HOSTNAME=$(getent hosts "$ip" | awk '{print $2}' || echo "n/a")
            printf "  [+] IP: %-15s | MAC: %-17s | Host: %s\n" "$ip" "$mac" "$HOSTNAME"
            FOUND=$((FOUND + 1))
        fi
    done < <(ip neigh show dev "$DEFAULT_IFACE" | grep -v FAILED)
fi

# Metodo 3: Lookup mDNS standard (avahi/zeroconf)
echo "----------------------------------------------------------"
echo "[*] Controllo host mDNS (raspberrypi.local):"
for h in raspberrypi.local; do
    if IP_MDNS=$(getent hosts "$h" 2>/dev/null | awk '{print $1}'); then
        echo "  [mDNS] $h -> $IP_MDNS"
    fi
done

echo "----------------------------------------------------------"
if [[ $FOUND -eq 0 ]]; then
    echo "[INFO] Nessun Raspberry Pi identificato tramite MAC OUI standard."
    echo "Suggerimento: Esegui con 'sudo' o installa 'arp-scan' (sudo apt install arp-scan)."
else
    echo "[OK] Nodi Raspberry Pi trovati: $FOUND"
fi
echo "=========================================================="
