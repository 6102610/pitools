#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Questo script deve essere eseguito come root (usa sudo)."
   exit 1
fi

BOARD_MODEL="Sconosciuto"
IS_PI5=0
IS_PI4=0

if [[ -f /proc/device-tree/model ]]; then
    BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    if [[ "$BOARD_MODEL" =~ "Raspberry Pi 5" ]]; then
        IS_PI5=1
    elif [[ "$BOARD_MODEL" =~ "Raspberry Pi 4" ]]; then
        IS_PI4=1
    fi
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    CURRENT_OS="${PRETTY_NAME:-Linux}"
else
    CURRENT_OS="Linux (Sconosciuto)"
fi

echo "=========================================================="
echo "    Setup Boot Sequenziale Multi-Piattaforma"
echo "    Hardware Rilevato : $BOARD_MODEL"
echo "    SO Rilevato       : $CURRENT_OS"
echo "=========================================================="

ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" != *mmcblk0* ]]; then
    echo "[WARN] Attenzione: il sistema non risulta avviato da microSD (root su $ROOT_DEV)."
    read -rp "Vuoi proseguire comunque? (s/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || exit 1
else
    echo "[OK] Sistema avviato correttamente da microSD ($ROOT_DEV)."
fi

EXT_BOOT_DEV=""
for dev in /dev/sd[a-z]1 /dev/nvme[0-9]n[0-9]p1; do
    if [[ -b "$dev" ]]; then
        EXT_BOOT_DEV="$dev"
        break
    fi
done

if [[ -z "$EXT_BOOT_DEV" ]]; then
    echo "[ERROR] Nessuna partizione di boot esterna rilevata (/dev/sd*1 o /dev/nvme*p1)."
    exit 1
fi
echo "[OK] Rilevata partizione boot di destinazione: $EXT_BOOT_DEV"

# Configurazione PCIe Gen 3 e USB (specifica Pi 5)
if [[ $IS_PI5 -eq 1 ]]; then
    echo "[*] Configurazione PCIe Gen 3 (8 GT/s) e corrente USB..."

    apply_pi5_boot_params() {
        local boot_dir="$1"
        local cfg_file="$boot_dir/config.txt"
        local user_file="$boot_dir/usercfg.txt"

        [[ -f "$cfg_file" ]] || touch "$cfg_file"

        # Iniezione sicura su config.txt primario
        for param in "usb_max_current_enable=1" "dtparam=pciex1" "dtparam=pciex1_gen=3"; do
            if ! grep -q "^${param}" "$cfg_file"; then
                echo "$param" >> "$cfg_file"
            fi
        done

        # Se esiste usercfg.txt (Ubuntu), allinea anche quello ed assicurati l'include
        if [[ -f "$user_file" ]]; then
            for param in "usb_max_current_enable=1" "dtparam=pciex1" "dtparam=pciex1_gen=3"; do
                if ! grep -q "^${param}" "$user_file"; then
                    echo "$param" >> "$user_file"
                fi
            done
            if ! grep -q "^include usercfg.txt" "$cfg_file"; then
                echo "include usercfg.txt" >> "$cfg_file"
            fi
        fi
    }

    # 1. Su microSD locale
    LOCAL_BOOT_DIR="/boot/firmware"
    [[ ! -d "$LOCAL_BOOT_DIR" && -d "/boot" ]] && LOCAL_BOOT_DIR="/boot"
    apply_pi5_boot_params "$LOCAL_BOOT_DIR"
    echo "[OK] Parametri PCIe Gen 3 configurati su microSD locale."

    # 2. Su storage esterno montato
    MOUNT_DIR=$(mktemp -d)
    mount "$EXT_BOOT_DEV" "$MOUNT_DIR"
    apply_pi5_boot_params "$MOUNT_DIR"
    sync
    umount "$MOUNT_DIR"
    rmdir "$MOUNT_DIR"
    echo "[OK] Parametri PCIe Gen 3 configurati su storage esterno ($EXT_BOOT_DEV)."
else
    echo "[INFO] Raspberry Pi 4: parametri PCIe Gen 3 non applicabili."
fi

# Stabilizzazione rete
echo "[*] Configurazione identificatore client DHCP MAC..."
if command -v nmcli >/dev/null 2>&1 || systemctl is-active NetworkManager >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'NM_CONF' > /etc/NetworkManager/conf.d/10-hardware-mac.conf
[connection]
ipv4.dhcp-client-id=mac
ethernet.cloned-mac-address=preserve
wifi.cloned-mac-address=preserve
wifi.scan-rand-mac-address=no
NM_CONF
fi

if [[ -d /etc/netplan ]]; then
    mkdir -p /etc/netplan
    cat << 'NETPLAN_CONF' > /etc/netplan/99-dhcp-mac.yaml
network:
  version: 2
  ethernets:
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp4-overrides:
        use-client-id: true
  wifis:
    all-wifi:
      match:
        name: "wlan*"
      dhcp4: true
      dhcp4-overrides:
        use-client-id: true
NETPLAN_CONF
fi

# EEPROM Firmware
echo "[*] Configurazione EEPROM firmware..."
if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq rpi-eeprom || apt-get install -y -qq libraspberrypi-bin
fi

CURRENT_CONF=$(rpi-eeprom-config)
NEW_CONF_FILE=$(mktemp)

echo "$CURRENT_CONF" | grep -v -E "^(BOOT_ORDER|PCIE_PROBE|USB_MSD_PWR_OFF_TIME|USB_MSD_DISCOVER_TIMEOUT)=" > "$NEW_CONF_FILE"

if [[ $IS_PI5 -eq 1 ]]; then
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf146
PCIE_PROBE=1
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
else
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf14
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
fi

rpi-eeprom-config --apply "$NEW_CONF_FILE"
rm -f "$NEW_CONF_FILE"
echo "[OK] EEPROM aggiornata."

echo "=========================================================="
echo " Setup completato. Riavvio in corso..."
echo "=========================================================="
sleep 3
reboot
