#!/usr/bin/env bash
set -euo pipefail

BOARD_MODEL="Sconosciuto"
if [[ -f /proc/device-tree/model ]]; then
    BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-Linux}"
else
    DISTRO_NAME="Linux (Sconosciuto)"
fi
KERNEL_VER=$(uname -r)
ARCH_TYPE=$(uname -m)

echo "=========================================================="
echo "    Verifica Dispositivo di Boot"
echo "=========================================================="
echo "Hardware    : $BOARD_MODEL"
echo "SO Rilevato : $DISTRO_NAME"
echo "Kernel      : $KERNEL_VER ($ARCH_TYPE)"
echo "----------------------------------------------------------"

ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

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
echo "Storage montato attualmente:"
lsblk -o NAME,TYPE,SIZE,MOUNTPOINTS,MODEL

echo "----------------------------------------------------------"
echo "Parametri Bootloader EEPROM:"

# Su Ubuntu/Debian assicura la presenza di libraspberrypi-bin o rpi-eeprom
if ! command -v vcgencmd >/dev/null 2>&1 && ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "[*] Tool EEPROM non trovati. Tentativo di installazione..."
    sudo apt-get update -qq && sudo apt-get install -y -qq libraspberrypi-bin rpi-eeprom >/dev/null 2>&1 || true
fi

# Lettura configurazione attiva
if command -v vcgencmd >/dev/null 2>&1; then
    sudo vcgencmd bootloader_config 2>/dev/null | grep -E "BOOT_ORDER|PCIE_PROBE|USB_MSD" || true
elif command -v rpi-eeprom-config >/dev/null 2>&1; then
    sudo rpi-eeprom-config 2>/dev/null | grep -E "BOOT_ORDER|PCIE_PROBE|USB_MSD" || true
else
    echo "[WARN] Impossibile leggere la configurazione EEPROM (libraspberrypi-bin mancante)."
fi
echo "=========================================================="
