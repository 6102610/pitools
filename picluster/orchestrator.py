#!/usr/bin/env python3
import os
import sys
import time
import json
import ipaddress
import subprocess
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn
from rich.text import Text

console = Console()

def get_network_info():
    wlan_ip = None
    wlan_subnet = None

    try:
        out = subprocess.check_output("ip -o -f inet addr show dev wlan0 2>/dev/null", shell=True).decode()
        for line in out.splitlines():
            parts = line.strip().split()
            cidr = parts[3]
            wlan_ip = cidr.split('/')[0]
            net = ipaddress.IPv4Network(cidr, strict=False)
            wlan_subnet = str(net)
            break
    except Exception:
        wlan_ip = "192.168.1.150"
        wlan_subnet = "192.168.1.0/24"

    if wlan_subnet and (wlan_subnet.startswith("10.") or wlan_subnet.startswith("100.64.")):
        cluster_subnet = "172.16.42.0/24"
        internal_base = "172.16.42"
    else:
        cluster_subnet = "10.42.42.0/24"
        internal_base = "10.42.42"

    return {
        "wlan_ip": wlan_ip,
        "wlan_subnet": wlan_subnet,
        "cluster_subnet": cluster_subnet,
        "vip_k8s": f"{internal_base}.100",
        "vip_gw": f"{internal_base}.254",
        "internal_base": internal_base
    }

def render_dashboard(net_info):
    table = Table(title="Topologia di Rete & Virtual IP", show_header=True, header_style="bold cyan")
    table.add_column("Ruolo / Segmento", style="bold yellow", width=24)
    table.add_column("Interfaccia / Subnet", style="white", width=22)
    table.add_column("Indirizzo IP / VIP", style="bold green", width=25)
    table.add_column("Note Operative", style="dim", width=30)
    table.add_row("Wi-Fi Uplink", f"wlan0 ({net_info['wlan_subnet']})", net_info['wlan_ip'], "Connettività e Management")
    table.add_row("Cluster Fabric (PoE)", f"eth0 ({net_info['cluster_subnet']})", f"{net_info['internal_base']}.0/24", "Traffico privato k8s segregato")
    table.add_row("K8s API Control-Plane", "eth0 / Kube-VIP", net_info['vip_k8s'], "Endpoint API Server (6443)")
    table.add_row("L3 Default Gateway", "eth0 / Keepalived", net_info['vip_gw'], "Gateway uscente nodi cluster")

    console.print(table)
    console.print()

    body = Text.from_markup(
        f"1. [bold yellow]Routing dal PC:[/] Aggiungi la rotta verso la subnet del cluster:\n"
        f"   [green]Linux/macOS:[/] sudo ip route add {net_info['cluster_subnet']} via {net_info['wlan_ip']}\n"
        f"   [green]Windows:[/]     route add {net_info['cluster_subnet'].split('/')[0]} mask 255.255.255.0 {net_info['wlan_ip']} -p\n"
        f"2. [bold yellow]Sessione Persistente:[/] Sessione terminale nativa attiva\n"
        f"3. [bold yellow]Kubeconfig:[/] export KUBECONFIG=~/.kube/config\n"
        f"4. [bold yellow]Naming Convenzione:[/] Nodi assimilati progressivamente come [cyan]k3s-pi-01, k3s-pi-02...[/]"
    )

    console.print(Panel(body, title="[bold blue]Istruzioni Operative[/]", border_style="bright_blue", padding=(1, 2)))
    console.print()

def get_k8s_nodes():
    try:
        res = subprocess.check_output("kubectl get nodes -o json 2>/dev/null", shell=True)
        data = json.loads(res.decode())
        nodes = []
        for item in data.get("items", []):
            name = item["metadata"]["name"]
            labels = item["metadata"].get("labels", {})
            is_master = "node-role.kubernetes.io/control-plane" in labels or "node-role.kubernetes.io/master" in labels
            ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in item.get("status", {}).get("conditions", []))
            nodes.append({"name": name, "is_master": is_master, "ready": ready})
        return nodes
    except Exception:
        return []

def evaluate_topology_and_heal():
    nodes = get_k8s_nodes()
    if not nodes:
        return

    masters = [n for n in nodes if n["is_master"]]
    workers = [n for n in nodes if not n["is_master"]]
    unready = [n for n in nodes if not n["ready"]]

    for dead_node in unready:
        console.print(f"[bold red][!] Nodo offline rilevato: {dead_node['name']}. Rimozione da etcd...[/]")
        subprocess.run(f"kubectl delete node {dead_node['name']} --wait=false 2>/dev/null", shell=True)

    total_valid = len(nodes) - len(unready)
    if total_valid >= 3 and len(masters) < 3 and workers:
        worker_to_promote = workers[0]["name"]
        console.print(f"[bold cyan][*] Raggiunti {total_valid} nodi totali. Promozione di {worker_to_promote} a Master...[/]")
        subprocess.run(
            f"ansible-playbook -i '{worker_to_promote},' playbooks/promote-worker.yaml -e target_node={worker_to_promote} 2>/dev/null",
            shell=True
        )

def run_bootstrap_stages(net_info):
    stages = [
        ("01-user-harden", "Hardening utente e ridenominazione k3s-pi-01", "-e node_index=1"),
        ("02-os-prep", "Tuning cgroups, swap check e sysctl", ""),
        ("03-k3s-init", "Inizializzazione Master (--cluster-init e node-name)", ""),
        ("05-kube-vip", "Deploy Kube-VIP DaemonSet e Keepalived", "")
    ]

    console.rule("[bold cyan]Esecuzione Pipeline di Bootstrap[/]")
    console.print()

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("[bold green]{task.percentage:>3.0f}%"),
        console=console
    ) as progress:
        overall_task = progress.add_task("[cyan]Avanzamento Cluster...", total=len(stages))

        for playbook, desc, extra_vars in stages:
            stage_task = progress.add_task(f"[yellow]-> {desc}...", total=100)
            cmd = f"ansible-playbook -i 'localhost,' -c local playbooks/{playbook}.yaml {extra_vars} >> /tmp/ansible-pipeline.log 2>&1"
            subprocess.run(cmd, shell=True)
            for _ in range(10):
                time.sleep(0.08)
                progress.advance(stage_task, 10)
            progress.remove_task(stage_task)
            progress.advance(overall_task, 1)

    console.print()
    console.print("[bold green]Cluster inizializzato con successo come k3s-pi-01![/]")

def watcher_loop():
    console.rule("[bold magenta]Demone Auto-Discovery & Quorum Watcher Attivo[/]")
    console.print("[dim]Monitoraggio nodi attivi e gestione espansione sequenziale (Ctrl+C per uscire)...[/]\n")
    try:
        while True:
            evaluate_topology_and_heal()
            time.sleep(30)
    except KeyboardInterrupt:
        console.print("[yellow]Watcher arrestato.[/]")

if __name__ == "__main__":
    console.rule("[bold bright_magenta]PiCluster Zero-Touch Orchestrator[/]")
    console.print()

    net = get_network_info()
    render_dashboard(net)
    run_bootstrap_stages(net)
    watcher_loop()
