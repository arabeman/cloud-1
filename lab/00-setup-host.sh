#!/usr/bin/env bash
#
# cloud-1 — Étape 0.a : préparer la machine hôte (control node + hyperviseur)
#
# Ce script NE crée aucune VM. Il installe et vérifie l'outillage :
#   - QEMU/KVM + libvirt  : pour héberger les VMs cibles
#   - virtinst / cloud-*  : pour créer des VMs depuis une image cloud
#   - Ansible             : le control node, d'où partiront les déploiements
#
# Propriétés voulues :
#   - IDEMPOTENT : relançable autant de fois que nécessaire, sans effet de bord
#   - TRAÇABLE   : capture la liste des paquets avant/après, pour un démontage exact
#   - VÉRIFIÉ    : la source de vérité est le comportement observé, pas l'état déclaré
#
# Démontage : ./99-teardown-host.sh
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

# Pourquoi ces paquets — tu dois pouvoir le défendre :
PACKAGES=(
    qemu-system-x86              # l'hyperviseur x86, accéléré par KVM (/dev/kvm)
    qemu-utils                   # qemu-img : créer/inspecter les disques qcow2
    libvirt-daemon-system        # le démon libvirtd : VMs, réseaux, pools
    libvirt-daemon-driver-qemu   # le driver qemu de libvirt (explicite : c'est un Recommends)
    libvirt-clients              # virsh, l'outil de pilotage en CLI
    dnsmasq-base                 # DHCP+DNS du réseau NAT libvirt (sans lui, "default" ne démarre pas)
    virtinst                     # virt-install : créer une VM en une commande
    cloud-image-utils            # cloud-localds : fabriquer le seed ISO de cloud-init
    genisoimage                  # utilisé par cloud-localds pour générer l'ISO
    ansible                      # le control node
)

MIN_ROOT_GB=4                    # marge disque exigée sur / avant installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/state"
PKGS_BEFORE="${STATE_DIR}/packages-before.txt"
PKGS_ADDED="${STATE_DIR}/packages-added.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers d'affichage
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

