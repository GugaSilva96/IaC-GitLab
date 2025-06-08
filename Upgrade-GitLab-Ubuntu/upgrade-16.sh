#!/bin/bash

source ./upgrade-common.sh

log "Iniciando upgrade das versões 16.x..."

backup_gitlab

VERSOES=(
  16.0.10 16.1.8 16.2.11 16.3.9
  16.4.7 16.5.10 16.6.10 16.7.10
  16.8.10 16.9.11 16.10.10 16.11.10
)

for V in "${VERSOES[@]}"; do
  instalar_gitlab "$V"
done
