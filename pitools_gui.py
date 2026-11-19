#!/usr/bin/env python3
import os
import re
import sys
import time
import shlex
import queue
import shutil
import socket
import getpass
import threading
import subprocess
import ipaddress
import importlib.util
from concurrent.futures import ThreadPoolExecutor, as_completed


def ensure_dependencies():
    """Controlla e installa automaticamente le dipendenze mancanti al primo avvio."""
    if os.environ.get("PITOOLS_BOOTSTRAPPED") == "1":
        return

    missing_apt = []
    missing_dnf = []
    missing_pac = []

    if importlib.util.find_spec("tkinter") is None:
        missing_apt.append("python3-tk")
        missing_dnf.append("python3-tkinter")
        missing_pac.append("tk")

    if importlib.util.find_spec("paramiko") is None:
        missing_apt.append("python3-paramiko")
        missing_dnf.append("python3-paramiko")
        missing_pac.append("python-paramiko")

    for bin_name in ("curl", "nmap", "openssl"):
        if shutil.which(bin_name) is None:
            missing_apt.append(bin_name)
            missing_dnf.append(bin_name)
            missing_pac.append(bin_name)

    if not missing_apt:
        return

    print("=================================================================")
    print(" [PiTools GUI] Dipendenze mancanti rilevate:", ", ".join(missing_apt))
    print("=================================================================")

    if shutil.which("apt-get"):
        cmd = ["sudo", "apt-get", "update"]
        cmd_install = ["sudo", "apt-get", "install", "-y"] + missing_apt
        rc = subprocess.call(cmd)
        if rc == 0:
            rc = subprocess.call(cmd_install)
    elif shutil.which("dnf"):
        rc = subprocess.call(["sudo", "dnf", "install", "-y"] + missing_dnf)
    elif shutil.which("pacman"):
        rc = subprocess.call(["sudo", "pacman", "-Sy", "--noconfirm"] + missing_pac)
    else:
        print("[ERRORE] Gestore pacchetti non riconosciuto. Installa manualmente:", ", ".join(missing_apt))
        sys.exit(1)

    if rc != 0:
        print("[ERRORE] Installazione dipendenze fallita.")
        sys.exit(rc)

    print("[OK] Dipendenze installate! Riavvio automatico di PiTools GUI...")
    os.environ["PITOOLS_BOOTSTRAPPED"] = "1"
    os.execv(sys.executable, [sys.executable] + sys.argv)


ensure_dependencies()

import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
import paramiko

REPO_RAW_BASE   = "https://raw.githubusercontent.com/6102610/pitools/main"
URL_PIFINDER    = f"{REPO_RAW_BASE}/pifinder.sh"
URL_PIVERIFY    = f"{REPO_RAW_BASE}/piverify.sh"
URL_PISETUP     = f"{REPO_RAW_BASE}/pisetup.sh"
URL_PIBOOTORDER = f"{REPO_RAW_BASE}/pibootorder.sh"

ANSI_ESCAPE_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

BOOT_NIBBLE_MAP = {
    "0": "SD-Wait",
    "1": "SD",
    "2": "NET",
    "3": "RPIBOOT",
    "4": "USB",
    "5": "USB2-C",
    "6": "NVMe",
    "7": "HTTP",
    "e": "STOP",
    "f": "↻",
}


def strip_ansi(text: str) -> str:
    return ANSI_ESCAPE_RE.sub("", text).replace("\r", "")


def is_wsl_env() -> bool:
    if os.path.isfile("/proc/sys/kernel/osrelease"):
        try:
            with open("/proc/sys/kernel/osrelease", "r", encoding="utf-8", errors="ignore") as f:
                return "microsoft" in f.read().lower()
        except OSError:
            pass
    return False


def bash_single_quote(val: str) -> str:
    """Racchiude una stringa in apici singoli POSIX sicuri per 'source' in bash."""
    return "'" + val.replace("'", "'\\''") + "'"


