#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Questo script deve essere eseguito come root (usa sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-giorgio}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="/home/$REAL_USER"

# Percorsi file configurazione: controlla prima la directory corrente, poi la home utente
LOCAL_ENV_CURRENT="./cloud-init-data.env"
LOCAL_ENV_HOME="$REAL_HOME/cloud-init-data.env"
ACTIVE_ENV_FILE="$LOCAL_ENV_HOME"

if [[ -f "$LOCAL_ENV_CURRENT" ]]; then
    ACTIVE_ENV_FILE="$LOCAL_ENV_CURRENT"
fi

echo "================================================================="
echo "        PiSetup - Provisioning Ubuntu Server LTS & EEPROM        "
echo "================================================================="

# -----------------------------------------------------------------
# 1. Rilevamento Hardware e Verifica Boot da microSD
# -----------------------------------------------------------------
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

echo "[*] Hardware rilevato : $BOARD_MODEL"

ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null || true)

if [[ "$ROOT_DEV" != *mmcblk0* ]]; then
    echo "[WARN] Il sistema non risulta avviato da microSD (root su $ROOT_DEV)."
    read -rp "Vuoi proseguire comunque? (s/N): " CONFIRM </dev/tty
    [[ "$CONFIRM" =~ ^[sS]$ ]] || exit 1
else
    echo "[OK] Sistema avviato da microSD ($ROOT_DEV)."
fi

# -----------------------------------------------------------------
# 2. Selezione Automatica Disco Target (NVMe > USB)
# -----------------------------------------------------------------
TARGET_DISK=""

# Priorità 1: NVMe (escluso eventuale disco root)
NVME_CANDIDATES=$(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1}')
USB_CANDIDATES=$(lsblk -dpno NAME,TRAN,TYPE | awk '$2=="usb" && $3=="disk" {print $1}')

if [[ -n "$NVME_CANDIDATES" ]]; then
    COUNT=$(echo "$NVME_CANDIDATES" | wc -l)
    if [[ "$COUNT" -gt 1 ]]; then
        echo "[ERROR] Rilevati più dischi NVMe ($NVME_CANDIDATES). Collega un solo disco target."
        exit 1
    fi
    TARGET_DISK="$NVME_CANDIDATES"
elif [[ -n "$USB_CANDIDATES" ]]; then
    COUNT=$(echo "$USB_CANDIDATES" | wc -l)
    if [[ "$COUNT" -gt 1 ]]; then
        echo "[ERROR] Rilevati più dischi USB ($USB_CANDIDATES). Collega un solo disco target."
        exit 1
    fi
    TARGET_DISK="$USB_CANDIDATES"
else
    echo "[ERROR] Nessun disco NVMe o USB rilevato su cui installare Ubuntu Server."
    lsblk -d -o NAME,SIZE,TRAN,MODEL
    exit 1
fi

if [[ -n "$ROOT_DISK" && "$TARGET_DISK" == "/dev/$ROOT_DISK" ]]; then
    echo "[ERROR] Il disco target ($TARGET_DISK) coincide con il disco di boot attuale!"
    exit 1
fi

DISK_INFO=$(lsblk -dn -o SIZE,MODEL "$TARGET_DISK" | xargs)
echo "[OK] Disco target selezionato automaticamente: $TARGET_DISK ($DISK_INFO)"

# -----------------------------------------------------------------
# 3. Gestione Parametri Cloud-Init (Caricamento o Wizard)
# -----------------------------------------------------------------
NEED_WIZARD=1

if [[ -f "$ACTIVE_ENV_FILE" ]]; then
    # Carica variabili esistenti
    # shellcheck disable=SC1090
    source "$ACTIVE_ENV_FILE"
    if [[ -n "${TARGET_USER:-}" && "$TARGET_USER" != "CHANGEME" && \
          -n "${TARGET_PASSWORD_HASH:-}" && "$TARGET_PASSWORD_HASH" != "CHANGEME" ]]; then
        echo "[OK] Configurazione valida caricata da: $ACTIVE_ENV_FILE (utente: $TARGET_USER)"
        NEED_WIZARD=0
    fi
fi

