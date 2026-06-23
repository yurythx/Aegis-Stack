.PHONY: help setup deploy up down restart logs status \
        tailscale-status rustdesk-keys \
        firewall backup schedule-backup update clean

# ── Alvo padrão ──────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  Aegis Stack — Comandos de Gestão"
	@echo ""
	@echo "  make deploy            Valida credenciais e faz o deploy (recomendado)"
	@echo "  make setup             Prepara ficheiro .env"
	@echo "  make up                Inicia todos os serviços em background"
	@echo "  make down              Para e remove os containers"
	@echo "  make restart           Reinicia todos os serviços"
	@echo "  make update            Actualiza imagens e reinicia"
	@echo "  make logs              Segue os logs em tempo real"
	@echo "  make status            Estado dos containers"
	@echo ""
	@echo "  make tailscale-status  Mostra o estado da tailnet"
	@echo "  make rustdesk-keys     Exibe a chave pública do RustDesk"
	@echo ""
	@echo "  make firewall          Restringe portas RustDesk ao CIDR Tailscale (UFW)"
	@echo "  make backup            Backup manual de data/"
	@echo "  make schedule-backup   Agenda backup diário às 02:00 via crontab"
	@echo ""
	@echo "  make clean             DESTRÓI containers e dados (irreversível)"
	@echo ""

# ── Deploy assistido ─────────────────────────────────────────────────────────
deploy:
	@bash deploy.sh

# ── Setup inicial ─────────────────────────────────────────────────────────────
setup:
	@[ -f .env ] && echo "✓ .env já existe." || (cp .env.example .env && chmod 600 .env && echo "✓ .env criado — preencha as variáveis.")
	@echo "✓ Pronto. Volumes geridos pelo Docker (criados automaticamente no primeiro 'make up')."

# ── Ciclo de vida ─────────────────────────────────────────────────────────────
up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

update:
	docker compose pull
	docker compose up -d

# ── Observabilidade ───────────────────────────────────────────────────────────
logs:
	docker compose logs -f --tail=100

logs-%:
	docker compose logs -f --tail=100 $*

status:
	@docker compose ps
	@docker inspect --format '{{.Name}}: {{.State.Health.Status}}' \
		tailscale cloudflared rustdesk_hbbs rustdesk_hbbr 2>/dev/null || true

# ── Utilitários ───────────────────────────────────────────────────────────────
tailscale-status:
	docker exec tailscale tailscale status

rustdesk-keys:
	@docker run --rm -v aegis-stack_rustdesk_data:/data:ro alpine cat /data/id_ed25519.pub 2>/dev/null || echo "Chaves ainda não geradas."

# ── Segurança e manutenção ───────────────────────────────────────────────────
firewall:
	@for port in 21115 21116 21117 21118 21119; do \
		sudo ufw allow from 100.64.0.0/10 to any port $$port comment "RustDesk via Tailscale"; \
		sudo ufw deny  from any           to any port $$port comment "RustDesk bloqueado"; \
	done
	@sudo ufw reload
	@sudo ufw status | grep 2111

backup:
	@mkdir -p backups
	@docker run --rm \
		-v aegis-stack_rustdesk_data:/data/rustdesk:ro \
		-v aegis-stack_tailscale_state:/data/tailscale:ro \
		-v $$(pwd)/backups:/backups \
		alpine tar -czf /backups/aegis-backup-$$(date +%Y%m%d_%H%M%S).tar.gz /data
	@echo "✓ Backup criado em backups/"
	@ls -lh backups/ | tail -5

schedule-backup:
	@(crontab -l 2>/dev/null; echo "0 2 * * * cd $$(pwd) && make backup >> backups/backup.log 2>&1") | crontab -
	@echo "✓ Backup agendado para as 02:00 diariamente."
	@crontab -l | grep backup

# ── Limpeza destrutiva ────────────────────────────────────────────────────────
clean:
	@read -p "Apagar containers e dados? [s/N] " c && [ "$$c" = "s" ] || exit 1
	docker compose down -v
	@echo "✓ Stack e volumes removidos."
