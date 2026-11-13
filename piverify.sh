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

# Controllo Negoziazione PCIe (se presente controller NVMe)
if lspci -d ::0108 >/dev/null 2>&1; then
    echo "----------------------------------------------------------"
    echo "Stato Bus PCIe NVMe:"
    LNK_STA=$(sudo lspci -vvv -d ::0108 2>/dev/null | grep -E "LnkSta:" | head -n1 || true)
    if [[ -n "$LNK_STA" ]]; then
        echo "  $LNK_STA"
        if [[ "$LNK_STA" =~ "Speed 8GT/s" ]]; then
            echo "  >> PCIe Gen 3 ATTIVO (8 GT/s) [VELOCITA MASSIMA]"
        elif [[ "$LNK_STA" =~ "Speed 5GT/s" ]]; then
            echo "  >> PCIe Gen 2 ATTIVO (5 GT/s)"
        fi
    fi
fi

echo "----------------------------------------------------------"
echo "Parametri Bootloader EEPROM:"

wait_for_apt_and_cloud_init() {
    if command -v cloud-init >/dev/null 2>&1; then
        local CI_STATUS
        CI_STATUS=$(cloud-init status 2>/dev/null || true)
        if [[ "$CI_STATUS" =~ "running" ]]; then
            echo "[*] cloud-init in corso: attesa completamento primo avvio..."
            cloud-init status --wait >/dev/null 2>&1 || true
        fi
    fi

    local TIMEOUT=120
    local ELAPSED=0
    local LOCK_FILES=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")

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

        [[ $LOCKED -eq 0 ]] && break

        sleep 2
        ELAPSED=$((ELAPSED + 2))
        [[ $ELAPSED -ge $TIMEOUT ]] && break
    done
}

if ! command -v vcgencmd >/dev/null 2>&1 && ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    echo "[*] Tool diagnostici EEPROM non trovati sul sistema..."
    if command -v apt-get >/dev/null 2>&1; then
        wait_for_apt_and_cloud_init
        sudo apt-get update -qq && sudo apt-get install -y -qq libraspberrypi-bin rpi-eeprom >/dev/null 2>&1 || true
    fi
fi

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
    echo "[WARN] Impossibile interrogare l'EEPROM."
fi
echo "=========================================================="