if [[ $NEED_WIZARD -eq 1 ]]; then
    echo ""
    echo "================================================================="
    echo "       Configurazione Interattiva Credenziali Cloud-Init         "
    echo "================================================================="

    read -rp "Nome utente amministratore [$REAL_USER]: " INPUT_USER </dev/tty
    TARGET_USER="${INPUT_USER:-$REAL_USER}"

    while true; do
        read -rsp "Password per '$TARGET_USER': " PWD1 </dev/tty
        echo ""
        read -rsp "Conferma password: " PWD2 </dev/tty
        echo ""
        if [[ -n "$PWD1" && "$PWD1" == "$PWD2" ]]; then
            TARGET_PASSWORD_HASH=$(openssl passwd -6 "$PWD1")
            break
        else
            echo "[!] Password non valide o non coincidenti. Riprova."
        fi
    done

    # Recupero automatico chiave SSH da authorized_keys o chiavi locali
    DETECTED_KEY=""
    for key_file in "$REAL_HOME/.ssh/authorized_keys" "$REAL_HOME/.ssh/id_ed25519.pub" "$REAL_HOME/.ssh/id_rsa.pub"; do
        if [[ -f "$key_file" && -s "$key_file" ]]; then
            DETECTED_KEY=$(grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2)' "$key_file" | head -n 1 || true)
            [[ -n "$DETECTED_KEY" ]] && break
        fi
    done

    SSH_AUTHORIZED_KEY=""
    if [[ -n "$DETECTED_KEY" ]]; then
        echo "[*] Chiave SSH rilevata in $REAL_HOME/.ssh/: ${DETECTED_KEY:0:48}..."
        read -rp "Usare questa chiave pubblica SSH? (S/n): " USE_KEY </dev/tty
        if [[ ! "$USE_KEY" =~ ^[nN]$ ]]; then
            SSH_AUTHORIZED_KEY="$DETECTED_KEY"
        fi
    fi

    if [[ -z "$SSH_AUTHORIZED_KEY" ]]; then
        read -rp "Incolla chiave pubblica SSH (lascia vuoto per saltare): " MANUAL_KEY </dev/tty
        SSH_AUTHORIZED_KEY="$MANUAL_KEY"
    fi

    read -rp "Configurare una rete Wi-Fi su Ubuntu? (s/N): " WANT_WIFI </dev/tty
    WIFI_SSID=""
    WIFI_PASSWORD=""
    if [[ "$WANT_WIFI" =~ ^[sS]$ ]]; then
        read -rp "SSID Wi-Fi: " WIFI_SSID </dev/tty
        read -rsp "Password Wi-Fi: " WIFI_PASSWORD </dev/tty
        echo ""
    fi

    # Salvataggio locale persistente per riutilizzi futuri
    cat << ENV_EOF > "$ACTIVE_ENV_FILE"
# Configurazione locale generata da pisetup.sh
TARGET_USER="${TARGET_USER}"
TARGET_PASSWORD_HASH='${TARGET_PASSWORD_HASH}'
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY}"
WIFI_SSID="${WIFI_SSID}"
WIFI_PASSWORD="${WIFI_PASSWORD}"
ENV_EOF
    chown "$REAL_USER:$REAL_USER" "$ACTIVE_ENV_FILE" 2>/dev/null || true
    chmod 600 "$ACTIVE_ENV_FILE"
    echo "[OK] Parametri salvati localmente in: $ACTIVE_ENV_FILE"
fi

# -----------------------------------------------------------------
# 4. Ricerca e Download Ultima Versione Ubuntu Server LTS ARM64
# -----------------------------------------------------------------
echo ""
echo "[*] Verifica ultima release Ubuntu Server LTS ARM64 per Raspberry Pi..."

# Rileva dinamicamente l'ultima release LTS disponibile (noble 24.04 o successiva)
BASE_URL="https://cdimage.ubuntu.com/releases"
LATEST_LTS_CODENAME=$(curl -fsSL "$BASE_URL/" | grep -oE 'href="(noble|resolute)/"' | tail -n 1 | cut -d'"' -f2 | tr -d '/' || true)
[[ -z "$LATEST_LTS_CODENAME" ]] && LATEST_LTS_CODENAME="noble"

RELEASE_INDEX_URL="${BASE_URL}/${LATEST_LTS_CODENAME}/release/"
IMG_FILENAME=$(curl -fsSL "$RELEASE_INDEX_URL" | grep -oE 'ubuntu-[0-9]+\.[0-9]+(\.[0-9]+)?-preinstalled-server-arm64\+raspi\.img\.xz' | head -n 1)

if [[ -z "$IMG_FILENAME" ]]; then
    echo "[ERROR] Impossibile determinare il nome dell'immagine Ubuntu LTS da $RELEASE_INDEX_URL"
    exit 1
