# Aegis Stack

Infraestrutura de conectividade e suporte remoto. Sempre o **primeiro stack a subir** no VPS — cria a rede `aegis_net` da qual os outros stacks dependem.

## Arquitectura

```
Internet
   │
   ├── Cloudflare Edge ──► cloudflared ──► aegis_net ──► microserviços (Keycloak, etc.)
   │
   └── Tailscale Coordination ──► tailscale (host network)
                                      └── SSH + routing LAN + acesso RustDesk

Clientes RustDesk
   ├── P2P   ──► papermoon.cloud :21116 UDP  (DNS directo, sem proxy CF)
   └── Relay ──► papermoon.cloud :21117 TCP
```

## Serviços

| Container | Imagem | Versão | Função |
|---|---|---|---|
| `tailscale` | `tailscale/tailscale` | `v1.98.4` | VPN mesh WireGuard; SSH; routing de sub-rede |
| `cloudflared` | `cloudflare/cloudflared` | `2026.6.1` | Túnel HTTPS zero-port para serviços internos |
| `rustdesk_hbbs` | `rustdesk/rustdesk-server` | `1.1.15` | Servidor de ID, rendezvous e NAT traversal |
| `rustdesk_hbbr` | `rustdesk/rustdesk-server` | `1.1.15` | Relay de dados para conexões sem P2P directo |

## Portas

| Porta | Proto | Serviço | Função |
|---|---|---|---|
| 21115 | TCP | hbbs | Teste de tipo NAT |
| 21116 | TCP+UDP | hbbs | Servidor de ID + hole punching P2P |
| 21118 | TCP | hbbs | WebSocket |
| 21117 | TCP | hbbr | Relay de dados |
| 21119 | TCP | hbbr | WebSocket relay |

> Tailscale e Cloudflared não expõem portas — criam conexões de saída.
> As portas RustDesk precisam de DNS directo (sem proxy Cloudflare) e são restritas ao CIDR Tailscale via `make firewall`.

## Pré-requisitos

