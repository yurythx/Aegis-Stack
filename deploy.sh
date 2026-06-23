#!/usr/bin/env bash
# deploy.sh — Validação de credenciais e deploy da Aegis Stack
set -euo pipefail

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"

G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m' B='\033[1;34m' N='\033[0m'
ok()   { echo -e "${G}✓${N} $*"; }
err()  { echo -e "${R}✗${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
info() { echo -e "${B}→${N} $*"; }

# ── Utilidades .env ───────────────────────────────────────────────────────────

get_env() { grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true; }

set_env() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

is_placeholder() {
    local v="$1"
    [[ -z "$v" || "$v" == *"xxx"* || "$v" == *"SEU_"* || "$v" == *"exemplo"* || "$v" == "meu-cliente" ]]
}

setup_env() {
    if [ ! -f "$ENV_FILE" ]; then
        [ -f "$ENV_EXAMPLE" ] && cp "$ENV_EXAMPLE" "$ENV_FILE" || touch "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        warn ".env criado a partir do template."
    fi
}

# ── Validação: Cloudflare Tunnel Token ───────────────────────────────────────
# CF_TOKEN é um base64 de JSON simples (eyJ...) — não é um JWT de 3 partes.
# Não existe endpoint público para validá-lo sem iniciar o tunnel.

validate_cf_token() {
    local t="$1"
    is_placeholder "$t" && return 1
    # Cloudflare Tunnel token: base64 de JSON simples (eyJ...), sem pontos, ≥ 100 chars
    [[ "$t" == eyJ* && ${#t} -ge 100 ]]
}

check_cf_token() {
    local val; val=$(get_env "CF_TOKEN")
    echo -n "  CF_TOKEN        ... "
    if validate_cf_token "$val"; then
        ok "já configurado."
        return
    fi
    err "não configurado ou formato inválido."
    echo ""
    info "Zero Trust → Networks → Tunnels → (seleccionar túnel) → copiar token após '--token'"
    warn "Nota: validação de formato apenas — confirmação real ocorre no arranque do container."
    while true; do
        read -rp "  Cole o CF_TOKEN: " val
        if validate_cf_token "$val"; then
            set_env "CF_TOKEN" "$val"
            ok "Guardado no .env."
            break
        else
            err "Formato inválido. Deve começar com 'eyJ' e ter pelo menos 100 caracteres."
        fi
    done
}

# ── Validação: Tailscale Auth Key ─────────────────────────────────────────────
# Formato: tskey-auth-<alphanum>-<alphanum>
# Validação real só ocorre quando o container tenta registar-se na tailnet.

validate_ts_key() {
    local k="$1"
    is_placeholder "$k" && return 1
    [[ "$k" =~ ^tskey-auth-[A-Za-z0-9]+-[A-Za-z0-9]+$ && ${#k} -ge 40 ]]
}

check_ts_key() {
    local val; val=$(get_env "TS_AUTHKEY")
    echo -n "  TS_AUTHKEY      ... "
    if validate_ts_key "$val"; then
        ok "já configurado."
        return
    fi
    err "não configurada ou formato inválido."
    echo ""
    info "Tailscale Admin → Settings → Keys → Generate auth key"
    info "Marcar: Reusable ✓  |  Ephemeral (opcional)"
    warn "Nota: validação de formato apenas — a chave é verificada pela Tailscale no arranque."
    while true; do
        read -rp "  Cole o TS_AUTHKEY: " val
        if validate_ts_key "$val"; then
            set_env "TS_AUTHKEY" "$val"
            ok "Guardado no .env."
            break
        else
            err "Formato inválido. Deve começar com 'tskey-auth-' (ex: tskey-auth-kXxx-Yyyy)."
        fi
    done
}

# ── Validação: Domínio / Relay Host ──────────────────────────────────────────
# Verificação DNS real — resolve ou não resolve.

validate_domain() {
    local h="$1"
    is_placeholder "$h" && return 1
    [[ "$h" == "SEU_IP_OU_DOMINIO" ]] && return 1
    # Aceitar IP directo (regex básico)
    if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    # Verificar resolução DNS
    host "$h" &>/dev/null || nslookup "$h" &>/dev/null || \
        { dig +short "$h" 2>/dev/null | grep -qE '^[0-9]'; }
}

check_domain() {
    local val; val=$(get_env "RUSTDESK_RELAY_HOST")
    echo -n "  RELAY_HOST ($val) ... "
    if validate_domain "$val"; then
        ok "já configurado (resolve)."
        echo ""
        warn "Confirme que o registo DNS está sem proxy Cloudflare (ícone cinzento)"
        warn "para que as portas RustDesk (21115-21119) cheguem directamente ao VPS."
        return
    fi
    err "não resolve ou não configurado."
    echo ""
    info "Use o IP público do VPS ou um domínio/subdomínio com DNS directo (sem proxy CF)."
    while true; do
        read -rp "  Domínio ou IP do VPS: " val
        echo -n "  A verificar DNS... "
        if validate_domain "$val"; then
            ok "resolve."
            set_env "RUSTDESK_RELAY_HOST" "$val"
            ok "Guardado no .env."
            break
        else
            err "Não resolve. Verifique o registo DNS ou use o IP directo do VPS."
        fi
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${B}══════════════════════════════════════════${N}"
    echo -e "${B}  Aegis Stack — Deploy                    ${N}"
    echo -e "${B}══════════════════════════════════════════${N}"
    echo ""

    setup_env

    echo "── Verificando credenciais ──────────────────"
    check_cf_token
    check_ts_key
    check_domain
    echo ""
    ok "Todas as validações passaram."
    echo ""

    read -rp "Iniciar deploy agora? [S/n] " confirm
    [[ "${confirm:-S}" =~ ^[Nn]$ ]] && { echo "Cancelado."; exit 0; }

    echo ""
    echo "── A subir a stack ──────────────────────────"
    docker compose up -d

    echo ""
    echo "── Estado (aguardando 8s) ───────────────────"
    sleep 8
    docker compose ps

    echo ""
    ok "Deploy concluído."
    echo ""
    echo "  Próximos passos:"
    echo "  make firewall        — restringir portas ao CIDR Tailscale"
    echo "  make schedule-backup — backup automático diário"
    echo "  make rustdesk-keys   — chave pública para configurar clientes"
    echo ""
}

main "$@"
