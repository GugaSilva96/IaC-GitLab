#!/bin/bash

source ./upgrade-common.sh

log "Iniciando upgrade das versões 17.x..."

backup_gitlab

VERSOES=(
  17.0.8 17.1.8 17.2.9 17.3.7
  17.4.6 17.5.5 17.6.5 17.7.7
  17.8.7 17.9.8 17.10.7 17.11.3
)

for V in "${VERSOES[@]}"; do
  instalar_gitlab "$V"
done

