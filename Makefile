DOMAIN = mickaia-cloud-1.duckdns.org
NAME = cloud-1

CERTBOT_DIR = $(CURDIR)/secrets/letsencrypt
ACME_DIR = $(CURDIR)/secrets/acme

COMPOSE_WEB = docker compose -f ./srcs/docker-compose.web.yml
COMPOSE_DB  = docker compose -f ./srcs/docker-compose.db.yml

up-web:
	$(COMPOSE_WEB) up -d --build

up-db:
	$(COMPOSE_DB) up -d --build

init-wp:
	$(COMPOSE_WEB) --profile init up wp-cli

down-web:
	$(COMPOSE_WEB) down

down-db:
	$(COMPOSE_DB) down

restart-web:
	$(COMPOSE_WEB) restart nginx

cert:
	docker run --rm \
		-v "$(CERTBOT_DIR):/etc/letsencrypt" \
		-v "$(ACME_DIR):/var/www/certbot" \
		certbot/certbot certonly \
		--webroot \
		--webroot-path /var/www/certbot \
		-d $(DOMAIN) \
		--email ramahazonick@gmail.com \
		--agree-tos \
		--no-eff-email \
		--keep-until-expiring

clean-web:
	$(COMPOSE_WEB) down --rmi all --volumes --remove-orphans

clean-db:
	$(COMPOSE_DB) down --rmi all --volumes --remove-orphans

fclean-web: clean-web
	sudo rm -rf $(HOME)/data/wordpress/*

fclean-db: clean-db
	sudo rm -rf $(HOME)/data/mariadb/*