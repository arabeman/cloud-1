# Mémo — commandes du lab cloud-1

Aide-mémoire personnel. À compléter au fur et à mesure du projet.

Arborescence de travail :

```
~/Projects/cloud-1/lab/      le code du lab (versionné)
├── 00-setup-host.sh         installe l'outillage sur l'hôte
├── 99-teardown-host.sh      annule tout
├── cloud-init/
│   ├── user-data            ce que JE veux configurer
│   └── meta-data            l'identité de l'instance
└── state/                   empreinte des paquets (pour le démontage)

~/vms/                       les données lourdes (NON versionné)
├── base/jammy.img           image Ubuntu 22.04, téléchargée une fois
├── disks/cloud1.qcow2       disque de la VM (copy-on-write)
└── seeds/cloud1.iso         faux CD-ROM lu par cloud-init
```

---

## 1. Le lab

```bash
cd ~/Projects/cloud-1/lab

./00-setup-host.sh              # installe/vérifie (idempotent, relançable)
./99-teardown-host.sh --vms-only # supprime les VMs, garde l'outillage + l'image de base
./99-teardown-host.sh           # démonte tout

# ⚠️ avant un teardown complet, relire ce qui va être purgé :
cat state/packages-added.txt
```

---

## 2. libvirt — piloter les VMs

`virsh` parle à libvirt, qui gère les VMs. `--connect qemu:///system` désigne
l'instance système (celle du démon), pas une instance personnelle.

```bash
# Éviter de retaper --connect à chaque fois :
export LIBVIRT_DEFAULT_URI=qemu:///system

virsh list                   # VMs en cours d'exécution
virsh list --all             # toutes, y compris éteintes
virsh dominfo cloud1         # RAM, vCPU, état
virsh domifaddr cloud1       # ➜ l'adresse IP de la VM

virsh start cloud1           # allumer
virsh shutdown cloud1        # extinction propre (demande au système)
virsh destroy cloud1         # couper le jus (brutal, immédiat)
virsh reboot cloud1

virsh console cloud1         # console série — sortir avec Ctrl+]
virsh undefine cloud1 --remove-all-storage   # supprimer VM + disques
```

### Réseau

```bash
virsh net-list --all         # doit montrer "default : active / autostart yes"
virsh net-dhcp-leases default # quelle IP a été donnée à qui
virsh net-edit default       # éditer (baux statiques par MAC)
```

`default` = réseau NAT en `192.168.122.0/24`, passerelle `192.168.122.1`
(l'interface `virbr0` sur l'hôte). Les VMs voient internet ; depuis l'hôte on
les joint directement. Elles ne sont pas visibles depuis le reste du LAN.

### Diagnostic

```bash
virt-host-validate qemu      # la virtualisation est-elle utilisable ?
systemctl status libvirtd
journalctl -xeu libvirtd     # quand une VM refuse de démarrer
```

---

## 3. Disques — `qemu-img`

```bash
# Télécharger l'image de base (une seule fois) — "jammy" = Ubuntu 22.04
curl -L -o ~/vms/base/jammy.img \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
chmod 444 ~/vms/base/jammy.img      # la protéger : tous les disques en dépendent

# Créer un disque copy-on-write par-dessus
qemu-img create -f qcow2 -F qcow2 \
    -b ~/vms/base/jammy.img \
    ~/vms/disks/cloud1.qcow2 15G

qemu-img info ~/vms/disks/cloud1.qcow2   # voir le "backing file" et les tailles
ls -lh ~/vms/disks/cloud1.qcow2          # taille apparente (15G)
du -h  ~/vms/disks/cloud1.qcow2          # place réellement occupée (~200K)
```

- `-f` = format du nouveau disque · `-F` = format du disque de dessous · `-b` = le disque de dessous
- Lecture : bloc modifié → dans le qcow2, sinon → dans l'image de base.
  Écriture : toujours dans le qcow2. **L'image de base n'est jamais touchée.**
- Le chemin du backing file est enregistré en dur : ne jamais déplacer `jammy.img`.
- La partition interne fait 2,2 Go, `cloud-init` l'agrandit à 15 Go au 1er boot.

---

## 4. cloud-init

Deux fichiers, deux rôles :

