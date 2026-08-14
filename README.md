# cloud-1

Déploiement automatisé d'une stack WordPress sur un serveur distant (projet 42).

## Architecture

```
internet ──:80/:443──► nginx ──► wordpress ──┐
                         └────► phpmyadmin ──┴──► db
                       [frontend]              [backend]
```

- `nginx` — reverse proxy, seul service exposé ; route selon le nom de domaine
- `wordpress` — image officielle, variante apache
- `phpmyadmin` — administration de la base
- `db` — MySQL, **aucun port publié, aucune route depuis nginx**

## Prérequis

Debian ou Ubuntu. Le script du lab installe l'outillage (libvirt, QEMU, Ansible) :

```bash
./lab/00-setup-host.sh
```

## Monter un serveur de test

Une VM Ubuntu 22.04 jetable, via libvirt + cloud-init. Les commandes détaillées
sont dans [lab/MEMO.md](lab/MEMO.md) — en résumé :

```bash
# image de base (une fois)
mkdir -p ~/vms/base ~/vms/disks ~/vms/seeds
curl -L -o ~/vms/base/jammy.img \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# disque + seed cloud-init + démarrage
qemu-img create -f qcow2 -F qcow2 -b ~/vms/base/jammy.img ~/vms/disks/cloud1.qcow2 15G
cloud-localds ~/vms/seeds/cloud1.iso lab/cloud-init/user-data lab/cloud-init/meta-data
virt-install --name cloud1 --memory 2048 --vcpus 2 --import \
  --disk path=$HOME/vms/disks/cloud1.qcow2,format=qcow2 \
  --disk path=$HOME/vms/seeds/cloud1.iso,device=cdrom \
  --network network=default --osinfo ubuntu22.04 --graphics none --noautoconsole
```

Ajoute ta clé publique dans `lab/cloud-init/user-data` avant de créer le seed.

## Déployer

```bash
cp .env.example .env          # puis remplir (valeurs à demander à Mick)
rsync -av --exclude lab --exclude .git ./ cloud1:~/wordpress/
ssh cloud1 'cd ~/wordpress && docker compose up -d'
```

## Vérifier

Sur la machine cliente, `/etc/hosts` :

```
192.168.122.2  cloud1.com pma.cloud1.com
```

Puis `http://cloud1.com` et `http://pma.cloud1.com`.

```bash
docker compose ps                                  # 4 services Up, db healthy
docker exec wordpress-nginx-1 getent hosts db      # doit échouer : isolation OK
```

## Choix techniques

- **WordPress en apache, pas php-fpm** — nginx reste un pur reverse proxy HTTP,
  pas besoin de partager le volume des fichiers WordPress avec lui.
- **Deux réseaux** — nginx n'est pas sur `backend`, il n'a aucune route vers la
  base. Combiné à l'absence de port publié, ça fait deux barrières indépendantes.
- **Pas de `depends_on: service_healthy`** — WordPress sait se reconnecter et
  `restart` fait le reste ; on évite un délai à calibrer à la main.
- **Images épinglées** — `latest` rendrait le déploiement non reproductible.
- **Secrets hors du dépôt** — `.env` est ignoré, `.env.example` documente les clés.

## État

Fait : stack complète en HTTP, routage par nom, isolation réseau, persistance.

Reste à faire :
- [ ] TLS (auto-signé en lab, Let's Encrypt sur l'instance publique)
- [ ] bloc `default_server` → `return 444`
- [ ] installation automatique de WordPress (wp-cli)
- [ ] rôles Ansible : docker, app, firewall
- [ ] firewall : seuls 22, 80, 443
