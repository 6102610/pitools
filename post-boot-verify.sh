#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "    Raspberry Pi 5 - Verifica Dispositivo di Boot"
echo "=========================================================="

ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
ROOT_UUID=$(findmnt -n -o UUID / || true)

echo "Rootfs montato su: $ROOT_SOURCE ($ROOT_FSTYPE)"

if [[ "$ROOT_SOURCE" =~ ^/dev/nvme[0-9]n[0-9]p ]]; then
    echo ">> ESITO: Avviato con successo da disco NVMe M.2 [OK]"
elif [[ "$ROOT_SOURCE" =~ ^/dev/sd[a-z][0-9] ]]; then
    echo ">> ESITO: Avviato con successo da memoria USB [OK]"
elif [[ "$ROOT_SOURCE" =~ ^/dev/mmcblk0p ]]; then
    echo ">> ESITO: Avviato da microSD [FALLBACK]"
else
    echo ">> ESITO: Dispositivo di avvio non riconosciuto ($ROOT_SOURCE)"
fi

echo "----------------------------------------------------------"
echo "Dettaglio partizioni e punti di mount correnti:"
lsblk -o NAME,TYPE,SIZE,MOUNTPOINTS,MODEL

echo "----------------------------------------------------------"
echo "Configurazione EEPROM attiva:"
vcgencmd bootloader_config | grep -E "BOOT_ORDER|PCIE_PROBE|USB_MSD" || true
echo "=========================================================="