fi

IMG_URL="${RELEASE_INDEX_URL}${IMG_FILENAME}"
CACHE_DIR="/var/tmp/pisetup-images"
mkdir -p "$CACHE_DIR"
LOCAL_IMG_PATH="${CACHE_DIR}/${IMG_FILENAME}"

if [[ -f "$LOCAL_IMG_PATH" ]]; then
    echo "[OK] Immagine già presente in cache locale: $LOCAL_IMG_PATH"
else
    echo "[*] Download in corso: $IMG_FILENAME"
    echo "    Sorgente: $IMG_URL"
    # Pulizia eventuali immagini vecchie in cache per risparmiare spazio su SD
    rm -f "${CACHE_DIR}"/ubuntu-*-raspi.img.xz
    curl -# -fL "$IMG_URL" -o "${LOCAL_IMG_PATH}.tmp"
    mv "${LOCAL_IMG_PATH}.tmp" "$LOCAL_IMG_PATH"
    echo "[OK] Download completato con successo."
fi

# -----------------------------------------------------------------
# 5. Smontaggio Partizioni Target e Scrittura Immagine (dd)
# -----------------------------------------------------------------
echo ""
echo "[*] Preparazione disco target $TARGET_DISK..."

# Smonta eventuali partizioni montate automaticamente da RPi OS
for part in $(lsblk -lnpo NAME "$TARGET_DISK" | tail -n +2); do
    if mountpoint -q "$part" || grep -q "^$part " /proc/mounts; then
        echo "    Smontaggio partizione attiva: $part"
        umount -f "$part" || true
    fi
done

echo "[*] Scrittura immagine su $TARGET_DISK (non scollegare il disco)..."
xzcat "$LOCAL_IMG_PATH" | dd of="$TARGET_DISK" bs=4M status=progress conv=fsync
sync

# Aggiornamento tabella partizioni nel kernel
partprobe "$TARGET_DISK" 2>/dev/null || blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true
sleep 2

# Identificazione partizione di boot (es. /dev/sda1 o /dev/nvme0n1p1)
if [[ "$TARGET_DISK" == *nvme* ]]; then
    BOOT_PART="${TARGET_DISK}p1"
else
    BOOT_PART="${TARGET_DISK}1"
fi

if [[ ! -b "$BOOT_PART" ]]; then
    echo "[ERROR] Partizione di boot $BOOT_PART non rilevata dopo la scrittura!"
    exit 1
fi
echo "[OK] Immagine scritta. Partizione di boot rilevata: $BOOT_PART"

# -----------------------------------------------------------------
# 6. Iniezione Cloud-Init e Parametri Hardware su Partizione Boot
# -----------------------------------------------------------------
echo "[*] Configurazione cloud-init e hardware su $BOOT_PART..."
MOUNT_DIR=$(mktemp -d)
mount "$BOOT_PART" "$MOUNT_DIR"

# Scrittura user-data
cat << CLOUD_EOF > "$MOUNT_DIR/user-data"
#cloud-config
manage_etc_hosts: true

