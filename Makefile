DOMAIN = mickaia-cloud-1.duckdns.org

NAME = cloud-1

COMPOSE = docker compose -f ./srcs/docker-compose.yml

all:
	$(COMPOSE) up -d --build

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) down
	$(COMPOSE) up -d --build

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

cert:
	docker run --rm \
		-v "$(PWD)/secrets/letsencrypt:/etc/letsencrypt" \
		-v "$(PWD)/secrets/acme:/var/www/certbot" \
		certbot/certbot certonly \
		--webroot \
		--webroot-path /var/www/certbot \
		-d $(DOMAIN) \
		--email ramahazonick@gmail.com \
		--agree-tos \
		--no-eff-email

clean:
	docker compose -f ./srcs/docker-compose.yml down --rmi all --volumes --remove-orphans
	docker system prune -af

fclean: clean
	sudo rm -rf $(HOME)/data/wordpress/*
	sudo rm -rf $(HOME)/data/mariadb/*

reset-data:
	docker compose -f ./srcs/docker-compose.yml down
	rm -rf $(HOME)/data/wordpress/*
	rm -rf $(HOME)/data/mariadb/*