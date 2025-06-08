#!/bin/bash

set -e

mkdir -p ./debs

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

erro() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Erro: $1"
  exit 1
}

backup_gitlab() {
  log "Iniciando backup do GitLab..."
  gitlab-backup create CRON=1 || erro "Falha ao criar backup"
  log "Backup criado com sucesso."
}

instalar_gitlab() {
  VERSAO=$1
  URL="https://packages.gitlab.com/gitlab/gitlab-ce/packages/ubuntu/focal/gitlab-ce_${VERSAO}-ce.0_amd64.deb/download.deb"
  ARQUIVO="./debs/gitlab-ce_${VERSAO}-ce.0_amd64.deb"

  if [[ ! -f "$ARQUIVO" ]]; then
    log "Baixando pacote para a versão $VERSAO..."
    wget -q --show-progress -O "$ARQUIVO" "$URL" || erro "Não foi possível baixar a versão $VERSAO"
  fi

  log "Instalando GitLab versão $VERSAO..."
  dpkg -i "$ARQUIVO" || erro "Falha na instalação da versão $VERSAO"

  log "Reconfigurando GitLab..."
  gitlab-ctl reconfigure || erro "Erro ao reconfigurar GitLab"

  log "Upgrade para $VERSAO concluído com sucesso."
}

