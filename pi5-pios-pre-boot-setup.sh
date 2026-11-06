#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Questo script deve essere eseguito come root (usa sudo)."
   exit 1
fi

echo "=========================================================="
echo "    Raspberry Pi 5 - Setup Boot NVMe -> USB -> SD"
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

# 2. Rileva la presenza della chiavetta USB
USB_BOOT_DEV=""
for dev in /dev/sd[a-z]1; do
    if [[ -b "$dev" ]]; then
        USB_BOOT_DEV="$dev"
        break
    fi
done

if [[ -z "$USB_BOOT_DEV" ]]; then
    echo "[ERROR] Nessuna partizione di boot USB rilevata (/dev/sd*1). Inserisci la chiavetta USB e riprova."
    exit 1
fi
echo "[OK] Rilevata partizione boot USB: $USB_BOOT_DEV"

# 3. Configura usb_max_current_enable=1 sia su SD che su USB
echo "[*] Configurazione corrente USB in /boot/firmware/config.txt locale..."
if ! grep -q "^usb_max_current_enable=1" /boot/firmware/config.txt 2>/dev/null; then
    echo "usb_max_current_enable=1" >> /boot/firmware/config.txt
    echo "[OK] Aggiunto a /boot/firmware/config.txt (microSD)."
else
    echo "[OK] Già presente su microSD."
fi

echo "[*] Configurazione corrente USB sulla chiavetta USB..."
MOUNT_DIR=$(mktemp -d)
mount "$USB_BOOT_DEV" "$MOUNT_DIR"
if [[ -f "$MOUNT_DIR/config.txt" ]]; then
    if ! grep -q "^usb_max_current_enable=1" "$MOUNT_DIR/config.txt"; then
        echo "usb_max_current_enable=1" >> "$MOUNT_DIR/config.txt"
        echo "[OK] Aggiunto a $USB_BOOT_DEV/config.txt."
    else
        echo "[OK] Già presente sulla chiavetta USB."
    fi
else
    echo "[WARN] config.txt non trovato sulla partizione montata $USB_BOOT_DEV."
fi
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

# 4. Stabilizzazione NetworkManager (MAC fisico hardware e DHCP client-id)
echo "[*] Configurazione stabilizzazione MAC/DHCP..."
mkdir -p /etc/NetworkManager/conf.d
cat << 'NM_CONF' > /etc/NetworkManager/conf.d/10-hardware-mac.conf
[connection]
ipv4.dhcp-client-id=mac
ethernet.cloned-mac-address=preserve
wifi.cloned-mac-address=preserve
wifi.scan-rand-mac-address=no
NM_CONF
echo "[OK] File /etc/NetworkManager/conf.d/10-hardware-mac.conf creato."

# 5. Aggiornamento bootloader e configurazione EEPROM
echo "[*] Verifica pacchetto rpi-eeprom..."
apt-get update -qq && apt-get install -y -qq rpi-eeprom

CURRENT_CONF=$(rpi-eeprom-config)
NEW_CONF_FILE=$(mktemp)

# Rimuove le impostazioni target precedenti se già presenti
echo "$CURRENT_CONF" | grep -v -E "^(BOOT_ORDER|PCIE_PROBE|USB_MSD_PWR_OFF_TIME|USB_MSD_DISCOVER_TIMEOUT)=" > "$NEW_CONF_FILE"

# Inietta le direttive richieste
cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf146
PCIE_PROBE=1
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF

echo "[*] Applicazione configurazione EEPROM..."
rpi-eeprom-config --apply "$NEW_CONF_FILE"
rm -f "$NEW_CONF_FILE"
echo "[OK] EEPROM aggiornata con BOOT_ORDER=0xf146."

echo "=========================================================="
echo " Configurazione completata con successo."
echo " Il Raspberry Pi verrà riavviato tra 5 secondi."
echo " Se rimuovi la microSD, il Pi tenterà il boot da USB."
echo "=========================================================="
sleep 5
reboot