| | Qui le fournit | Contenu |
|---|---|---|
| `meta-data` | la plateforme (ici : nous) | ce que la machine **est** : `instance-id`, `local-hostname` |
| `user-data` | moi, le propriétaire | ce qu'elle doit **devenir** : comptes, clés SSH |

`user-data` doit commencer par `#cloud-config` en **première ligne** — c'est la
signature du format, pas un commentaire. Sans elle, le fichier est ignoré en silence.

**Règle d'or : `user-data` ne fait que ce qu'un fournisseur cloud ferait.**
Docker, le firewall, TLS → c'est le travail d'Ansible, jamais de cloud-init.
Sinon le playbook n'est plus testé sur une machine vierge.

`instance-id` sert à l'idempotence : cloud-init le mémorise et ne reconfigure
que s'il change. Donc **un instance-id distinct par VM**.

```bash
# Vérifier le YAML — afficher le parsing, pas juste "OK" :
# un YAML valide peut être un YAML incorrect (mauvaise indentation = mauvais niveau)
python3 -c 'import yaml,json; print(json.dumps(yaml.safe_load(open("cloud-init/user-data")),indent=2))'

# Fabriquer le faux CD-ROM (volume nommé "cidata", cherché par cloud-init)
cloud-localds ~/vms/seeds/cloud1.iso cloud-init/user-data cloud-init/meta-data
```

Depuis l'intérieur de la VM :

```bash
cloud-init status --long     # terminé ? en erreur ?
cloud-init query instance_id
sudo cat /var/log/cloud-init-output.log   # ce qui s'est réellement passé au boot
```

### YAML en 3 règles

1. `clé: valeur` — un espace après les deux-points
2. l'indentation crée l'imbrication (ce qui est décalé appartient à ce qui est au-dessus)
3. `-` marque un élément de liste

**Des espaces, jamais de tabulation.**

---

## 5. SSH

```bash
ssh-keygen -t ed25519 -C "cloud1-lab" -f ~/.ssh/cloud1_ed25519 -N ""
cat ~/.ssh/cloud1_ed25519.pub          # publique : partageable, à copier partout
ssh-keygen -y -f ~/.ssh/cloud1_ed25519 # recalcule la publique depuis la privée
ssh-keygen -l -f ~/.ssh/cloud1_ed25519.pub  # empreinte

ssh -i ~/.ssh/cloud1_ed25519 ubuntu@192.168.122.x
```

- **`.pub` = publique**, une ligne, commence par `ssh-ed25519` → peut être committée
- **sans extension = privée**, plusieurs lignes, contient `PRIVATE KEY` → ne sort jamais de la machine
- La clé privée n'est jamais transmise : elle signe un défi aléatoire, le serveur
  vérifie la signature avec la clé publique. D'où la possibilité de couper
  complètement l'authentification par mot de passe.
- Permissions : la clé privée doit être en `600`, sinon SSH refuse de l'utiliser.

Quand une VM est recréée avec la même IP, SSH refuse de se connecter
(l'empreinte du serveur a changé — protection contre l'usurpation) :

```bash
ssh-keygen -R 192.168.122.11    # oublier l'ancienne empreinte
```

---

## 6. Créer la VM

```bash
# à compléter — virt-install
```

---

## 7. Principes à ne pas perdre de vue

- **Idempotence** : une commande d'automatisation doit pouvoir être rejouée
  sans effet de bord. Vérifier avant d'agir. Le critère de qualité d'un
  playbook, c'est `changed=0` au second passage.
- **Vérifier par le comportement, pas par la déclaration** : `virsh version`
  répond-il ? plutôt que `systemctl is-active`. Un service peut être « actif »
  et inutilisable.
- **Connaître l'état avant de modifier** : c'est ce qui rend un démontage exact
  et un playbook idempotent.
- **Séparer ce qui dépend de l'environnement** (IP, utilisateur, domaine → dans
  l'inventaire) de ce qui est la logique (→ dans les rôles).
- Un firewall ne rattrape pas une mauvaise configuration réseau : **Docker
  contourne ufw** (règles en `FORWARD`/`DOCKER`, ufw agit sur `INPUT`). Un port
  qu'on ne publie pas n'a pas besoin d'être bloqué.
