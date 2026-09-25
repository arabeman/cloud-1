DOMAIN = mickaia-cloud-1.duckdns.org

NAME = cloud-1

COMPOSE = docker compose -f ./srcs/docker-compose.yml

CERTBOT_DIR = $(CURDIR)/secrets/letsencrypt
ACME_DIR = $(CURDIR)/secrets/acme

COMPOSE_WEB = docker compose -f ./srcs/docker-compose.web.yml
COMPOSE_DB  = docker compose -f ./srcs/docker-compose.db.yml

all:
	$(COMPOSE) up -d --build

up-web:
	$(COMPOSE_WEB) up -d --build

up-db:
	$(COMPOSE_DB) up -d --build

init-wp:
	$(COMPOSE_WEB) --profile init up wp-cli

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) down
	$(COMPOSE) up -d --build

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

clean:
	docker compose -f ./srcs/docker-compose.yml down --rmi all --volumes --remove-orphans
	docker system prune -af

fclean: clean
	sudo rm -rf $(HOME)/data/wordpress/*
	sudo rm -rf $(HOME)/data/mariadb/*

reset-data:
	docker compose -f ./srcs/docker-compose.yml down
	sudo rm -rf $(HOME)/data/wordpress/*
	sudo rm -rf $(HOME)/data/mariadb/*