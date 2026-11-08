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

echo "=========================================================="
echo "    Setup Boot Sequenziale Multi-Piattaforma"
echo "    Hardware Rilevato : $BOARD_MODEL"
echo "=========================================================="

ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" != *mmcblk0* ]]; then
    echo "[WARN] Attenzione: il sistema non risulta avviato da microSD (root su $ROOT_DEV)."
    read -rp "Vuoi proseguire comunque? (s/N): " CONFIRM </dev/tty
    [[ "$CONFIRM" =~ ^[sS]$ ]] || exit 1
else
    echo "[OK] Sistema avviato correttamente da microSD ($ROOT_DEV)."
fi

# Rilevamento partizione boot esterna (USB o NVMe)
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

# -----------------------------------------------------------------
# Raccolta Interattiva Credenziali (Lettura forzata da /dev/tty)
# -----------------------------------------------------------------
echo ""
echo "=========================================================="
echo "       Configurazione Interattiva Utente e Rete"
echo "=========================================================="

# 1. Username
DEFAULT_USER="giorgio"
read -rp "Nome utente da creare [$DEFAULT_USER]: " INPUT_USER </dev/tty
TARGET_USER="${INPUT_USER:-$DEFAULT_USER}"

# 2. Password
PASSWORD_HASH=""
while true; do
    read -rsp "Password per l'utente $TARGET_USER: " PWD1 </dev/tty
    echo ""
    read -rsp "Conferma password: " PWD2 </dev/tty
    echo ""
    if [[ -n "$PWD1" && "$PWD1" == "$PWD2" ]]; then
        PASSWORD_HASH=$(openssl passwd -6 "$PWD1")
        break
    else
        echo "[!] Le password non coincidono o sono vuote. Riprova."
    fi
done

# 3. Chiave SSH
DETECTED_SSH_KEY=""
for k in /home/*/.ssh/id_ed25519.pub /home/*/.ssh/id_rsa.pub /home/*/.ssh/authorized_keys /root/.ssh/id_*.pub; do
    if [[ -f "$k" ]]; then
        DETECTED_SSH_KEY=$(head -n 1 "$k")
        break
    fi
done

SSH_AUTHORIZED_KEY=""
if [[ -n "$DETECTED_SSH_KEY" ]]; then
    echo "[*] Trovata chiave SSH locale: ${DETECTED_SSH_KEY:0:45}..."
    read -rp "Vuoi utilizzare questa chiave SSH? (S/n): " USE_DETECTED </dev/tty
    if [[ ! "$USE_DETECTED" =~ ^[nN]$ ]]; then
        SSH_AUTHORIZED_KEY="$DETECTED_SSH_KEY"
    fi
fi

if [[ -z "$SSH_AUTHORIZED_KEY" ]]; then
    read -rp "Incolla chiave pubblica SSH (lascia vuoto per disabilitare): " CUSTOM_SSH </dev/tty
    SSH_AUTHORIZED_KEY="$CUSTOM_SSH"
fi

# 4. Rete Wi-Fi (opzionale)
echo ""
read -rp "Configurare connessione Wi-Fi? (s/N): " SETUP_WIFI </dev/tty
WIFI_SSID=""
WIFI_PASSWORD=""
if [[ "$SETUP_WIFI" =~ ^[sS]$ ]]; then
    read -rp "SSID Rete Wi-Fi: " WIFI_SSID </dev/tty
    read -rsp "Password Wi-Fi: " WIFI_PASSWORD </dev/tty
    echo ""
fi

# -----------------------------------------------------------------
# Montaggio Storage Esterno e Iniezione Cloud-Init
# -----------------------------------------------------------------
echo ""
echo "[*] Montaggio dello storage esterno $EXT_BOOT_DEV..."
MOUNT_DIR=$(mktemp -d)
mount "$EXT_BOOT_DEV" "$MOUNT_DIR"

echo "[*] Generazione file user-data per cloud-init..."

cat << CLOUD_EOF > "$MOUNT_DIR/user-data"
#cloud-config
hostname: pi5
manage_etc_hosts: true

users:
  - name: ${TARGET_USER}
    gecos: ${TARGET_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [adm, sudo, dialout, cdrom, audio, video, plugdev, games, users, input, netdev]
    lock_passwd: false
    passwd: "${PASSWORD_HASH}"
$(if [[ -n "$SSH_AUTHORIZED_KEY" ]]; then echo "    ssh_authorized_keys:"; echo "      - \"${SSH_AUTHORIZED_KEY}\""; fi)

ssh_pwauth: true
package_update: false
package_upgrade: false
CLOUD_EOF

# Iniezione configurazione Wi-Fi se fornita
if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]]; then
cat << CLOUD_NET >> "$MOUNT_DIR/user-data"

write_files:
  - path: /etc/netplan/50-cloud-init-wifi.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        wifis:
          wlan0:
            dhcp4: true
            access-points:
              "${WIFI_SSID}":
                password: "${WIFI_PASSWORD}"
CLOUD_NET
fi

touch "$MOUNT_DIR/meta-data"
chmod 644 "$MOUNT_DIR/user-data" "$MOUNT_DIR/meta-data"
echo "[OK] user-data e meta-data generati con successo."

# Abilitazione cgroups in cmdline.txt per K3s
if [[ -f "$MOUNT_DIR/cmdline.txt" ]]; then
    if ! grep -q "cgroup_enable=cpuset" "$MOUNT_DIR/cmdline.txt"; then
        echo "[*] Iniezione parametri cgroups in cmdline.txt..."
        sed -i 's/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' "$MOUNT_DIR/cmdline.txt"
    fi
fi

# Parametri PCIe Gen 3 se Pi 5
if [[ $IS_PI5 -eq 1 ]]; then
    for cfg in "$MOUNT_DIR/config.txt" "$MOUNT_DIR/usercfg.txt"; do
        if [[ -f "$cfg" ]]; then
            for param in "usb_max_current_enable=1" "dtparam=pciex1" "dtparam=pciex1_gen=3"; do
                grep -q "^${param}" "$cfg" || echo "$param" >> "$cfg"
            done
        fi
    done
fi

sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "[OK] Storage esterno configurato e smontato con successo."

# -----------------------------------------------------------------
# Configurazione EEPROM Bootloader
# -----------------------------------------------------------------
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
echo "[OK] EEPROM aggiornata con successo."

echo "=========================================================="
echo " Setup completato. Riavvio in corso..."
echo "=========================================================="
sleep 3
reboot
