#!/bin/bash

source ./upgrade-common.sh

log "Iniciando upgrade das versões 15.x..."

backup_gitlab

VERSOES=(
  15.0.5
  15.1.6 15.2.5 15.3.5 15.4.6
  15.5.9 15.6.8 15.7.9 15.8.6
  15.9.8 15.10.8 15.11.13
)

for V in "${VERSOES[@]}"; do
  instalar_gitlab "$V"
done
