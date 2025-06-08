#!/bin/bash

source ./upgrade-common.sh

log "Iniciando upgrade para a versão 18.0..."

backup_gitlab

VERSOES=(
  18.0.0 18.0.1  # Atualize com o número real da versão assim que for publicada
)

for V in "${VERSOES[@]}"; do
  instalar_gitlab "$V"
done

log "Tudo certo por aqui! Aproveite o GitLab Duo integrado à IDE! 🦊✨"
