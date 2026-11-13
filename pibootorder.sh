#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Questo script deve essere eseguito come root (usa sudo)."
    exit 1
fi

MODE="${1:-toggle}" # Accetta: sd | external | toggle

BOARD_MODEL="Sconosciuto"
IS_PI5=0
if [[ -f /proc/device-tree/model ]]; then
    BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    [[ "$BOARD_MODEL" =~ "Raspberry Pi 5" ]] && IS_PI5=1
fi

if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq rpi-eeprom
fi

CURRENT_CONF=$(rpi-eeprom-config)
CURRENT_ORDER=$(echo "$CURRENT_CONF" | grep "^BOOT_ORDER=" | cut -d'=' -f2 | tr -d '[:space:]' || true)

# Definizione codici BOOT_ORDER (letti da destra verso sinistra dal bootloader)
# 1 = microSD | 4 = USB-MSD | 6 = NVMe
if [[ $IS_PI5 -eq 1 ]]; then
    ORDER_EXT="0xf146" # Priorita: NVMe (6) -> USB (4) -> SD (1)
    ORDER_SD="0xf461"  # Priorita: SD (1) -> NVMe (6) -> USB (4)
else
    ORDER_EXT="0xf14"  # Priorita: USB (4) -> SD (1)
    ORDER_SD="0xf41"   # Priorita: SD (1) -> USB (4)
fi

# Logica di selezione / inversione
TARGET_ORDER=""
TARGET_DESC=""

case "$MODE" in
    sd)
        TARGET_ORDER="$ORDER_SD"
        TARGET_DESC="microSD First (SD -> NVMe/USB)"
        ;;
    ext|external|usb|nvme)
        TARGET_ORDER="$ORDER_EXT"
        TARGET_DESC="External First (NVMe/USB -> SD)"
        ;;
    toggle)
        # Se finisce per '1' siamo gia in SD-first -> inverti a External-first
        if [[ "$CURRENT_ORDER" == *1 ]]; then
            TARGET_ORDER="$ORDER_EXT"
            TARGET_DESC="External First (NVMe/USB -> SD)"
        else
            TARGET_ORDER="$ORDER_SD"
            TARGET_DESC="microSD First (SD -> NVMe/USB)"
        fi
        ;;
    *)
        echo "Uso: sudo bash pibootorder.sh [toggle|sd|external]"
        exit 1
        ;;
esac

echo "================================================================="
echo "         PiBootOrder - Switch Ordine di Boot EEPROM              "
echo "================================================================="
echo "Hardware rilevato : $BOARD_MODEL"
echo "BOOT_ORDER attuale: ${CURRENT_ORDER:-default}"
echo "BOOT_ORDER nuovo  : $TARGET_ORDER ($TARGET_DESC)"
echo "-----------------------------------------------------------------"

NEW_CONF_FILE=$(mktemp)
echo "$CURRENT_CONF" | grep -v -E "^(BOOT_ORDER|PCIE_PROBE|USB_MSD_PWR_OFF_TIME|USB_MSD_DISCOVER_TIMEOUT)=" > "$NEW_CONF_FILE"

if [[ $IS_PI5 -eq 1 ]]; then
    cat << EEPROM_EOF >> "$NEW_CONF_FILE"
BOOT_ORDER=$TARGET_ORDER
PCIE_PROBE=1
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_EOF
else
    cat << EEPROM_EOF >> "$NEW_CONF_FILE"
BOOT_ORDER=$TARGET_ORDER
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_EOF
fi

rpi-eeprom-config --apply "$NEW_CONF_FILE"
rm -f "$NEW_CONF_FILE"

# Se Pi 5, abilita anche il bus PCIe sulla microSD corrente per vedere /dev/nvme0n1 da Linux
if [[ $IS_PI5 -eq 1 ]]; then
    for cfg in /boot/firmware/config.txt /boot/config.txt; do
        if [[ -f "$cfg" ]]; then
            for param in "dtparam=pciex1" "dtparam=pciex1_gen=3"; do
                grep -q "^${param}" "$cfg" || echo "$param" >> "$cfg"
            done
        fi
    done
fi

APPLIED_ORDER=$(rpi-eeprom-config | grep "^BOOT_ORDER=" | cut -d'=' -f2 || true)
echo "[OK] EEPROM aggiornata con successo: BOOT_ORDER=$APPLIED_ORDER"
echo "================================================================="

read -rp "Azione post-aggiornamento: [r]eboot / [p]oweroff / [n]essuna (r/p/N): " ACTION </dev/tty
case "$ACTION" in
    [rR])
        echo "[*] Riavvio in corso..."
        sleep 1
        reboot
        ;;
    [pP])
        echo "[*] Spegnimento in corso (attendi il LED rosso prima di collegare il cavo PCIe)..."
        sleep 1
        poweroff
        ;;
    *)
        echo "[INFO] Modifica pronta per il prossimo avvio."
        ;;
esac