step() { printf '\n%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
skip() { printf '  %s·%s %s\n'   "$C_DIM"    "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '\n  %s✗ %s%s\n\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Pré-vols — échouer tôt et avec un message clair, plutôt que tard et obscur
# ─────────────────────────────────────────────────────────────────────────────

step "Vérifications préalables"

# Surtout pas root : on doit ajouter TON compte aux groupes, pas celui de root.
[[ ${EUID} -ne 0 ]] || die "Ne lance pas ce script en root (sudo est appelé au besoin)."

command -v apt-get >/dev/null || die "Ce script cible une distribution Debian/Ubuntu."
ok "distribution : $(. /etc/os-release && echo "${PRETTY_NAME}")"

# La virtualisation matérielle : sans elle, QEMU émule tout en logiciel (10x plus lent).
grep -Eq '(vmx|svm)' /proc/cpuinfo \
    || die "Pas de VT-x/AMD-V détecté. Vérifie que la virtualisation est activée dans le BIOS/UEFI."
ok "virtualisation matérielle présente ($(grep -Eom1 '(vmx|svm)' /proc/cpuinfo))"

# /dev/kvm est fourni par le kernel : il existe AVANT toute installation.
# C'est la preuve qu'on n'installe que de l'espace utilisateur autour de KVM.
[[ -e /dev/kvm ]] || die "/dev/kvm absent : le module kvm n'est pas chargé (modprobe kvm_intel ?)."
ok "/dev/kvm présent"

avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
(( avail_gb >= MIN_ROOT_GB )) \
    || die "Seulement ${avail_gb} Go libres sur / (il en faut ${MIN_ROOT_GB})."
ok "espace disque sur / : ${avail_gb} Go"

# On demande sudo maintenant, pas au milieu du script.
sudo -v || die "Droits sudo requis."
ok "droits sudo confirmés"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Empreinte de l'état AVANT — pour pouvoir démonter exactement
# ─────────────────────────────────────────────────────────────────────────────
#
# Réflexe à retenir : avant de modifier un système, sache décrire son état.
# C'est le même raisonnement qui rend un playbook Ansible idempotent — Ansible
# compare l'état constaté à l'état voulu avant d'agir.

step "Empreinte des paquets installés"

mkdir -p "${STATE_DIR}"

if [[ -f "${PKGS_BEFORE}" ]]; then
    # Ne JAMAIS écraser l'empreinte d'origine : c'est la référence du démontage.
    skip "empreinte déjà prise le $(date -r "${PKGS_BEFORE}" '+%d/%m/%Y à %H:%M') — conservée"
else
    dpkg-query -W -f='${Package}\n' | sort > "${PKGS_BEFORE}"
    ok "$(wc -l < "${PKGS_BEFORE}") paquets recensés → ${PKGS_BEFORE#"${SCRIPT_DIR}/"}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Installation
# ─────────────────────────────────────────────────────────────────────────────

step "Installation de l'outillage"

# Idempotence : on ne fait un apt-get install que pour ce qui manque réellement.
missing=()
for pkg in "${PACKAGES[@]}"; do
    if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'ok installed'; then
        skip "${pkg}"
    else
        missing+=("${pkg}")
    fi
done

if (( ${#missing[@]} == 0 )); then
    ok "tous les paquets sont déjà installés"
else
    printf '  installation de : %s\n' "${missing[*]}"
    sudo apt-get update -qq
    # DEBIAN_FRONTEND=noninteractive : aucune question posée, le script reste automatique.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    ok "${#missing[@]} paquet(s) installé(s)"
fi

# Différentiel : la liste exacte de ce qui a été ajouté, pour le démontage.
comm -13 "${PKGS_BEFORE}" <(dpkg-query -W -f='${Package}\n' | sort) > "${PKGS_ADDED}"
ok "$(wc -l < "${PKGS_ADDED}") paquet(s) ajouté(s) au total → ${PKGS_ADDED#"${SCRIPT_DIR}/"}"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Groupes — pour piloter libvirt sans sudo
# ─────────────────────────────────────────────────────────────────────────────

step "Appartenance aux groupes"

groups_changed=0
for grp in libvirt kvm; do
    if ! getent group "${grp}" >/dev/null; then
        warn "le groupe ${grp} n'existe pas (inattendu) — ignoré"
    elif id -nG "${USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
        skip "${USER} est déjà dans ${grp}"
    else
        sudo usermod -aG "${grp}" "${USER}"
        ok "${USER} ajouté à ${grp}"
        groups_changed=1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 5. Services — et surtout : survivre au reboot
# ─────────────────────────────────────────────────────────────────────────────
#
# Le sujet cloud-1 exige que le site redémarre seul après un reboot du serveur.
# Le même principe s'applique à ton lab : un service qui tourne mais qui ne
# revient pas au boot ne "marche" pas vraiment. On active ET on démarre.

step "Service libvirtd"

if systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | grep -q libvirtd; then
    if ! systemctl is-enabled --quiet libvirtd 2>/dev/null; then
        sudo systemctl enable --quiet libvirtd || warn "enable libvirtd a échoué (socket-activation ?)"
    fi
    if ! systemctl is-active --quiet libvirtd; then
        sudo systemctl start libvirtd || warn "start libvirtd a échoué"
    fi
fi

# La source de vérité, c'est le comportement : est-ce que virsh répond ?
if sudo virsh --connect qemu:///system version >/dev/null 2>&1; then
    ok "libvirt répond ($(sudo virsh --connect qemu:///system version 2>/dev/null \
         | awk '/Running hypervisor/{print $3, $4}'))"
else
    die "libvirt ne répond pas. Diagnostique avec : systemctl status libvirtd ; journalctl -xeu libvirtd"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Réseau NAT "default" — 192.168.122.0/24
# ─────────────────────────────────────────────────────────────────────────────
#
# Pas de bridge L2 : ta machine est en WiFi, et le 802.11 n'autorise en pratique
# qu'une MAC par station. On utilise donc le réseau NAT de libvirt.
# Ce n'est pas un compromis ici : Ansible ET les VMs sont sur le même hôte, donc
# on joint directement 192.168.122.x sur les ports 22/80/443. Rien à rediriger.

step "Réseau libvirt 'default'"

vsh() { sudo virsh --connect qemu:///system "$@"; }

if ! vsh net-info default >/dev/null 2>&1; then
    default_xml=/usr/share/libvirt/networks/default.xml
    [[ -f "${default_xml}" ]] || die "Réseau 'default' absent et ${default_xml} introuvable."
    vsh net-define "${default_xml}" >/dev/null
    ok "réseau 'default' défini depuis ${default_xml}"
else
    skip "réseau 'default' déjà défini"
fi

net_state=$(vsh net-info default | awk -F': *' '/^Active/{print $2}')
if [[ "${net_state}" != "yes" ]]; then
    vsh net-start default >/dev/null
    ok "réseau 'default' démarré"
else
    skip "réseau 'default' déjà actif"
fi

net_auto=$(vsh net-info default | awk -F': *' '/^Autostart/{print $2}')
if [[ "${net_auto}" != "yes" ]]; then
    vsh net-autostart default >/dev/null
    ok "autostart activé (le réseau survivra au reboot de ta machine)"
else
    skip "autostart déjà activé"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Vérification finale — on observe, on ne suppose pas
# ─────────────────────────────────────────────────────────────────────────────

step "Vérification"

# L'accélération KVM est-elle réellement utilisable ? Sans elle, tout sera lent.
#
# On demande à libvirt de RÉSOUDRE les capacités du type 'kvm' : s'il ne peut pas
# l'utiliser, la commande échoue. C'est un test de comportement.
# (Ne pas grepper les capabilities : libvirt y écrit <domain type='kvm'/> en
#  auto-fermante, et un motif attendant '>' donne un faux négatif silencieux.)
if sudo virsh --connect qemu:///system domcapabilities --virttype kvm >/dev/null 2>&1; then
    ok "accélération KVM opérationnelle"
else
    warn "KVM inutilisable : les VMs tourneraient en émulation logicielle (très lent)"
    warn "diagnostique avec : virt-host-validate qemu"
fi

# virbr0 : l'interface virtuelle du réseau NAT. Elle est AJOUTÉE à côté de wlo1,
# ta configuration réseau hôte n'est pas modifiée.
if ip -br addr show virbr0 &>/dev/null; then
    ok "virbr0 : $(ip -br addr show virbr0 | awk '{print $3}')"
else
    warn "virbr0 absent — le réseau 'default' n'est peut-être pas réellement actif"
fi

ok "ansible : $(ansible --version 2>/dev/null | head -1)"
ok "virt-install : $(virt-install --version 2>/dev/null)"
ok "qemu-img : $(qemu-img --version 2>/dev/null | head -1 | cut -d' ' -f1-3)"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Ce qu'il te reste à faire
# ─────────────────────────────────────────────────────────────────────────────

printf '\n%s─────────────────────────────────────────────────────────%s\n' "$C_BLUE" "$C_RESET"

if (( groups_changed )); then
    printf '\n%sACTION REQUISE%s — tu as été ajouté à de nouveaux groupes.\n' "$C_YELLOW" "$C_RESET"
    printf 'Un changement de groupe ne prend effet que dans une NOUVELLE session :\n'
    printf '  · déconnecte/reconnecte ta session, ou\n'
    printf '  · lance %snewgrp libvirt%s pour ce shell uniquement\n' "$C_DIM" "$C_RESET"
    printf '\nVérifie ensuite que tu pilotes libvirt sans sudo :\n'
    printf '  %svirsh --connect qemu:///system net-list --all%s\n' "$C_DIM" "$C_RESET"
else
    printf '\nHôte prêt. Vérifie que tu pilotes libvirt sans sudo :\n'
    printf '  %svirsh --connect qemu:///system net-list --all%s\n' "$C_DIM" "$C_RESET"
fi

printf '\nPour tout annuler : %s./99-teardown-host.sh%s\n\n' "$C_DIM" "$C_RESET"