def get_default_env_save_path() -> str:
    candidates = [
        os.path.abspath("./cloud-init-data.env"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud-init-data.env"),
        os.path.expanduser("~/pitools/cloud-init-data.env"),
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud-init-data.env")


def parse_env_file(path: str) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path or not os.path.isfile(path):
        return data
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                key, raw_val = line.split("=", 1)
                key = key.strip()
                raw_val = raw_val.strip()
                try:
                    parts = shlex.split(raw_val, posix=True)
                    val = parts[0] if parts else ""
                except ValueError:
                    val = raw_val.strip("\"'")
                data[key] = val
    except OSError:
        pass
    return data


def detect_system_username() -> str:
    try:
        u = getpass.getuser().strip()
        if u:
            return u
    except Exception:
        pass
    return os.environ.get("USER", "").strip() or "ubuntu"


def detect_default_user() -> str:
    """Ordine di fallback: 1) TARGET_USER in cloud-init-data.env, 2) utente di sistema, 3) 'ubuntu'."""
    env_data = parse_env_file(get_default_env_save_path())
    if env_data.get("TARGET_USER", "").strip():
        return env_data["TARGET_USER"].strip()
    return detect_system_username()


def discover_ssh_public_key() -> str:
    """Cerca una chiave pubblica SSH locale (~/.ssh, ssh-agent o profilo Windows su WSL)."""
    ssh_dir = os.path.expanduser("~/.ssh")
    preferred = ("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub")
    for fname in preferred:
        fpath = os.path.join(ssh_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                    line = f.readline().strip()
                    if line.startswith("ssh-") or line.startswith("ecdsa-"):
                        return line
            except OSError:
                pass

    if os.path.isdir(ssh_dir):
        for fname in sorted(os.listdir(ssh_dir)):
            if fname.endswith(".pub"):
                try:
                    with open(os.path.join(ssh_dir, fname), "r", encoding="utf-8", errors="ignore") as f:
                        line = f.readline().strip()
                        if line.startswith("ssh-") or line.startswith("ecdsa-"):
                            return line
                except OSError:
                    pass

    # Fallback su ssh-agent
    if shutil.which("ssh-add"):
        try:
            out = subprocess.check_output(["ssh-add", "-L"], stderr=subprocess.DEVNULL, timeout=3).decode(
                "utf-8", errors="ignore"
            )
            for line in out.splitlines():
                if line.startswith(("ssh-", "ecdsa-", "sk-")):
                    return line.strip()
        except Exception:
            pass

    # Fallback su profilo Windows se in esecuzione sotto WSL
    if is_wsl_env() and shutil.which("cmd.exe") and shutil.which("wslpath"):
        try:
            win_prof = (
                subprocess.check_output(["cmd.exe", "/c", "echo %USERPROFILE%"], stderr=subprocess.DEVNULL, timeout=4)
                .decode("utf-8", errors="ignore")
                .strip()
            )
            wsl_prof = (
                subprocess.check_output(["wslpath", "-u", win_prof], stderr=subprocess.DEVNULL, timeout=3)
                .decode("utf-8", errors="ignore")
                .strip()
            )
            win_ssh = os.path.join(wsl_prof, ".ssh")
            for fname in preferred:
                fpath = os.path.join(win_ssh, fname)
                if os.path.isfile(fpath):
                    with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                        line = f.readline().strip()
                        if line.startswith("ssh-") or line.startswith("ecdsa-"):
                            return line
        except Exception:
            pass

    return ""


def discover_wifi_credentials() -> tuple[str, str]:
    """Tenta di rilevare SSID e Password Wi-Fi attivi da Windows (WSL) o NetworkManager (Linux)."""
    ssid, psk = "", ""

    if is_wsl_env() and shutil.which("netsh.exe"):
        try:
            out = subprocess.check_output(
                ["netsh.exe", "wlan", "show", "interfaces"], stderr=subprocess.DEVNULL, timeout=5
            ).decode("cp850", errors="ignore")
            for line in out.splitlines():
                m = re.match(r"^\s*SSID\s*:\s*(.+)$", line)
                if m:
                    ssid = m.group(1).strip()
                    break
            if ssid:
                prof = subprocess.check_output(
                    ["netsh.exe", "wlan", "show", "profile", f"name={ssid}", "key=clear"],
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                ).decode("cp850", errors="ignore")
                m_key = re.search(r"(?:Key Content|Contenuto chiave)\s*:\s*(.+)", prof, flags=re.IGNORECASE)
                if m_key:
                    psk = m_key.group(1).strip()
        except Exception:
            pass
        if ssid:
            return ssid, psk

    if shutil.which("nmcli"):
        try:
            out = subprocess.check_output(
                ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"], stderr=subprocess.DEVNULL, timeout=4
            ).decode("utf-8", errors="ignore")
            for line in out.splitlines():
                if line.startswith(("yes:", "sì:", "si:")):
                    ssid = line.split(":", 1)[1].strip()
                    break
            if ssid:
                psk_out = subprocess.check_output(
                    ["nmcli", "-s", "-g", "802-11-wireless-security.psk", "connection", "show", ssid],
                    stderr=subprocess.DEVNULL,
                    timeout=4,
                ).decode("utf-8", errors="ignore")
                psk = psk_out.strip()
        except Exception:
            pass

    if not ssid and shutil.which("iwgetid"):
        try:
            ssid = (
                subprocess.check_output(["iwgetid", "-r"], stderr=subprocess.DEVNULL, timeout=3)
                .decode("utf-8", errors="ignore")
                .strip()
            )
        except Exception:
            pass

    return ssid, psk


def generate_sha512_password_hash(password: str) -> str:
    """Genera un hash compatibile cloud-init ($6$...) tramite openssl."""
    proc = subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"],
        input=password,
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    return proc.stdout.strip()


def decode_boot_order(raw_code: str) -> str:
    """Converte qualsiasi codice esadecimale BOOT_ORDER (letto da destra a sinistra) in formato testuale."""
    val = raw_code.strip()
    if not val or val == "-":
        return "-"
    clean = val.lower()
    if clean == "default":
        return "SD → USB ↻ (default)"
    if clean.startswith("0x"):
        clean = clean[2:]
    if not re.fullmatch(r"[0-9a-f]+", clean):
        return val

    steps = []
    has_loop = False
    for idx, nibble in enumerate(reversed(clean)):
        if nibble == "f" and idx == len(clean) - 1:
            has_loop = True
        elif nibble == "f":
            steps.append("LOOP")
        else:
            steps.append(BOOT_NIBBLE_MAP.get(nibble, f"0x{nibble.upper()}"))

    chain = " → ".join(steps) if steps else "↻"
    if has_loop and steps:
        chain = f"{chain} ↻"
    return f"{chain} ({val})"


def detect_default_subnet() -> str:
    if is_wsl_env():
        try:
            out = subprocess.check_output(
                ["ipconfig.exe"], stderr=subprocess.DEVNULL, timeout=4
            ).decode("cp850", errors="ignore")
            ips = re.findall(r"IPv4[^:]*:\s*(\d+\.\d+\.\d+\.\d+)", out)
            for ip in ips:
                if ip.startswith(("192.168.", "10.")) and not ip.endswith(".1"):
                    net = ipaddress.ip_network(f"{ip}/24", strict=False)
                    return str(net)
        except Exception:
            pass

    try:
        out = subprocess.check_output(
            ["ip", "-o", "-f", "inet", "addr", "show"], stderr=subprocess.DEVNULL, timeout=3
        ).decode("utf-8", errors="ignore")
        for line in out.splitlines():
            if " lo " in line:
                continue
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+/\d+)", line)
            if m:
                iface_net = ipaddress.ip_interface(m.group(1)).network
                if not str(iface_net.network_address).startswith("172."):
                    return str(iface_net)
    except Exception:
        pass

    return "192.168.0.0/24"


def grab_ssh_banner(ip: str, timeout: float = 1.5) -> str:
    try:
        with socket.create_connection((ip, 22), timeout=timeout) as s:
            s.settimeout(timeout)
            data = s.recv(128).decode("utf-8", errors="ignore").strip()
            if data.startswith("SSH-"):
                return data.replace("SSH-2.0-", "")
            return "Porta 22 aperta"
    except Exception:
        return ""


class PiToolsGUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("PiTools Manager - Discovery, Verify, BootOrder & Upgrade (Online via curl)")
        self.root.geometry("1380x750")
        self.root.minsize(1120, 620)

        self.ui_queue: queue.Queue = queue.Queue()
        self.selected_ips: set[str] = set()
        self.cancel_event = threading.Event()
        self.busy = False

        self._build_ui()
        self._toggle_auth_fields()
        self._refresh_env_badge()
        self.root.after(100, self._process_ui_queue)

    def _build_ui(self):
        pad = {"padx": 8, "pady": 5}

        # --- 1. Barra Scansione Rete & Aggiunta IP ---
        scan_frame = ttk.LabelFrame(self.root, text=" 1. Scansione Rete (pifinder.sh + nmap) ")
        scan_frame.pack(fill="x", **pad)

        ttk.Label(scan_frame, text="Subnet:").grid(row=0, column=0, padx=(10, 4), pady=8, sticky="w")
        self.subnet_var = tk.StringVar(value=detect_default_subnet())
        self.subnet_entry = ttk.Entry(scan_frame, textvariable=self.subnet_var, width=18)
        self.subnet_entry.grid(row=0, column=1, padx=4, pady=8, sticky="w")

        self.btn_scan = ttk.Button(scan_frame, text="Scansiona Rete", command=self.start_scan)
        self.btn_scan.grid(row=0, column=2, padx=6, pady=8)

        ttk.Separator(scan_frame, orient="vertical").grid(row=0, column=3, sticky="ns", padx=12, pady=4)

        ttk.Label(scan_frame, text="Aggiungi IP singolo:").grid(row=0, column=4, padx=4, pady=8, sticky="w")
        self.manual_ip_var = tk.StringVar()
        self.manual_ip_entry = ttk.Entry(scan_frame, textvariable=self.manual_ip_var, width=16)
        self.manual_ip_entry.grid(row=0, column=5, padx=4, pady=8, sticky="w")
        self.manual_ip_entry.bind("<Return>", lambda _e: self.add_manual_ip())

        ttk.Button(scan_frame, text="Aggiungi IP", command=self.add_manual_ip).grid(row=0, column=6, padx=6, pady=8)

        self.btn_cancel = ttk.Button(
            scan_frame, text="Interrompi Operazione", command=self.cancel_operation, state="disabled"
        )
        self.btn_cancel.grid(row=0, column=7, padx=(20, 8), pady=8, sticky="e")

        # --- 2. Barra Autenticazione SSH & Configurazione .env ---
        auth_frame = ttk.LabelFrame(self.root, text=" 2. Autenticazione SSH & Parametri Cloud-Init ")
        auth_frame.pack(fill="x", **pad)

        self.use_ssh_key_var = tk.BooleanVar(value=True)
        self.chk_ssh_key = ttk.Checkbutton(
            auth_frame,
            text="Usa Chiave SSH (default)",
            variable=self.use_ssh_key_var,
            command=self._toggle_auth_fields,
        )
        self.chk_ssh_key.grid(row=0, column=0, padx=10, pady=8, sticky="w")

        ttk.Label(auth_frame, text="Utente:").grid(row=0, column=1, padx=(8, 4), pady=8, sticky="w")
        self.user_var = tk.StringVar(value=detect_default_user())
        self.entry_user = ttk.Entry(auth_frame, textvariable=self.user_var, width=13)
        self.entry_user.grid(row=0, column=2, padx=4, pady=8)

        ttk.Label(auth_frame, text="Password SSH:").grid(row=0, column=3, padx=(8, 4), pady=8, sticky="w")
        self.pass_var = tk.StringVar()
        self.entry_pass = ttk.Entry(auth_frame, textvariable=self.pass_var, show="*", width=14)
        self.entry_pass.grid(row=0, column=4, padx=4, pady=8)

        ttk.Label(auth_frame, text="Password Sudo (vuoto = SSH):").grid(
            row=0, column=5, padx=(8, 4), pady=8, sticky="w"
        )
        self.sudo_var = tk.StringVar()
        self.entry_sudo = ttk.Entry(auth_frame, textvariable=self.sudo_var, show="*", width=14)
        self.entry_sudo.grid(row=0, column=6, padx=4, pady=8)

        ttk.Separator(auth_frame, orient="vertical").grid(row=0, column=7, sticky="ns", padx=10, pady=4)

        self.env_status_var = tk.StringVar(value=".env: verifica...")
        self.lbl_env_status = ttk.Label(auth_frame, textvariable=self.env_status_var, font=("Sans", 9, "bold"))
        self.lbl_env_status.grid(row=0, column=8, padx=(4, 6), pady=8, sticky="w")

        self.btn_env_cfg = ttk.Button(
            auth_frame, text="Configura cloud-init (.env)", command=lambda: self.open_env_dialog()
        )
        self.btn_env_cfg.grid(row=0, column=9, padx=(4, 10), pady=8, sticky="e")

        # --- 3. Tabella Dispositivi Rilevati ---
        table_frame = ttk.LabelFrame(
            self.root, text=" 3. Raspberry Pi Rilevati (Clicca su una riga per spuntare/deselezionare) "
        )
        table_frame.pack(fill="both", expand=True, **pad)

        cols = ("sel", "ip", "banner", "model", "os", "boot_dev", "boot_order", "disks", "status")
        self.tree = ttk.Treeview(table_frame, columns=cols, show="headings", height=9, selectmode="browse")

        headers = {
            "sel": ("Sel", 45, "center"),
            "ip": ("Indirizzo IP", 115, "w"),
            "banner": ("Banner SSH", 160, "w"),
            "model": ("Modello Pi", 200, "w"),
            "os": ("OS Attuale", 160, "w"),
            "boot_dev": ("Boot Attivo", 130, "w"),
            "boot_order": ("Ordine di Boot", 230, "w"),
            "disks": ("Periferiche (SD/USB/NVMe)", 180, "w"),
            "status": ("Stato", 105, "center"),
        }
        for col, (label, width, anchor) in headers.items():
            self.tree.heading(col, text=label)
            self.tree.column(col, width=width, anchor=anchor)

        vsb = ttk.Scrollbar(table_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True, padx=(6, 0), pady=6)
        vsb.pack(side="right", fill="y", padx=(0, 6), pady=6)

        self.tree.bind("<ButtonRelease-1>", self._on_tree_click)

        # --- 4. Barra Azioni ---
        action_frame = ttk.Frame(self.root)
        action_frame.pack(fill="x", padx=8, pady=4)

        ttk.Button(action_frame, text="Seleziona Tutti", command=self.select_all).pack(side="left", padx=4)
        ttk.Button(action_frame, text="Deseleziona Tutti", command=self.deselect_all).pack(side="left", padx=4)

        self.auto_reboot_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(
            action_frame,
            text="Riavvia automaticamente a fine Upgrade",
            variable=self.auto_reboot_var,
        ).pack(side="left", padx=16)

        self.btn_upgrade = ttk.Button(
            action_frame, text="Lancia Upgrade sui Selezionati (pisetup.sh)", command=self.start_upgrade
        )
        self.btn_upgrade.pack(side="right", padx=4)

        self.btn_bootorder = ttk.Button(
            action_frame, text="Cambia Boot Order (pibootorder.sh)", command=self.open_bootorder_dialog
        )
        self.btn_bootorder.pack(side="right", padx=6)

        self.btn_verify = ttk.Button(
            action_frame, text="Verifica Selezionati (piverify.sh)", command=self.start_verify
        )
        self.btn_verify.pack(side="right", padx=6)

        # --- 5. Console Log Live ---
        log_frame = ttk.LabelFrame(self.root, text=" Output Live (curl / SSH) ")
        log_frame.pack(fill="both", expand=True, **pad)

        self.log_box = scrolledtext.ScrolledText(
            log_frame, height=11, bg="#1e1e1e", fg="#d4d4d4", font=("Monospace", 9), state="disabled"
        )
        self.log_box.pack(fill="both", expand=True, padx=6, pady=6)

    def _refresh_env_badge(self):
        path = self._find_local_env_file()
        data = parse_env_file(path) if path else {}
        required = ("TARGET_USER", "TARGET_PASSWORD_HASH", "SSH_AUTHORIZED_KEY")
        if path and all(data.get(k, "").strip() for k in required):
            self.env_status_var.set(f".env: OK ({data['TARGET_USER']})")
        else:
            self.env_status_var.set(".env: Da configurare")

    def _toggle_auth_fields(self):
        state = "disabled" if self.use_ssh_key_var.get() else "normal"
        self.entry_user.configure(state=state)
        self.entry_pass.configure(state=state)
        self.entry_sudo.configure(state=state)

    def _set_busy(self, busy: bool):
        self.busy = busy
        if busy:
            self.cancel_event.clear()
        st = "disabled" if busy else "normal"
        self.btn_scan.configure(state=st)
        self.btn_verify.configure(state=st)
        self.btn_bootorder.configure(state=st)
        self.btn_upgrade.configure(state=st)
        self.btn_env_cfg.configure(state=st)
        self.btn_cancel.configure(state="normal" if busy else "disabled")

    def cancel_operation(self):
        if self.busy:
            self.cancel_event.set()
            self.log("[!] Interruzione richiesta dall'utente, arresto sessione remota in corso...")

    def log(self, msg: str):
        self.ui_queue.put(("log", msg))

    def _process_ui_queue(self):
        while not self.ui_queue.empty():
            kind, payload = self.ui_queue.get_nowait()
            if kind == "log":
                self.log_box.configure(state="normal")
                self.log_box.insert("end", payload + "\n")
                self.log_box.see("end")
                self.log_box.configure(state="disabled")
            elif kind == "upsert_host":
                ip, banner, auto_select = payload
                self._upsert_host_row(ip, banner, auto_select)
            elif kind == "update_verify":
                ip, info = payload
                if self.tree.exists(ip):
                    vals = list(self.tree.item(ip, "values"))
                    vals[3] = info.get("model", "-")
                    vals[4] = info.get("os", "-")
                    vals[5] = info.get("boot_dev", "-")
                    vals[6] = info.get("boot_order", "-")
                    vals[7] = info.get("disks", "-")
                    vals[8] = info.get("status", "Verificato")
                    self.tree.item(ip, values=vals)
            elif kind == "update_boot_order":
                ip, bo_decoded, status_txt = payload
                if self.tree.exists(ip):
                    vals = list(self.tree.item(ip, "values"))
                    if bo_decoded:
                        vals[6] = bo_decoded
                    vals[8] = status_txt
                    self.tree.item(ip, values=vals)
            elif kind == "update_status":
                ip, status_txt = payload
                if self.tree.exists(ip):
                    vals = list(self.tree.item(ip, "values"))
                    vals[8] = status_txt
                    self.tree.item(ip, values=vals)
            elif kind == "ask_confirm":
                question, event, result_holder = payload
                result_holder["ans"] = messagebox.askyesno("Conferma richiesta da pisetup.sh", question)
                event.set()
            elif kind == "done":
                self._set_busy(False)
        self.root.after(100, self._process_ui_queue)

    # --- Wizard / Editor per cloud-init-data.env con Auto-Discovery dal Sistema ---
    def open_env_dialog(self) -> bool:
        """Apre il configuratore di cloud-init-data.env. Restituisce True se salvato con successo."""
        save_path = get_default_env_save_path()
        existing = parse_env_file(save_path)

        sys_user = detect_system_username()
        auto_ssh = discover_ssh_public_key()
        auto_ssid, auto_psk = discover_wifi_credentials()

        init_user = existing.get("TARGET_USER") or sys_user
        existing_hash = existing.get("TARGET_PASSWORD_HASH", "")
        init_ssh = existing.get("SSH_AUTHORIZED_KEY") or auto_ssh
        init_ssid = existing.get("WIFI_SSID") if "WIFI_SSID" in existing else auto_ssid
        init_psk = existing.get("WIFI_PASSWORD") if "WIFI_PASSWORD" in existing else auto_psk

        saved_flag = {"ok": False}

        dlg = tk.Toplevel(self.root)
        dlg.title("Configurazione Locale cloud-init-data.env")
        dlg.geometry("680x470")
        dlg.resizable(False, False)
        dlg.transient(self.root)
        dlg.grab_set()

        info_lbl = ttk.Label(
            dlg,
            text=(
                f"Percorso file: {save_path}\n"
                "I campi vuoti sono stati precompilati automaticamente con i dati rilevati da questo PC."
            ),
            font=("Sans", 9),
        )
        info_lbl.pack(anchor="w", padx=16, pady=(12, 8))

        form = ttk.LabelFrame(dlg, text=" Parametri Utente, SSH e Rete Wi-Fi per Ubuntu Server ")
        form.pack(fill="both", expand=True, padx=16, pady=6)
        form.columnconfigure(1, weight=1)

        # 1. TARGET_USER
        ttk.Label(form, text="Utente Linux (TARGET_USER):").grid(row=0, column=0, padx=10, pady=8, sticky="w")
        v_user = tk.StringVar(value=init_user)
        ttk.Entry(form, textvariable=v_user, width=28).grid(row=0, column=1, padx=8, pady=8, sticky="w")

        # 2. Password -> TARGET_PASSWORD_HASH
        pw_label_txt = (
            "Nuova Password Utente (vuoto = mantieni hash attuale):"
            if existing_hash
            else "Password Utente sui Pi (verrà cifrata in SHA-512):"
        )
        ttk.Label(form, text=pw_label_txt).grid(row=1, column=0, padx=10, pady=8, sticky="w")
        v_pw = tk.StringVar()
        ent_pw = ttk.Entry(form, textvariable=v_pw, show="*", width=32)
        ent_pw.grid(row=1, column=1, padx=8, pady=8, sticky="w")

        # 3. SSH_AUTHORIZED_KEY
        ttk.Label(form, text="Chiave Pubblica SSH:").grid(row=2, column=0, padx=10, pady=8, sticky="nw")
        v_ssh = tk.StringVar(value=init_ssh)
        ent_ssh = ttk.Entry(form, textvariable=v_ssh, width=52)
        ent_ssh.grid(row=2, column=1, padx=8, pady=8, sticky="ew")

        ssh_btn_frame = ttk.Frame(form)
        ssh_btn_frame.grid(row=3, column=1, padx=8, pady=(0, 8), sticky="w")

        def _redetect_ssh():
            k = discover_ssh_public_key()
            if k:
                v_ssh.set(k)
            else:
                messagebox.showinfo("Chiave SSH", "Nessuna chiave pubblica trovata in ~/.ssh o ssh-agent.", parent=dlg)

        def _generate_ssh():
            ssh_dir = os.path.expanduser("~/.ssh")
            os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
            key_file = os.path.join(ssh_dir, "id_ed25519")
            if os.path.exists(key_file):
                if not messagebox.askyesno(
                    "Chiave già esistente",
                    f"Il file {key_file} esiste già. Vuoi caricare la sua chiave pubblica senza sovrascriverlo?",
                    parent=dlg,
                ):
                    return
            else:
                rc = subprocess.call(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", key_file])
                if rc != 0:
                    messagebox.showerror("Errore ssh-keygen", "Generazione chiave SSH fallita.", parent=dlg)
                    return
            pub_file = key_file + ".pub"
            if os.path.isfile(pub_file):
                with open(pub_file, "r", encoding="utf-8", errors="ignore") as f:
                    v_ssh.set(f.readline().strip())

        ttk.Button(ssh_btn_frame, text="Rileva da questo PC", command=_redetect_ssh).pack(side="left", padx=(0, 6))
        ttk.Button(ssh_btn_frame, text="Genera nuova chiave ed25519", command=_generate_ssh).pack(side="left")

        # 4. WIFI_SSID
        ttk.Label(form, text="Wi-Fi SSID:").grid(row=4, column=0, padx=10, pady=8, sticky="w")
        v_ssid = tk.StringVar(value=init_ssid)
        ssid_row = ttk.Frame(form)
        ssid_row.grid(row=4, column=1, padx=8, pady=8, sticky="ew")
        ttk.Entry(ssid_row, textvariable=v_ssid, width=28).pack(side="left")

        # 5. WIFI_PASSWORD
        ttk.Label(form, text="Wi-Fi Password:").grid(row=5, column=0, padx=10, pady=8, sticky="w")
        v_wpsk = tk.StringVar(value=init_psk)
        ent_wpsk = ttk.Entry(form, textvariable=v_wpsk, show="*", width=32)
        ent_wpsk.grid(row=5, column=1, padx=8, pady=8, sticky="w")

        def _redetect_wifi():
            s, p = discover_wifi_credentials()
            if s:
                v_ssid.set(s)
                if p:
                    v_wpsk.set(p)
            else:
                messagebox.showinfo(
                    "Wi-Fi PC",
                    "Nessuna interfaccia Wi-Fi attiva rilevata su questo PC (es. connesso solo via cavo Ethernet).",
                    parent=dlg,
                )

        ttk.Button(ssid_row, text="Rileva Wi-Fi attivo dal PC", command=_redetect_wifi).pack(side="left", padx=8)

        # Mostra/Nascondi password
        v_show = tk.BooleanVar(value=False)

        def _toggle_show():
            ch = "" if v_show.get() else "*"
            ent_pw.configure(show=ch)
            ent_wpsk.configure(show=ch)

        ttk.Checkbutton(
            form, text="Mostra password in chiaro", variable=v_show, command=_toggle_show
        ).grid(row=6, column=1, padx=8, pady=6, sticky="w")

        # Pulsanti Salva / Annulla
        btn_bar = ttk.Frame(dlg)
        btn_bar.pack(fill="x", padx=16, pady=(6, 12))

        def _save():
            user_clean = v_user.get().strip()
            ssh_clean = v_ssh.get().strip()
            pw_plain = v_pw.get()
            ssid_clean = v_ssid.get().strip()
            wpsk_clean = v_wpsk.get()

            if not user_clean or not re.match(r"^[a-z_][a-z0-9_-]*$", user_clean):
                messagebox.showerror(
                    "Utente non valido",
                    "Inserisci un nome utente Linux valido (solo lettere minuscole, numeri, '-' o '_').",
                    parent=dlg,
                )
                return

            if pw_plain:
                try:
                    final_hash = generate_sha512_password_hash(pw_plain)
                except Exception as e:
                    messagebox.showerror("Errore Hash Password", f"Impossibile generare l'hash SHA-512: {e}", parent=dlg)
                    return
            elif existing_hash:
                final_hash = existing_hash
            else:
                messagebox.showerror(
                    "Password mancante",
                    "Inserisci una password per l'utente Linux (verrà salvata solo come hash SHA-512).",
                    parent=dlg,
                )
                return

            if not ssh_clean or not ssh_clean.startswith(("ssh-", "ecdsa-", "sk-")):
                messagebox.showerror(
                    "Chiave SSH non valida",
                    "Inserisci una chiave pubblica SSH valida (es. ssh-ed25519 AAAA...) oppure clicca 'Genera nuova chiave'.",
                    parent=dlg,
                )
                return

            content_lines = [
                "# Generato da PiTools GUI (escluso da Git)",
                f"TARGET_USER={bash_single_quote(user_clean)}",
                f"TARGET_PASSWORD_HASH={bash_single_quote(final_hash)}",
                f"SSH_AUTHORIZED_KEY={bash_single_quote(ssh_clean)}",
                f"WIFI_SSID={bash_single_quote(ssid_clean)}",
                f"WIFI_PASSWORD={bash_single_quote(wpsk_clean)}",
                "",
            ]
            try:
                os.makedirs(os.path.dirname(save_path), exist_ok=True)
                with open(save_path, "w", encoding="utf-8", newline="\n") as f:
                    f.write("\n".join(content_lines))
                os.chmod(save_path, 0o600)
            except OSError as e:
                messagebox.showerror("Errore Scrittura", f"Impossibile salvare {save_path}:\n{e}", parent=dlg)
                return

            self.user_var.set(user_clean)
            self._refresh_env_badge()
            self.log(f"[OK] Salvato {save_path} (chmod 600) per utente '{user_clean}'.")
            saved_flag["ok"] = True
            dlg.destroy()

        ttk.Button(btn_bar, text="Annulla", command=dlg.destroy).pack(side="right", padx=4)
        ttk.Button(btn_bar, text="Salva cloud-init-data.env", command=_save).pack(side="right", padx=4)

        self.root.wait_window(dlg)
        return saved_flag["ok"]

    # --- Gestione Tabella e Selezione ---
    def _upsert_host_row(self, ip: str, banner: str = "-", auto_select: bool = True):
        if self.tree.exists(ip):
            vals = list(self.tree.item(ip, "values"))
            if banner and banner != "-":
                vals[2] = banner
            self.tree.item(ip, values=vals)
            return

        if auto_select:
            self.selected_ips.add(ip)
        mark = "[✓]" if ip in self.selected_ips else "[ ]"
        self.tree.insert("", "end", iid=ip, values=(mark, ip, banner, "-", "-", "-", "-", "-", "Rilevato"))

    def _on_tree_click(self, event):
        item_id = self.tree.identify_row(event.y)
        if not item_id:
            return
        if item_id in self.selected_ips:
            self.selected_ips.remove(item_id)
            mark = "[ ]"
        else:
            self.selected_ips.add(item_id)
            mark = "[✓]"
        vals = list(self.tree.item(item_id, "values"))
        vals[0] = mark
        self.tree.item(item_id, values=vals)

    def select_all(self):
        for iid in self.tree.get_children():
            self.selected_ips.add(iid)
            vals = list(self.tree.item(iid, "values"))
            vals[0] = "[✓]"
            self.tree.item(iid, values=vals)

    def deselect_all(self):
        self.selected_ips.clear()
        for iid in self.tree.get_children():
            vals = list(self.tree.item(iid, "values"))
            vals[0] = "[ ]"
            self.tree.item(iid, values=vals)

    def add_manual_ip(self):
        ip_str = self.manual_ip_var.get().strip()
        try:
            ipaddress.ip_address(ip_str)
        except ValueError:
            messagebox.showerror("IP non valido", "Inserisci un indirizzo IPv4 valido (es. 192.168.0.117).")
            return
        banner = grab_ssh_banner(ip_str, timeout=1.2) or "Inserito manualmente"
        self._upsert_host_row(ip_str, banner, auto_select=True)
        self.manual_ip_var.set("")

    # --- 1. Scansione con pifinder.sh (online) + nmap ---
    def start_scan(self):
        if self.busy:
            return
        subnet = self.subnet_var.get().strip()
        try:
            net = ipaddress.ip_network(subnet, strict=False)
            subnet = str(net)
            self.subnet_var.set(subnet)
        except ValueError:
            messagebox.showerror("Subnet non valida", "Formato atteso: es. 192.168.0.0/24")
            return

        self._set_busy(True)
        threading.Thread(target=self._scan_worker, args=(subnet,), daemon=True).start()

    def _scan_worker(self, subnet: str):
        try:
            net = ipaddress.ip_network(subnet, strict=False)
            found_ips: set[str] = set()

            self.log(f"=== Avvio scansione su {subnet} ===")
            self.log(f"[*] Esecuzione online: curl -4 -fsSL {URL_PIFINDER} | bash -s -- {subnet}")

            try:
                proc = subprocess.run(
                    [
                        "bash",
                        "-c",
                        f'curl -4 -fsSL --connect-timeout 8 --max-time 25 "{URL_PIFINDER}" | bash -s -- "{subnet}"',
                    ],
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                out_clean = strip_ansi(proc.stdout)
                for line in out_clean.splitlines():
                    if line.strip():
                        self.log(f"  [pifinder] {line}")
                    for m in re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", line):
                        try:
                            ip_obj = ipaddress.ip_address(m)
                            if ip_obj in net and ip_obj != net.network_address and ip_obj != net.broadcast_address:
                                found_ips.add(str(ip_obj))
                        except ValueError:
                            pass
            except Exception as e:
                self.log(f"[WARN] pifinder.sh non completato o timeout: {e}")

            if self.cancel_event.is_set():
                return

            self.log(f"[*] Scansione TCP/22 con nmap su {subnet} (compatibile WSL2 e Pi Imager)...")
            try:
                nproc = subprocess.run(
                    ["nmap", "-n", "-T4", "-p", "22", "--open", subnet, "-oG", "-"],
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                for line in nproc.stdout.splitlines():
                    if "22/open" in line:
                        m = re.search(r"Host:\s+(\d+\.\d+\.\d+\.\d+)", line)
                        if m:
                            found_ips.add(m.group(1))
            except FileNotFoundError:
                self.log("[WARN] Comando 'nmap' non installato: uso solo i risultati di pifinder.sh.")
            except Exception as e:
                self.log(f"[WARN] Errore nmap: {e}")

            if not found_ips:
                self.log("[!] Nessun host con SSH (porta 22) rilevato nella subnet indicata.")
                return

            self.log(f"[*] Verifica banner SSH su {len(found_ips)} host rilevati...")
            with ThreadPoolExecutor(max_workers=16) as pool:
                future_map = {pool.submit(grab_ssh_banner, ip): ip for ip in sorted(found_ips)}
                for fut in as_completed(future_map):
                    ip = future_map[fut]
                    banner = fut.result() or "SSH / Sconosciuto"
                    is_likely_pi = any(k in banner.lower() for k in ("debian", "rpt", "raspbian", "ubuntu", "openssh"))
                    is_router = "dropbear" in banner.lower()
                    self.ui_queue.put(("upsert_host", (ip, banner, is_likely_pi and not is_router)))

            self.log(f"[OK] Scansione terminata: {len(found_ips)} nodi elencati in tabella.")
        finally:
            self.ui_queue.put(("done", None))

    # --- Connessione SSH & Runner PTY Anti-Freeze ---
    def _connect_ssh(self, ip: str) -> tuple[paramiko.SSHClient, str]:
        use_key = self.use_ssh_key_var.get()
        user = self.user_var.get().strip() or detect_default_user()
        password = self.pass_var.get()
        sudo_pass = self.sudo_var.get() or password

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        if use_key:
            client.connect(
                ip,
                username=user,
                look_for_keys=True,
                allow_agent=True,
                timeout=8,
                banner_timeout=10,
                auth_timeout=10,
            )
            if client.get_transport():
                client.get_transport().set_keepalive(10)
            return client, ""
        else:
            client.connect(
                ip,
                username=user,
                password=password,
                look_for_keys=False,
                allow_agent=False,
                timeout=8,
                banner_timeout=10,
                auth_timeout=10,
            )
            if client.get_transport():
                client.get_transport().set_keepalive(10)
            return client, sudo_pass

    def _run_remote_pty(
        self,
        client: paramiko.SSHClient,
        ip: str,
        cmd: str,
        sudo_pass: str,
        idle_timeout: float = 35.0,
        prompt_handler=None,
    ) -> tuple[int, str]:
        transport = client.get_transport()
        if not transport or not transport.is_active():
            raise RuntimeError("Trasporto SSH non attivo")

        chan = transport.open_session(timeout=10)
        chan.get_pty(width=160, height=40)
        chan.exec_command(cmd)

        full_clean = ""
        line_buf = ""
        tail_buf = ""
        sudo_sent = False
        last_activity = time.monotonic()
        exit_seen_at = None

        while True:
            if self.cancel_event.is_set():
                try:
                    chan.send("\x03")
                    chan.close()
                except Exception:
                    pass
                raise RuntimeError("Operazione interrotta dall'utente")

            if chan.recv_ready():
                raw = chan.recv(4096).decode("utf-8", errors="ignore")
                last_activity = time.monotonic()
                clean_chunk = strip_ansi(raw)
                full_clean += clean_chunk
                tail_buf = (tail_buf + clean_chunk)[-600:]

                line_buf += clean_chunk
                while "\n" in line_buf:
                    line, line_buf = line_buf.split("\n", 1)
                    if line.strip() and "[PT_SUDO]" not in line:
                        self.log(f"  [{ip}] {line}")

                if ("Sorry, try again" in tail_buf or "incorrect password" in tail_buf.lower()) and sudo_sent:
                    chan.send("\x03")
                    chan.close()
                    raise RuntimeError("Password Sudo rifiutata dal nodo remoto")

                if re.search(r"(\[PT_SUDO\]|\[sudo\] password|Password:)", tail_buf):
                    if sudo_pass and not sudo_sent:
                        chan.send(sudo_pass + "\n")
                        sudo_sent = True
                        tail_buf = ""
                    elif not sudo_pass:
                        self.log(f"  [{ip}] [WARN] Sudo richiede password (invio Ctrl+C per evitare blocco)")
                        chan.send("\x03")
                        tail_buf = ""

                if prompt_handler is not None:
                    new_tail = prompt_handler(chan, tail_buf)
                    if new_tail is not None:
                        tail_buf = new_tail
                        last_activity = time.monotonic()

            if chan.exit_status_ready():
                if exit_seen_at is None:
                    exit_seen_at = time.monotonic()
                if not chan.recv_ready() and (time.monotonic() - exit_seen_at) > 0.2:
                    break

            if (time.monotonic() - last_activity) > idle_timeout:
                try:
                    chan.send("\x03")
                    chan.close()
                except Exception:
                    pass
                raise TimeoutError(f"Nessun output ricevuto per {int(idle_timeout)}s (timeout comando/rete sul Pi)")

            time.sleep(0.05)

        if line_buf.strip() and "[PT_SUDO]" not in line_buf:
            self.log(f"  [{ip}] {line_buf.strip()}")

        rc = chan.recv_exit_status() if chan.exit_status_ready() else -1
        chan.close()
        return rc, full_clean

    # --- 2. Verifica con piverify.sh ---
    def start_verify(self):
        if self.busy:
            return
        targets = sorted(self.selected_ips)
        if not targets:
            messagebox.showwarning("Nessun Pi selezionato", "Spunta almeno un Raspberry Pi nella tabella.")
            return
        if not self.use_ssh_key_var.get() and not self.user_var.get().strip():
            messagebox.showerror("Credenziali mancanti", "Inserisci il nome utente SSH.")
            return

        self._set_busy(True)
        threading.Thread(target=self._verify_worker, args=(targets,), daemon=True).start()

    def _verify_worker(self, targets: list[str]):
        try:
            for ip in targets:
                if self.cancel_event.is_set():
                    break
                self.ui_queue.put(("update_status", (ip, "Verifica...")))
                self.log(f"\n=== [{ip}] Verifica in corso via {URL_PIVERIFY} ===")
                client = None
                try:
                    client, sudo_pass = self._connect_ssh(ip)
                    self.log(f"  [{ip}] Connessione SSH stabilita, scaricamento piverify.sh (IPv4)...")

                    sudo_prep = f'sudo -p "[PT_SUDO] " -v && ' if sudo_pass else "sudo -n -v 2>/dev/null || true; "
                    cmd = f'{sudo_prep}curl -4 -fsSL --connect-timeout 8 --max-time 25 "{URL_PIVERIFY}" | bash'

                    _rc, clean = self._run_remote_pty(client, ip, cmd, sudo_pass, idle_timeout=35.0)
                    parsed = self._parse_piverify_output(clean)
                    self.ui_queue.put(("update_verify", (ip, parsed)))
                except Exception as e:
                    self.log(f"[ERRORE {ip}] Connessione/Verifica fallita: {e}")
                    self.ui_queue.put(("update_status", (ip, "Errore")))
                finally:
                    if client:
                        client.close()
        finally:
            self.ui_queue.put(("done", None))

    @staticmethod
    def _parse_piverify_output(text: str) -> dict:
        info = {
            "model": "-",
            "os": "-",
            "boot_dev": "-",
            "boot_order": "-",
            "disks": "-",
            "status": "Verificato [OK]",
        }
        m_hw = re.search(r"Hardware\s*:\s*(.+)", text)
        if m_hw:
            info["model"] = m_hw.group(1).strip()

        m_os = re.search(r"SO Rilevato\s*:\s*(.+)", text)
        if m_os:
            info["os"] = m_os.group(1).strip()

        m_root = re.search(r"Rootfs montato su:\s*(.+)", text)
        if m_root:
            info["boot_dev"] = m_root.group(1).strip()

        m_bo = re.search(r"BOOT_ORDER=(\S+)", text)
        if m_bo:
            info["boot_order"] = decode_boot_order(m_bo.group(1).strip())

        disks = []
        for line in text.splitlines():
            m_d = re.match(r"^(mmcblk\d+|nvme\d+n\d+|sd[a-z]+)\s+disk\s+(\S+)", line.strip())
            if m_d:
                dev, size = m_d.group(1), m_d.group(2)
                if dev.startswith("mmcblk"):
                    disks.append(f"SD ({size})")
                elif dev.startswith("nvme"):
                    disks.append(f"NVMe ({size})")
                elif dev.startswith("sd"):
                    disks.append(f"USB ({size})")
        if disks:
            info["disks"] = ", ".join(disks)

        return info

    # --- 3. Cambio Ordine di Boot con pibootorder.sh ---
    def open_bootorder_dialog(self):
        if self.busy:
            return
        targets = sorted(self.selected_ips)
        if not targets:
            messagebox.showwarning("Nessun Pi selezionato", "Spunta almeno un Raspberry Pi nella tabella.")
            return
        if not self.use_ssh_key_var.get() and not self.user_var.get().strip():
            messagebox.showerror("Credenziali mancanti", "Inserisci il nome utente SSH.")
            return

        dlg = tk.Toplevel(self.root)
        dlg.title("Cambia Ordine di Boot EEPROM (pibootorder.sh)")
        dlg.geometry("470x305")
        dlg.resizable(False, False)
        dlg.transient(self.root)
        dlg.grab_set()

        ttk.Label(
            dlg,
            text=f"Nodi selezionati ({len(targets)}): " + ", ".join(targets[:4]) + ("..." if len(targets) > 4 else ""),
            font=("Sans", 9, "bold"),
        ).pack(anchor="w", padx=16, pady=(14, 8))

        mode_frame = ttk.LabelFrame(dlg, text=" Modalità BOOT_ORDER ")
        mode_frame.pack(fill="x", padx=16, pady=6)

        mode_var = tk.StringVar(value="toggle")
        ttk.Radiobutton(
            mode_frame, text="Inverti automatico (Toggle SD ↔ NVMe/USB)", variable=mode_var, value="toggle"
        ).pack(anchor="w", padx=10, pady=3)
        ttk.Radiobutton(
            mode_frame, text="Forza microSD First (sd → 0xf461 / 0xf41)", variable=mode_var, value="sd"
        ).pack(anchor="w", padx=10, pady=3)
        ttk.Radiobutton(
            mode_frame, text="Forza NVMe/USB First (external → 0xf146 / 0xf14)", variable=mode_var, value="external"
        ).pack(anchor="w", padx=10, pady=3)

        act_frame = ttk.LabelFrame(dlg, text=" Azione dopo scrittura EEPROM ")
        act_frame.pack(fill="x", padx=16, pady=6)

        act_var = tk.StringVar(value="n")
        ttk.Radiobutton(act_frame, text="Nessuna (resta acceso)", variable=act_var, value="n").pack(
            side="left", padx=10, pady=6
        )
        ttk.Radiobutton(act_frame, text="Riavvia (reboot)", variable=act_var, value="r").pack(
            side="left", padx=10, pady=6
        )
        ttk.Radiobutton(act_frame, text="Spegni (poweroff)", variable=act_var, value="p").pack(
            side="left", padx=10, pady=6
        )

        btn_bar = ttk.Frame(dlg)
        btn_bar.pack(fill="x", padx=16, pady=(10, 12))

        def _confirm():
            chosen_mode = mode_var.get()
            chosen_act = act_var.get()
            dlg.destroy()
            self._set_busy(True)
            threading.Thread(
                target=self._bootorder_worker, args=(targets, chosen_mode, chosen_act), daemon=True
            ).start()

        ttk.Button(btn_bar, text="Annulla", command=dlg.destroy).pack(side="right", padx=4)
        ttk.Button(btn_bar, text="Applica su EEPROM", command=_confirm).pack(side="right", padx=4)

    def _bootorder_worker(self, targets: list[str], mode: str, post_action: str):
        try:
            for ip in targets:
                if self.cancel_event.is_set():
                    break
                self.ui_queue.put(("update_status", (ip, "BootOrder...")))
                self.log(f"\n=== [{ip}] Cambio ordine di boot ({mode}) via {URL_PIBOOTORDER} ===")
                client = None
                try:
                    client, sudo_pass = self._connect_ssh(ip)
                    sudo_prep = f'sudo -p "[PT_SUDO] " -v && ' if sudo_pass else "sudo -n -v && "
                    cmd = (
                        f'{sudo_prep}curl -4 -fsSL --connect-timeout 8 --max-time 25 "{URL_PIBOOTORDER}" '
                        f'| sudo bash -s -- "{mode}"'
                    )
                    state = {"sent": False}

                    def _on_prompt(chan, tail):
                        if "Azione post-aggiornamento:" in tail and not state["sent"]:
                            state["sent"] = True
                            self.log(f"  [{ip}] Invio azione post-EEPROM: {post_action}")
                            chan.send(f"{post_action}\n")
                            return ""
                        return None

                    rc, full_clean = self._run_remote_pty(
                        client, ip, cmd, sudo_pass, idle_timeout=60.0, prompt_handler=_on_prompt
                    )

                    m_new = re.search(r"BOOT_ORDER=(0x[0-9a-fA-F]+)", full_clean)
                    if not m_new:
                        m_new = re.search(r"BOOT_ORDER nuovo\s*:\s*(0x[0-9a-fA-F]+)", full_clean)
                    bo_decoded = decode_boot_order(m_new.group(1)) if m_new else ""

                    if state["sent"] or rc == 0:
                        st_map = {"r": "Riavvio...", "p": "Spento [OK]", "n": "EEPROM [OK]"}
                        self.ui_queue.put(("update_boot_order", (ip, bo_decoded, st_map.get(post_action, "EEPROM [OK]"))))
                    else:
                        self.ui_queue.put(("update_status", (ip, f"Errore (rc={rc})")))
                except Exception as e:
                    self.log(f"[ERRORE {ip}] Cambio BOOT_ORDER fallito: {e}")
                    self.ui_queue.put(("update_status", (ip, "Fallito")))
                finally:
                    if client:
                        client.close()
        finally:
            self.ui_queue.put(("done", None))

    # --- 4. Upgrade con pisetup.sh ---
    def start_upgrade(self):
        if self.busy:
            return
        targets = sorted(self.selected_ips)
        if not targets:
            messagebox.showwarning("Nessun Pi selezionato", "Spunta uno o più Raspberry Pi su cui lanciare pisetup.sh.")
            return

        env_path = self._find_local_env_file()
        env_data = parse_env_file(env_path) if env_path else {}
        required = ("TARGET_USER", "TARGET_PASSWORD_HASH", "SSH_AUTHORIZED_KEY")

        if not env_path or not all(env_data.get(k, "").strip() for k in required):
            messagebox.showinfo(
                "Configurazione cloud-init richiesta",
                "Il file 'cloud-init-data.env' non è presente o è incompleto.\n"
                "Si aprirà ora la finestra precompilata con i dati rilevati dal tuo sistema.",
            )
            if not self.open_env_dialog():
                return
            env_path = self._find_local_env_file()

        msg = (
            f"Stai per lanciare pisetup.sh online (formattazione disco NVMe/USB con Ubuntu LTS) su {len(targets)} nodo/i:\n\n"
            + "\n".join(f"  • {ip}" for ip in targets)
            + f"\n\nFile configurazione usato: {env_path}\nVuoi procedere?"
        )
        if not messagebox.askyesno("Conferma Upgrade Raspberry Pi", msg):
            return

        self._set_busy(True)
        threading.Thread(target=self._upgrade_worker, args=(targets, env_path), daemon=True).start()

    @staticmethod
    def _find_local_env_file() -> str:
        candidates = [
            os.path.abspath("./cloud-init-data.env"),
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud-init-data.env"),
            os.path.expanduser("~/pitools/cloud-init-data.env"),
        ]
        for path in candidates:
            if os.path.isfile(path):
                return path
        return ""

    def _upgrade_worker(self, targets: list[str], env_path: str):
        try:
            with open(env_path, "r", encoding="utf-8", errors="ignore") as f:
                clean_env_bytes = f.read().replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")

            for ip in targets:
                if self.cancel_event.is_set():
                    break
                self.ui_queue.put(("update_status", (ip, "Upgrade...")))
                self.log(f"\n=======================================================")
                self.log(f"[{ip}] Avvio provisioning con {URL_PISETUP}")
                self.log(f"=======================================================")
                client = None
                try:
                    client, sudo_pass = self._connect_ssh(ip)
                    user = self.user_var.get().strip() or detect_default_user()

                    sftp = client.open_sftp()
                    remote_home = sftp.normalize(".")
                    remote_env = f"{remote_home}/cloud-init-data.env"
                    with sftp.file(remote_env, "wb") as rf:
                        rf.write(clean_env_bytes)
                    sftp.chmod(remote_env, 0o600)
                    sftp.close()
                    self.log(f"[{ip}] Caricato cloud-init-data.env → {remote_env} (utente: {user})")

                    sudo_prep = f'sudo -p "[PT_SUDO] " -v && ' if sudo_pass else "sudo -n -v && "
                    cmd = f'{sudo_prep}curl -4 -fsSL --connect-timeout 10 "{URL_PISETUP}" | sudo bash'
                    state = {"non_sd": False, "reboot": False}

                    def _on_prompt(chan, tail):
                        if "Vuoi proseguire comunque? (s/N):" in tail and not state["non_sd"]:
                            state["non_sd"] = True
                            ev = threading.Event()
                            res = {"ans": False}
                            self.ui_queue.put((
                                "ask_confirm",
                                (f"Il nodo {ip} NON risulta avviato da microSD.\nVuoi proseguire comunque?", ev, res),
                            ))
                            ev.wait()
                            chan.send("s\n" if res["ans"] else "n\n")
                            return ""

                        if "Vuoi riavviare ora il Raspberry Pi" in tail and not state["reboot"]:
                            state["reboot"] = True
                            ans = "s\n" if self.auto_reboot_var.get() else "n\n"
                            self.log(f"  [{ip}] Risposta automatica al prompt di riavvio: {ans.strip()}")
                            chan.send(ans)
                            return ""
                        return None

                    rc, _out = self._run_remote_pty(
                        client, ip, cmd, sudo_pass, idle_timeout=180.0, prompt_handler=_on_prompt
                    )

                    if state["reboot"] or rc == 0:
                        final_st = "Riavviato [OK]" if self.auto_reboot_var.get() else "Completato [OK]"
                        self.ui_queue.put(("update_status", (ip, final_st)))
                        self.log(f"[OK] Upgrade completato con successo su {ip}.")
                    else:
                        self.ui_queue.put(("update_status", (ip, f"Errore (rc={rc})")))
                        self.log(f"[ERRORE] pisetup.sh terminato con codice {rc} su {ip}.")
                except Exception as e:
                    self.log(f"[ERRORE {ip}] Upgrade interrotto: {e}")
                    self.ui_queue.put(("update_status", (ip, "Fallito")))
                finally:
                    if client:
                        client.close()
        finally:
            self.ui_queue.put(("done", None))


if __name__ == "__main__":
    root = tk.Tk()
    style = ttk.Style(root)
    if "clam" in style.theme_names():
        style.theme_use("clam")
    app = PiToolsGUI(root)
    root.mainloop()