users:
  - name: ${TARGET_USER}
    gecos: ${TARGET_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [adm, sudo, dialout, cdrom, audio, video, plugdev, games, users, input, netdev]
    lock_passwd: false
    passwd: '${TARGET_PASSWORD_HASH}'
$(if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then echo "    ssh_authorized_keys:"; echo "      - \"${SSH_AUTHORIZED_KEY}\""; fi)

ssh_pwauth: true
package_update: false
package_upgrade: false
CLOUD_EOF

# Scrittura meta-data
cat << META_EOF > "$MOUNT_DIR/meta-data"
instance-id: rpi-ubuntu-$(date +%s)
META_EOF

# Scrittura network-config (Ethernet DHCP + Wi-Fi opzionale)
if [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASSWORD:-}" ]]; then
    cat << NET_EOF > "$MOUNT_DIR/network-config"
version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp-identifier: mac
    optional: true
wifis:
  wlan0:
    dhcp4: true
    dhcp-identifier: mac
    optional: true
    regulatory-domain: "IT"
    access-points:
      "${WIFI_SSID}":
        password: "${WIFI_PASSWORD}"
NET_EOF
else
    cat << NET_EOF > "$MOUNT_DIR/network-config"
version: 2
ethernets:
  eth0:
    dhcp4: true
    optional: true
NET_EOF
fi

chmod 644 "$MOUNT_DIR/user-data" "$MOUNT_DIR/meta-data" "$MOUNT_DIR/network-config"

# Fix stabilita NVMe (evita D3cold e timeout ASPM su SSD DRAM-less come WD SN740)
for cmdf in "$MOUNT_DIR/cmdline.txt" "$MOUNT_DIR/current/cmdline.txt"; do
    if [[ -f "$cmdf" ]] && ! grep -q "pcie_port_pm=off" "$cmdf"; then
        CLEAN_LINE=$(tr -d "\n\r" < "$cmdf")
        echo "${CLEAN_LINE} nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off" > "$cmdf"
    fi
done

# Fix Ubuntu 26.04+ (layout current/ e bug autoboot.txt tryboot_a_b su boot USB/NVMe)
if [[ -f "$MOUNT_DIR/autoboot.txt" ]]; then
    rm -f "$MOUNT_DIR/autoboot.txt"
    echo "[OK] Rimosso autoboot.txt (fix loop USB-MSD tryboot_a_b)."
fi
if [[ -d "$MOUNT_DIR/current" ]]; then
    cp -f "$MOUNT_DIR/user-data" "$MOUNT_DIR/meta-data" "$MOUNT_DIR/network-config" "$MOUNT_DIR/current/"
    echo "[OK] File cloud-init replicati in /current/ per compatibilita os_prefix."
fi

# Configurazione PCIe Gen 3 e corrente USB se Raspberry Pi 5
if [[ $IS_PI5 -eq 1 ]]; then
    for cfg in "$MOUNT_DIR/config.txt" "$MOUNT_DIR/usercfg.txt"; do
        if [[ -f "$cfg" ]]; then
            for param in "usb_max_current_enable=1" "dtparam=pciex1"; do
                grep -q "^${param}" "$cfg" || echo "$param" >> "$cfg"
            done
        fi
    done
    echo "[OK] Parametri PCIe Gen 2 e USB Max Current applicati su Pi 5."
fi

sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

# -----------------------------------------------------------------
# 7. Configurazione & Verifica Ordine di Avvio EEPROM
# -----------------------------------------------------------------
echo "[*] Configurazione e verifica EEPROM bootloader..."
if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq rpi-eeprom || apt-get install -y -qq libraspberrypi-bin
fi

CURRENT_CONF=$(rpi-eeprom-config)
NEW_CONF_FILE=$(mktemp)

echo "$CURRENT_CONF" | grep -v -E "^(BOOT_ORDER|PCIE_PROBE|USB_MSD_PWR_OFF_TIME|USB_MSD_DISCOVER_TIMEOUT)=" > "$NEW_CONF_FILE"

if [[ $IS_PI5 -eq 1 ]]; then
    TARGET_ORDER="0xf146"
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf146
PCIE_PROBE=1
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
else
    TARGET_ORDER="0xf14"
    cat << 'EEPROM_CONF' >> "$NEW_CONF_FILE"
BOOT_ORDER=0xf14
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=5000
EEPROM_CONF
fi

rpi-eeprom-config --apply "$NEW_CONF_FILE"
rm -f "$NEW_CONF_FILE"

# Verifica esplicita che il parametro sia registrato correttamente per il prossimo riavvio
APPLIED_ORDER=$(rpi-eeprom-config | grep "^BOOT_ORDER=" | cut -d'=' -f2 || true)
if [[ "$APPLIED_ORDER" == "$TARGET_ORDER" ]]; then
    echo "[OK] Verifica EEPROM superata: BOOT_ORDER=$APPLIED_ORDER (priorità NVMe/USB attiva)."
else
    echo "[WARN] BOOT_ORDER letto: '$APPLIED_ORDER' (atteso: '$TARGET_ORDER'). Controlla manualmente rpi-eeprom-config."
fi

echo ""
echo "================================================================="
echo "  [✓] Provisioning completato su $TARGET_DISK ($IMG_FILENAME)"
echo "================================================================="
read -rp "Vuoi riavviare ora il Raspberry Pi per avviare Ubuntu Server? (S/n): " DO_REBOOT </dev/tty
if [[ ! "$DO_REBOOT" =~ ^[nN]$ ]]; then
    echo "[*] Riavvio in corso..."
    sleep 2
    reboot
else
    echo "[INFO] Riavvio annullato. Esegui 'sudo reboot' quando sei pronto."
fi
