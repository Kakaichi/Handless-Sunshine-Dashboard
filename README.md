# Handless Sunshine Dashboard

> **Aviso:** este projeto nasceu como um app *vibecoded* — feito de forma experimental, com IA e muita improvisação — para um grupo de amigos no Brasil. O pessoal curtiu tanto que pediu para compartilhar publicamente. Não espere código enterprise: espere algo que **funciona na prática** para quem quer Sunshine + Tailscale + Moonlight Web num PC Windows, com uma interface gráfica simples.

Painel desktop (PySide6) para gerenciar **Sunshine**, **Tailscale** e **Moonlight Web** no Windows: ligar/desligar serviços, sincronizar jogos Steam, configurar Moonlight (usuários, Funnel, acesso remoto) e usar a API local do Sunshine sem abrir o navegador o tempo todo.

Repositório: [github.com/Kakaichi/Handless-Sunshine-Dashboard](https://github.com/Kakaichi/Handless-Sunshine-Dashboard)

**Releases:** [GitHub Releases](https://github.com/Kakaichi/Handless-Sunshine-Dashboard/releases) — zip com o `.exe` já buildado (recomendado para quem só quer usar).

---

## Versão

A versão segue [semver](https://semver.org/) no arquivo `headless-steam-app/VERSION` (ex.: `1.0.0`).

| Onde ver | Exemplo |
|----------|---------|
| Título da janela | `Handless Sunshine Dashboard v1.0.0` |
| Subtítulo no app | `v1.0.0 · Sunshine · Tailscale · Moonlight` |
| Pasta do `.exe` | arquivo `VERSION` ao lado de `HeadlessSteam.exe` |


## O que vem incluso

| Pasta | Descrição |
|-------|-----------|
| `headless-steam-app/` | Interface gráfica **Handless Sunshine Dashboard** (Python + PySide6) |
| `sunshine/` | Scripts PowerShell — fonte de verdade das ações (serviços, jogos, Moonlight) |
| `moonlight-web/` | Pacote local do [Moonlight Web](https://github.com/moonlight-stream/moonlight-web) (`web-server.exe` + `streamer.exe`) |

---

## Requisitos

- **Windows 10/11** (64-bit)
- Executar como **administrador** (UAC) — igual ao menu `.bat` original
- Dependências instaladas via `sunshine/instalar-dependencias.ps1`:
  - [Sunshine](https://github.com/LizardByte/Sunshine)
  - [Tailscale](https://tailscale.com/)
  - [ViGEmBus](https://github.com/ViGEm/ViGEmBus) (gamepad virtual)
- Python 3.11+ (só para desenvolvimento ou build do `.exe`)

---

## Início rápido

### 1. Instalar dependências externas

```powershell
cd sunshine
.\instalar-dependencias.ps1 -InstallMissing
```

### 2. Moonlight Web (primeira vez)

Copie o banco vazio de usuários se ainda não existir:

```powershell
Copy-Item moonlight-web\package\server\data.json.example moonlight-web\package\server\data.json -Force
```

Na primeira execução do Moonlight Web, crie um usuário pela interface ou pelo app.

### 3. Rodar a interface (desenvolvimento)

```powershell
cd headless-steam-app
pip install -r requirements.txt
python main.py
```

O app encontra `sunshine/` automaticamente a partir da raiz do repositório. Para outro layout, defina `HEADLESS_STEAM_HOME`.

### 4. Build do executável

```powershell
cd headless-steam-app
.\build.ps1
```

Saída: `headless-steam-app/dist/HeadlessSteam/HeadlessSteam.exe` (nome interno legado; o app aparece como **Handless Sunshine Dashboard** com versão no título).

O build copia `sunshine/`, `moonlight-web/` e o arquivo `VERSION` para a pasta `dist`.

---

## Menu alternativo (CLI)

Sem a interface gráfica, use o menu interativo original:

```powershell
cd sunshine
.\gerenciar-servicos.bat
```

---

## Funcionalidades principais

- **Dashboard** — power global, sync de jogos Steam, status dos serviços
- **Sunshine** — credenciais, PIN, clientes, configuração via API local (`https://localhost:47990`)
- **Tailscale** — ligar/desligar
- **Moonlight Web** — ligar/desligar, usuários, Tailscale Funnel (acesso público via URL `*.ts.net`), URLs de acesso

### Sincronizar jogos Steam

```powershell
cd sunshine
.\atualizar-jogos.bat
```

Gera entradas em `sunshine/apps.json` e capas em `sunshine/covers/` com base na sua biblioteca Steam (não versionadas no Git).

### Tailscale Funnel (internet pública)

O Funnel **não** usa as regras de **General access rules** (`src/dst/ip` = `*`). Tudo fica na **policy ACL**:

[login.tailscale.com/admin/acls/file](https://login.tailscale.com/admin/acls/file)

Adicione permissão `funnel` via **Add Funnel to policy** (ou manualmente):

```json
"nodeAttrs": [
  {
    "target": ["autogroup:member"],
    "attr": ["funnel"]
  }
]
```

Se o PC usa **tags** Tailscale, inclua a tag em `target` (ex.: `"tag:server"`). Dispositivos tagueados não herdam `autogroup:member`.

**MagicDNS + HTTPS** devem estar ativos no tailnet (o CLI do Funnel costuma pedir isso na primeira vez).

No app: crie pelo menos um usuário Moonlight Web → ative **Expor via Tailscale Funnel** → **Salvar e aplicar**.

Use a URL **Internet (Funnel)** (`https://seu-host.tailXXXX.ts.net`). O link **Via Tailscale** so funciona com o app Tailscale instalado.

Documentação: [Tailscale Funnel KB](https://tailscale.com/kb/1223/funnel)

---

## Dados locais (não commitar)

| Caminho | Conteúdo |
|---------|----------|
| `%APPDATA%\HeadlessSteam\` | Credenciais Sunshine, settings Moonlight |
| `moonlight-web/package/server/data.json` | Usuários Moonlight (senhas, chaves de pareamento) |
| `sunshine/apps.json` | Jogos sincronizados (caminhos do seu PC) |
| `sunshine/covers/*.png` | Capas geradas |

Use os arquivos `*.example` como referência.

---

## Estrutura de scripts

- `sunshine/HeadlessSteam-Status.ps1` — status em JSON para a UI
- `sunshine/Invoke-HeadlessSteamAction.ps1` — ações sem menu
- `sunshine/sync-steam-games.ps1` — sync biblioteca Steam → Sunshine
- `sunshine/Install-HeadlessSteamShortcut.ps1` — atalho na área de trabalho

---

## Disclaimer

Projeto hobby, sem garantias. Streaming na internet (Funnel) expõe o Moonlight Web — use senhas fortes e entenda os riscos. Testado principalmente em ambiente doméstico brasileiro; caminhos Steam, bibliotecas e rede podem variar no seu PC.

Contribuições e issues são bem-vindas — especialmente para tornar o setup menos *vibecoded* e mais amigável para quem clona o repo do zero.

---

## English (short)

**Handless Sunshine Dashboard** is a Windows desktop UI (PySide6) to manage Sunshine, Tailscale, and Moonlight Web. It started as a casual, AI-assisted project for a Brazilian friends group and was shared publicly on request. Run as Administrator, install dependencies via `sunshine/instalar-dependencias.ps1`, then `headless-steam-app/build.ps1` or `python main.py`.
