#!/usr/bin/env bash
set -eo pipefail

SESSION_NAME="picluster"
REPO_DIR="${HOME}/picluster-bootstrap"
LOG_FILE="/tmp/picluster-preflight.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Colori e formattazione
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

draw_banner() {
    clear
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                     PICLUSTER ZERO-TOUCH ENGINE                            ║${NC}"
    echo -e "${CYAN}${BOLD}║                Provisioning & High-Availability Automation                 ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Spinner grafico non bloccante per comandi lenti
run_with_spinner() {
    local msg="$1"
    shift
    local pid
    local spin='-\|/'
    local i=0

    echo -ne " ${YELLOW}[*]${NC} ${msg}... "
    "$@" >> "${LOG_FILE}" 2>&1 &
    pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r ${YELLOW}[%c]${NC} %s... " "${spin:$i:1}" "${msg}"
        sleep 0.1
    done

    wait "${pid}"
    local exit_code=$?
    if [ ${exit_code} -eq 0 ]; then
        printf "\r ${GREEN}[✓]${NC} %s... ${GREEN}COMPLETATO${NC}\n" "${msg}"
    else
        printf "\r ${RED}[✗]${NC} %s... ${RED}FALLITO (Dettagli in %s)${NC}\n" "${msg}" "${LOG_FILE}"
        return ${exit_code}
    fi
}

draw_banner

# ------------------------------------------------------------------------------
# 1. Risoluzione Lock apt e unattended-upgrades
# ------------------------------------------------------------------------------
echo -e "${BOLD}[Fase 1/4] Ispezione e Sblocco Gestore Pacchetti${NC}"
sudo systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

wait_count=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    printf "\r ${YELLOW}[!]${NC} In attesa rilascio lock da Ubuntu unattended-upgrades (%3ds)..." "${wait_count}"
    sleep 3
    wait_count=$((wait_count + 3))
    if [ ${wait_count} -ge 300 ]; then
        echo ""
        sudo kill -9 $(fuser /var/lib/dpkg/lock-frontend 2>/dev/null) 2>/dev/null || true
        sudo dpkg --configure -a || true
        break
    fi
done
[ ${wait_count} -gt 0 ] && echo -e "\r ${GREEN}[✓]${NC} Lock di sistema rilasciati.                         " || echo -e " ${GREEN}[✓]${NC} Risorse dpkg/apt libere."

# ------------------------------------------------------------------------------
# 2. Installazione Prerequisiti OS
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[Fase 2/4] Installazione Strumenti di Base (apt)${NC}"

install_apt_packages() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        tmux git curl python3 python3-pip python3-venv arp-scan
}
run_with_spinner "Download e installazione pacchetti di sistema" install_apt_packages

# ------------------------------------------------------------------------------
# 3. Wrapping trasparente in tmux
# ------------------------------------------------------------------------------
if [ -z "${TMUX:-}" ]; then
    echo ""
    echo -e "${BOLD}[Fase 3/4] Persistenza Sessione${NC}"
    echo -e " ${GREEN}[✓]${NC} Avvio sessione autonoma ${CYAN}tmux:${SESSION_NAME}${NC}"
    
    # Crea un runner temporaneo pulito che non scompare
    RUNNER_SCRIPT="/tmp/picluster_exec.sh"
    cat << 'RUNNER' > "${RUNNER_SCRIPT}"
#!/usr/bin/env bash
cd "${HOME}/picluster-bootstrap"
# Riesegue questo stesso script ma all'interno dell'ambiente tmux
export INSIDE_TMUX=1
exec bash "${HOME}/picluster-bootstrap/bootstrap.sh"
RUNNER
    chmod +x "${RUNNER_SCRIPT}"

    # Clona il repo localmente se lanciato via curl remoto prima di passare a tmux
    if [ ! -d "${REPO_DIR}/.git" ]; then
        run_with_spinner "Clonazione repository principale" git clone --quiet "https://github.com/6102610/picluster-bootstrap.git" "${REPO_DIR}"
    fi

    exec tmux new-session -s "${SESSION_NAME}" "bash ${RUNNER_SCRIPT}"
fi

# ------------------------------------------------------------------------------
# 4. Configurazione Ambiente Python e Avvio Orchestratore (Dentro tmux)
# ------------------------------------------------------------------------------
draw_banner
echo -e "${BOLD}[Fase 4/4] Inizializzazione Motore Ansible & Python${NC}"

setup_venv() {
    if [ ! -d "${REPO_DIR}/.venv" ]; then
        python3 -m venv "${REPO_DIR}/.venv"
    fi
    source "${REPO_DIR}/.venv/bin/activate"
    pip install --upgrade pip --quiet
    pip install rich pyyaml ansible --quiet
}
run_with_spinner "Creazione Virtualenv e installazione moduli (Ansible/Rich)" setup_venv

# Richiesta credenziali cluster se non esportate
if [ -z "${CLUSTER_ADMIN_PASS:-}" ]; then
    echo ""
    echo -e "${BOLD}--- Configurazione Utente Amministratore Cluster ---${NC}"
    read -r -p "Nome utente admin [default: giorgio]: " INP_USER
    export CLUSTER_ADMIN_USER="${INP_USER:-giorgio}"
    while true; do
        read -r -s -p "Password per utente '${CLUSTER_ADMIN_USER}': " PASS1
        echo ""
        read -r -s -p "Conferma password: " PASS2
        echo ""
        if [ -n "${PASS1}" ] && [ "${PASS1}" = "${PASS2}" ]; then
            export CLUSTER_ADMIN_PASS="${PASS1}"
            break
        fi
        echo -e "${RED}[!] Le password non coincidono. Riprova.${NC}"
    done
fi

echo ""
echo -e " ${GREEN}[✓]${NC} Ambiente pronto. Avvio dashboard orchestratore..."
sleep 1

# Esecuzione orchestratore mantenendo la shell aperta se si arresta
source "${REPO_DIR}/.venv/bin/activate"
cd "${REPO_DIR}"
python3 orchestrator.py || {
    echo ""
    echo -e "${RED}[!] L'orchestratore è uscito con un errore. Premi INVIO per la shell di debug.${NC}"
    read -r
    bash
}
