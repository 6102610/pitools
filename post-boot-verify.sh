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

# Funzione per attendere la fine dei task di post-installazione (cloud-init e APT)
wait_for_apt_and_cloud_init() {
    # 1. Attesa completamento cloud-init (se in esecuzione)
    if command -v cloud-init >/dev/null 2>&1; then
        local CI_STATUS
        CI_STATUS=$(cloud-init status 2>/dev/null || true)
        if [[ "$CI_STATUS" =~ "running" ]]; then
            echo "[*] cloud-init in corso: attesa completamento primo avvio..."
            cloud-init status --wait >/dev/null 2>&1 || true
        fi
    fi

    # 2. Attesa rilascio lock APT / DPKG
    local TIMEOUT=120
    local ELAPSED=0
    local LOCK_FILES=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
    )

    while true; do
        local LOCKED=0
        for lock in "${LOCK_FILES[@]}"; do
            if [[ -f "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
                LOCKED=1
                break
            fi
        done

        if pgrep -f "unattended-upgrade|apt.systemd.daily" >/dev/null 2>&1; then
            LOCKED=1
        fi

        if [[ $LOCKED -eq 0 ]]; then
            break
        fi

        if [[ $ELAPSED -eq 0 ]]; then
            echo "[*] Gestore pacchetti occupato in background. Attesa rilascio lock..."
        fi

        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [[ $ELAPSED -ge $TIMEOUT ]]; then
            echo "[WARN] Timeout di attesa lock APT ($TIMEOUT s) superato. Procedo comunque."
            break
        fi
    done
}

# Se mancano i comandi per interrogare il firmware, installali attendendo il lock
if ! command -v vcgencmd >/dev/null 2>&1 && ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "[*] Tool diagnostici EEPROM non trovati sul sistema..."
    if command -v apt-get >/dev/null 2>&1; then
        wait_for_apt_and_cloud_init
        echo "[*] Installazione libraspberrypi-bin e rpi-eeprom in corso..."
        sudo apt-get update -qq && sudo apt-get install -y -qq libraspberrypi-bin rpi-eeprom >/dev/null 2>&1 || true
    fi
fi

# Lettura dei parametri con fallback
CONFIG_OUT=""
if command -v vcgencmd >/dev/null 2>&1; then
    CONFIG_OUT=$(sudo vcgencmd bootloader_config 2>/dev/null || true)
fi

if [[ -z "$CONFIG_OUT" ]] && command -v rpi-eeprom-config >/dev/null 2>&1; then
    CONFIG_OUT=$(sudo rpi-eeprom-config 2>/dev/null || true)
fi

if [[ -n "$CONFIG_OUT" ]]; then
    echo "$CONFIG_OUT" | grep -E "BOOT_ORDER|PCIE_PROBE|USB_MSD" || true
else
    echo "[WARN] Impossibile interrogare l'EEPROM (verifica che il pacchetto libraspberrypi-bin sia installato e riesegui con sudo)."
fi
echo "=========================================================="
