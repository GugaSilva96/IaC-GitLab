#!/bin/bash

# Carrega funções utilitárias
source ./script-functions.sh || {
  echo "Erro: Não foi possível carregar script-functions.sh"
  exit 1
}

log "Iniciando upgrade de versões..."

# Lista de versões em ordem de upgrade
VERSOES=(
  15.0.5 15.1.6 15.2.5 15.3.5 15.4.6 15.5.9 15.6.8 15.7.9
  15.8.6 15.9.8 15.10.8 15.11.13
  16.0.10 16.1.8 16.2.11 16.3.9 16.4.7 16.5.10 16.6.10 16.7.10
  16.8.10 16.9.11 16.10.10 16.11.10
  17.0.8 17.1.8 17.2.9 17.3.7 17.4.6 17.5.5 17.6.5 17.7.7
  17.8.7 17.9.8 17.10.7 17.11.3
  18.0.1
)

# Loop pelas versões
for V in "${VERSOES[@]}"; do
  log "======================"
  log "Processando versão $V"
  log "======================"

  check_pod_structure    # Confirma que o pod existe e está acessível
  check_pod_resources    # Verifica limites antes de backup
  backup_gitlab_with_recovery "$V"
  atualizar_versao_gitlab "$V"
done

success "Upgrade completo de todas as versões!"
