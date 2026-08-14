#!/usr/bin/env bash
#
# cloud-1 — Démontage complet du lab
#
# Annule ce que 00-setup-host.sh (et la création de VMs) a mis en place.
# On démonte de l'intérieur vers l'extérieur : VMs → stockage → réseau →
# paquets → groupes. L'ordre compte : on ne retire pas un réseau encore utilisé.
#
# Usage :
#   ./99-teardown-host.sh            # démontage complet (avec confirmation)
#   ./99-teardown-host.sh --vms-only # ne supprime que les VMs et leurs disques
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/state"
PKGS_ADDED="${STATE_DIR}/packages-added.txt"
VM_DIR="${HOME}/vms"

VMS_ONLY=0
[[ "${1:-}" == "--vms-only" ]] && VMS_ONLY=1

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

[[ ${EUID} -ne 0 ]] || { echo "Ne lance pas ce script en root." >&2; exit 1; }

vsh() { sudo virsh --connect qemu:///system "$@"; }
has_libvirt() { command -v virsh >/dev/null && sudo virsh --connect qemu:///system version &>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# Confirmation — on montre ce qui va disparaître AVANT de le détruire
# ─────────────────────────────────────────────────────────────────────────────

printf '\n%sDémontage du lab cloud-1%s\n' "$C_YELLOW" "$C_RESET"
printf 'Va être supprimé :\n'
printf '  · toutes les VMs libvirt et leurs disques\n'
printf '  · %s\n' "${VM_DIR}"
if (( ! VMS_ONLY )); then
    printf '  · le réseau libvirt "default" et les pools de stockage\n'
    if [[ -f "${PKGS_ADDED}" ]]; then
        printf '  · %s paquets (liste : %s)\n' "$(wc -l < "${PKGS_ADDED}")" "${PKGS_ADDED#"${SCRIPT_DIR}/"}"
    else
        printf '  · les paquets qemu/libvirt/ansible\n'
    fi
    printf '  · ton appartenance aux groupes libvirt et kvm\n'
fi
printf '\nTa configuration réseau hôte (wlo1), ton kernel et tes données ne sont pas touchés.\n'
printf '\nTape %soui%s pour confirmer : ' "$C_RED" "$C_RESET"
read -r answer
[[ "${answer}" == "oui" ]] || { printf 'Annulé.\n'; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. VMs
# ─────────────────────────────────────────────────────────────────────────────

step "VMs"

if has_libvirt; then
    # --name : ne récupérer que les noms, sans l'en-tête du tableau
    mapfile -t vms < <(vsh list --all --name | sed '/^$/d')
    if (( ${#vms[@]} == 0 )); then
        skip "aucune VM définie"
    else
        for vm in "${vms[@]}"; do
            # destroy = couper le jus. La VM va être supprimée, un arrêt propre
            # n'apporte rien. || true : elle est peut-être déjà éteinte.
            vsh destroy "${vm}" &>/dev/null || true
            # undefine --remove-all-storage : retire la définition XML ET les disques
            if vsh undefine "${vm}" --remove-all-storage &>/dev/null; then
                ok "${vm} supprimée (définition + disques)"
            else
                # Certaines VMs ont un firmware UEFI dont le nvram bloque l'undefine
                vsh undefine "${vm}" --remove-all-storage --nvram &>/dev/null \
                    && ok "${vm} supprimée (définition + disques + nvram)" \
                    || warn "${vm} : undefine a échoué, à traiter à la main"
            fi
        done
    fi
else
    skip "libvirt absent ou injoignable"
fi

# En mode --vms-only on préserve ~/vms/base : l'image cloud pèse ~700 Mo et ne
# change jamais. La retélécharger à chaque remise à zéro serait une perte de
# temps pure. Seuls les disques et les seeds, qui sont dérivés, sont jetés.
if (( VMS_ONLY )); then
    targets=("${VM_DIR}/disks" "${VM_DIR}/seeds")
else
    targets=("${VM_DIR}")
fi

for target in "${targets[@]}"; do
    if [[ -d "${target}" ]]; then
        du_size=$(du -sh "${target}" 2>/dev/null | cut -f1)
        rm -rf "${target}"
        ok "${target} supprimé (${du_size} récupérés)"
    else
        skip "${target} inexistant"
    fi
done

if (( VMS_ONLY )); then
    [[ -d "${VM_DIR}/base" ]] && skip "${VM_DIR}/base conservé (image de base)"
    printf '\n%s─────%s Démontage partiel terminé. L'"'"'outillage reste installé.\n\n' "$C_BLUE" "$C_RESET"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Pools de stockage
# ─────────────────────────────────────────────────────────────────────────────

step "Pools de stockage"

if has_libvirt; then
    mapfile -t pools < <(vsh pool-list --all --name | sed '/^$/d')
    if (( ${#pools[@]} == 0 )); then
        skip "aucun pool"
    else
        for pool in "${pools[@]}"; do
            vsh pool-destroy "${pool}" &>/dev/null || true
            vsh pool-undefine "${pool}" &>/dev/null \
                && ok "pool ${pool} retiré" \
                || warn "pool ${pool} : undefine a échoué"
        done
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Réseau
# ─────────────────────────────────────────────────────────────────────────────

step "Réseau libvirt"

if has_libvirt && vsh net-info default &>/dev/null; then
    vsh net-destroy default &>/dev/null || true
    vsh net-undefine default &>/dev/null \
        && ok "réseau 'default' retiré (virbr0 disparaît)" \
        || warn "réseau 'default' : undefine a échoué"
else
    skip "réseau 'default' absent"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Paquets
# ─────────────────────────────────────────────────────────────────────────────

step "Paquets"

if [[ -f "${PKGS_ADDED}" ]] && [[ -s "${PKGS_ADDED}" ]]; then
    # On purge la liste exacte de ce que l'installation a ajouté.
    # C'est tout l'intérêt d'avoir pris une empreinte avant : un démontage
    # chirurgical, sans deviner et sans retirer un paquet qui préexistait.
    mapfile -t to_purge < "${PKGS_ADDED}"
    printf '  purge de %s paquet(s)…\n' "${#to_purge[@]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "${to_purge[@]}" || \
        warn "certains paquets n'ont pas pu être purgés"
else
    warn "empreinte introuvable — purge de la liste par défaut"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-daemon-driver-qemu \
        libvirt-clients virtinst cloud-image-utils ansible || \
        warn "certains paquets n'ont pas pu être purgés"
fi
sudo apt-get autoremove --purge -y
ok "paquets purgés"

# Résidus : /etc/libvirt contient les définitions XML, /var/lib/libvirt les images
# du pool par défaut. Ce ne sont pas des conffiles, apt purge ne les retire pas.
for d in /etc/libvirt /var/lib/libvirt; do
    if [[ -d "${d}" ]]; then
        sudo rm -rf "${d}"
        ok "${d} supprimé"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 5. Groupes
# ─────────────────────────────────────────────────────────────────────────────

step "Groupes"

for grp in libvirt kvm; do
    if getent group "${grp}" >/dev/null && id -nG "${USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
        sudo gpasswd -d "${USER}" "${grp}" >/dev/null \
            && ok "${USER} retiré de ${grp}" \
            || warn "${USER} : retrait de ${grp} a échoué"
    else
        skip "${USER} n'est pas dans ${grp}"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────

printf '\n%s─────────────────────────────────────────────────────────%s\n' "$C_BLUE" "$C_RESET"
printf '\nDémontage terminé.\n'
printf 'Vérifie si tu veux : %sip -br addr | grep virbr ; which virsh ansible%s\n' "$C_DIM" "$C_RESET"
printf '(les deux doivent ne rien retourner)\n\n'
printf 'L'"'"'empreinte %s est conservée, au cas où tu recommences.\n\n' "${STATE_DIR#"${SCRIPT_DIR}/"}"