- Docker Engine ≥ 24 com Compose v2
- Linux com `/dev/net/tun` disponível (`sudo modprobe tun` se necessário)
- Conta [Tailscale](https://login.tailscale.com) e [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
- Registo DNS A para `papermoon.cloud` apontando ao VPS com **proxy desactivado** (ícone cinzento)

---

## Deploy

### 1. Clonar

```bash
git clone <repo-url> aegis-stack
cd aegis-stack
```

### 2. Criar o `.env`

```bash
cp .env.example .env
```

O `.env.example` já tem os valores não-sensíveis pré-preenchidos (`CLIENT_NAME`, `TAILSCALE_ROUTES`, `RUSTDESK_RELAY_HOST`, versões). Só os tokens ficam em branco — o passo seguinte trata disso.

### 3. Executar o script de deploy

```bash
bash deploy.sh
# ou: make deploy
```

O script lê o `.env`, valida cada credencial e solicita interactivamente as que estiverem em falta ou inválidas. Se tudo já estiver configurado, avança directamente para o deploy:

```
── Verificando credenciais ──────────────────
  CF_TOKEN        ... ✓ já configurado.
  TS_AUTHKEY      ... ✓ já configurado.
  RELAY_HOST (papermoon.cloud) ... ✓ já configurado (resolve).

✓ Todas as validações passaram.
Iniciar deploy agora? [S/n]
```

Se um token estiver em branco, o script pede e guarda no `.env`:

```
  CF_TOKEN        ... ✗ não configurado ou formato inválido.
  → Zero Trust → Networks → Tunnels → copiar token após '--token'
  Cole o CF_TOKEN: █
```

> **O que é validado:**
> - `CF_TOKEN` — começa com `eyJ` e tem ≥ 100 caracteres (formato Cloudflare Tunnel token)
> - `TS_AUTHKEY` — formato `tskey-auth-xxx-xxx` com ≥ 40 caracteres
> - `RUSTDESK_RELAY_HOST` — resolução DNS real
>
> Tokens são confirmados definitivamente no arranque dos containers (não existe API pública para pré-validar tunnel tokens).

### 3. Pós-deploy (uma vez por VPS)

**Hardening de firewall:**
```bash
make firewall
```
Restringe as portas RustDesk ao CIDR Tailscale (`100.64.0.0/10`) via UFW.

**Activar rotas no painel Tailscale:**
Em [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines) → nó `meu-servidor-01-node` → `···` → **Edit route settings** → activar `192.168.1.0/24`.

**Chave pública para clientes RustDesk:**
```bash
make rustdesk-keys
```
Configurar nos clientes RustDesk → **Settings → Network**:
- **ID Server:** `papermoon.cloud:21116`
- **Relay Server:** `papermoon.cloud:21117`
- **Key:** (saída do comando acima)

**Backup automático:**
```bash
make schedule-backup   # agenda às 02:00 diariamente via crontab
```

---

## Onde obter as credenciais

| Variável | Como obter |
|---|---|
| `TS_AUTHKEY` | [Tailscale Admin](https://login.tailscale.com/admin/settings/keys) → Generate auth key → marcar **Reusable** |
| `CF_TOKEN` | [Zero Trust](https://one.dash.cloudflare.com) → Networks → Tunnels → Create tunnel → copiar token após `--token` |

As restantes variáveis (`CLIENT_NAME`, `TAILSCALE_ROUTES`, `RUSTDESK_RELAY_HOST`, versões) já estão pré-configuradas no `.env.example`.

---

## Integração com Outros Stacks

Esta stack cria a rede `aegis_net`. Para o Cloudflare Tunnel encaminhar tráfego para outro container (Keycloak, APIs, etc.), esse stack deve aderir à rede como externa:

```yaml
# docker-compose.yml do stack de aplicação
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26
    networks:
      - aegis_net

networks:
  aegis_net:
    external: true    # criada pela Aegis Stack
```

O `cloudflared` alcança o Keycloak por nome de container (`http://keycloak:8080`) sem expor portas.

**Ordem obrigatória:** Aegis Stack primeiro, restantes stacks depois.

---

## Referência de Comandos

```bash
make deploy            # valida credenciais e faz o deploy (recomendado)
make up                # inicia stack (sem validação)
make down              # para stack
make restart           # reinicia stack
make update            # actualiza imagens e reinicia
make status            # estado e healthchecks
make logs              # logs de todos os serviços
make logs-<serviço>    # ex: make logs-tailscale
make tailscale-status  # estado da tailnet
make rustdesk-keys     # chave pública RustDesk
make firewall          # restringe portas ao CIDR Tailscale (UFW)
make backup            # backup manual dos volumes
make schedule-backup   # agenda backup diário às 02:00
make clean             # destrói containers e volumes (irreversível)
```

## Actualização de Imagens

Editar a versão no `.env` e correr:

```bash
make update
```

| Variável | Versão actual |
|---|---|
| `TAILSCALE_VERSION` | `v1.98.4` |
| `CLOUDFLARED_VERSION` | `2026.6.1` |
| `RUSTDESK_VERSION` | `1.1.15` |

## Segurança

- `.env` com permissões `600`, excluído do git
- `.env.example` contém apenas tokens em branco — seguro para versionar
- Imagens com versões pinnadas
- Cloudflared com `--no-autoupdate` e `no-new-privileges:true`
- Tailscale em modo kernel (`TS_USERSPACE=false`)
- Portas RustDesk restritas ao CIDR Tailscale via UFW (`make firewall`)
- Volumes geridos pelo Docker — dados não expostos no filesystem do host

## Estrutura

```
aegis-stack/
├── deploy.sh            # deploy assistido com validação de credenciais
├── docker-compose.yml   # orquestração
├── .env.example         # template com defaults não-sensíveis (versionado)
├── .env                 # credenciais reais (NUNCA versionar)
├── .gitignore
├── Makefile             # todos os comandos de gestão
└── backups/             # backups locais (gerado por make backup)
```

## Resolução de Problemas

**`/dev/net/tun` não encontrado**
```bash
sudo modprobe tun
```

**RustDesk — clientes não conectam**
```bash
ss -tlnup | grep -E '2111[5-9]|21117'   # portas a escutar?
make rustdesk-keys                         # chave correcta?
make logs-hbbs                             # erros no servidor?
```
Verificar também: DNS de `papermoon.cloud` com proxy CF **desactivado**.

**Cloudflared — túnel não estabelece**
```bash
make logs-cloudflared
```
Se aparecer `token is not valid` → gerar novo token no painel Zero Trust e correr `bash deploy.sh`.

**Outro stack não liga à `aegis_net`**
```bash
docker network ls | grep aegis
docker network inspect aegis_net
```
Confirmar que a Aegis Stack está em execução antes de subir os outros stacks.
