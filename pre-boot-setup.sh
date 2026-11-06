#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Questo script deve essere eseguito come root (usa sudo)."
   exit 1
fi

# Rilevamento Modello Raspberry Pi
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

# Rilevamento Distribuzione OS
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

# 1. Verifica che il sistema sia attualmente avviato da microSD
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" != *mmcblk0* ]]; then
    echo "[WARN] Attenzione: il sistema corrente NON risulta avviato da microSD (root su $ROOT_DEV)."
    read -rp "Vuoi proseguire comunque? (s/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || exit 1
else
    echo "[OK] Sistema avviato correttamente da microSD ($ROOT_DEV)."
fi

# 2. Rileva la presenza della partizione di boot esterna (USB o NVMe)
EXT_BOOT_DEV=""
for dev in /dev/sd[a-z]1 /dev/nvme[0-9]n[0-9]p1; do
    if [[ -b "$dev" ]]; then
        EXT_BOOT_DEV="$dev"
        break
    fi
done

if [[ -z "$EXT_BOOT_DEV" ]]; then
    echo "[ERROR] Nessuna partizione di boot esterna rilevata (/dev/sd*1 o /dev/nvme*p1). Collega il supporto e riprova."
    exit 1
fi
echo "[OK] Rilevata partizione boot di destinazione: $EXT_BOOT_DEV"

# 3. Configurazione PCIe Gen 3 e corrente USB (specifica Pi 5)
if [[ $IS_PI5 -eq 1 ]]; then
    echo "[*] Rilevato Pi 5: configurazione usb_max_current_enable e PCIe Gen 3..."

    configure_pi5_firmware_file() {
        local target_file="$1"
        [[ -f "$target_file" ]] || touch "$target_file"

        if ! grep -q "^usb_max_current_enable=1" "$target_file"; then
            echo "usb_max_current_enable=1" >> "$target_file"
        fi
        if ! grep -q "^dtparam=pciex1" "$target_file"; then
            echo "dtparam=pciex1" >> "$target_file"
        fi
        if ! grep -q "^dtparam=pciex1_gen=3" "$target_file"; then
            echo "dtparam=pciex1_gen=3" >> "$target_file"
        fi
    }

    LOCAL_BOOT_CONF="/boot/firmware/config.txt"
    [[ ! -f "$LOCAL_BOOT_CONF" && -f "/boot/config.txt" ]] && LOCAL_BOOT_CONF="/boot/config.txt"

    if [[ -f "$LOCAL_BOOT_CONF" ]]; then
        configure_pi5_firmware_file "$LOCAL_BOOT_CONF"
        echo "[OK] Parametri PCIe Gen 3 e USB configurati su microSD ($LOCAL_BOOT_CONF)."
    fi

    MOUNT_DIR=$(mktemp -d)
    mount "$EXT_BOOT_DEV" "$MOUNT_DIR"
    
    TARGET_CONF=""
    if [[ -f "$MOUNT_DIR/usercfg.txt" ]]; then
        TARGET_CONF="$MOUNT_DIR/usercfg.txt"
    elif [[ -f "$MOUNT_DIR/config.txt" ]]; then
        TARGET_CONF="$MOUNT_DIR/config.txt"
    else
        TARGET_CONF="$MOUNT_DIR/config.txt"
    fi

    configure_pi5_firmware_file "$TARGET_CONF"
    echo "[OK] Parametri PCIe Gen 3 e USB configurati su supporto esterno ($(basename "$TARGET_CONF"))."

    sync
    umount "$MOUNT_DIR"
    rmdir "$MOUNT_DIR"
else
    echo "[INFO] Raspberry Pi 4: parametri PCIe Gen 3 e usb_max_current non applicabili."
fi

# 4. Stabilizzazione NetworkManager e Netplan (MAC fisico hardware)
echo "[*] Configurazione persistenza identità di rete..."
if command -v nmcli >/dev/null 2>&1 || systemctl is-active NetworkManager >/dev/null 2>&1; then
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'NM_CONF' > /etc/NetworkManager/conf.d/10-hardware-mac.conf
[connection]
ipv4.dhcp-client-id=mac
ethernet.cloned-mac-address=preserve
wifi.cloned-mac-address=preserve
wifi.scan-rand-mac-address=no
NM_CONF
    echo "[OK] NetworkManager configurato."
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
    echo "[OK] Netplan configurato."
fi

# 5. Aggiornamento bootloader EEPROM condizionale
echo "[*] Configurazione EEPROM firmware..."
if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq rpi-eeprom || apt-get install -y -qq libraspberrypi-bin
fi

CURRENT_CONF=$(rpi-eeprom-config)
NEW_CONF_FILE=$(mktemp)

echo "$CURRENT_CONF" | grep -v -E "^(BOOT_ORDER|PCIE_PROBE|USB_MSD_PWR_OFF_TIME|USB_MSD_DISCOVER_TIMEOUT)=" > "$NEW_CONF_FILE"

if [[ $IS_PI5 -eq 1 ]]; then
    echo "[INFO] Applicazione configurazione Pi 5: NVMe (6) -> USB (4) -> SD (1)..."
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf146
PCIE_PROBE=1
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
else
    echo "[INFO] Applicazione configurazione Pi 4: USB (4) -> SD (1)..."
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf14
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
fi

rpi-eeprom-config --apply "$NEW_CONF_FILE"
rm -f "$NEW_CONF_FILE"
echo "[OK] EEPROM aggiornata con successo."

echo "=========================================================="
echo " Configurazione completata. Riavvio in corso..."
echo "=========================================================="
sleep 3
reboot
