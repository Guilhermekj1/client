
#!/usr/bin/env bash
set -Eeuo pipefail

# github.sh — Sincroniza a pasta atual com um repositório GitHub.
# O nome da pasta atual será o nome do repositório.

PROJECT_DIR="$(pwd -P)"
REPO_NAME="$(basename "$PROJECT_DIR")"
BRANCH="${GITHUB_BRANCH:-main}"

# Evita publicar o próprio script de sincronização.
# Remova esta linha se quiser versionar github.sh também.
# Para incluí-lo, apague github.sh da lista de exclusão abaixo.

die() {
    printf '\n[ERRO] %s\n' "$*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || die "Instale o Git primeiro."
command -v gh  >/dev/null 2>&1 || die "Instale o GitHub CLI (gh) primeiro."

gh auth status >/dev/null 2>&1 ||
    die "Faça login no GitHub com: gh auth login"

# Obtém o usuário autenticado.
GH_USER="$(gh api user --jq .login)" ||
    die "Não foi possível identificar sua conta GitHub."

REPO="$GH_USER/$REPO_NAME"

printf '\nProjeto:    %s\n' "$PROJECT_DIR"
printf 'Repositório: %s\n' "$REPO"
printf 'Branch:      %s\n\n' "$BRANCH"

# Não permite que a sincronização apague arquivos fora do projeto.
cd "$PROJECT_DIR"

# Cria o repositório remoto se ainda não existir.
if gh repo view "$REPO" >/dev/null 2>&1; then
    printf '[OK] Repositório existente: %s\n' "$REPO"
else
    printf '[INFO] Criando repositório privado...\n'
    gh repo create "$REPO" --private ||
        die "Não foi possível criar o repositório."
fi

# Inicializa o Git se necessário.
if [[ ! -d .git ]]; then
    git init -b "$BRANCH"
fi

# Garante que a branch local tenha o nome esperado.
git branch -M "$BRANCH"

# Configura o remoto sem duplicá-lo.
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "https://github.com/$REPO.git"
else
    git remote add origin "https://github.com/$REPO.git"
fi

# Busca o estado remoto.
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git fetch origin "$BRANCH:refs/remotes/origin/$BRANCH"

    # Valida o histórico antes de criar commits ou preparar alterações locais.
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        die "A branch remota já contém commits, mas a branch local ainda não tem histórico. Integre os históricos manualmente antes de sincronizar."
    fi

    if ! git merge-base HEAD "origin/$BRANCH" >/dev/null 2>&1; then
        die "Os históricos local e remoto são independentes. Nenhum arquivo foi preparado ou commitado. Confira se o repositório remoto é o correto e integre os históricos manualmente."
    fi

    if ! git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
        die "O GitHub contém commits ausentes localmente. Nenhum arquivo foi preparado ou commitado. Integre os commits remotos primeiro para evitar perda de histórico."
    fi
fi

# Atualiza as regras de exclusão antes de adicionar arquivos.
git add -A

# Verifica se há conteúdo local para enviar.
if git diff --cached --quiet && ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    die "Não há arquivos para enviar. Confira o .gitignore."
fi

# Faz um commit apenas se houver mudanças.
if ! git diff --cached --quiet; then
    git commit -m "Sincronização: $(date '+%Y-%m-%d %H:%M:%S')" ||
        die "O commit falhou. Confira seu nome e e-mail do Git."
fi

printf '\n[INFO] Confira as alterações que serão enviadas.\n'
git status --short

read -r -p "Enviar para github.com/$REPO (s/n)? " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || {
    printf '[INFO] Envio cancelado. O commit local pode ter sido criado.\n'
    exit 0
}

# Envia o conteúdo local. --force não é usado.
git push -u origin "$BRANCH"

printf '\n[SUCESSO] Projeto enviado para:\n'
printf 'https://github.com/%s\n' "$REPO"
