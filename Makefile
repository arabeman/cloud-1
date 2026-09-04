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

reset-data:
	docker compose -f ./srcs/docker-compose.yml down
	rm -rf $(HOME)/data/wordpress/*
	rm -rf $(HOME)/data/mariadb/*

clean:
	docker compose -f ./srcs/docker-compose.yml down --rmi all --volumes --remove-orphans
	docker system prune -af

fclean: clean
	sudo rm -rf $(HOME)/data/wordpress/*
	sudo rm -rf $(HOME)/data/mariadb/*