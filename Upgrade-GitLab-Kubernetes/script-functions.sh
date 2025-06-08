#!/bin/bash

# Constantes
NAMESPACE="${1:-gitlab}"
APP_LABEL="app=gitlab"
DEPLOYMENT_NAME="gitlab"
BACKUP_DIR="/var/opt/gitlab/backups/"
TIMEOUT_SECONDS=300

# Funções de log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] \033[0;32m$1\033[0m"; }
error() { echo -e "\033[0;31m[$(date '+%Y-%m-%d %H:%M:%S')] Error: $1\033[0m"; exit 1; }

# Funções de utilidade
get_container_name() {
  kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].name}'
}

get_gitlab_pod() {
  kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" -o jsonpath="{.items[0].metadata.name}" || 
    error "Falha ao obter o pod do GitLab"

sleep 10
}

wait_for_pod_ready() {
  local pod=$1
  local timeout=180
  local counter=0

  log "Aguardando pod $pod estar pronto..."
  while [ $counter -lt $timeout ]; do
    if kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q "true"; then
      log "Pod $pod está pronto"
      return 0
    fi
    counter=$((counter + 5))
    sleep 5
  done

  log "Timeout aguardando pod $pod ficar pronto"
  return 1
}

ensure_version_dir() {
  local dir="version_pre_${1}"
  mkdir -p "$dir" || error "Falha ao criar diretório $dir"
  echo "$dir"
}

restart_gitlab_pod() {
  local pod=$(get_gitlab_pod)
  log "Reiniciando o pod do GitLab..."
  kubectl delete pod "$pod" -n "$NAMESPACE" --grace-period=30 || error "Falha ao reiniciar o pod"
  sleep 30
  local new_pod=$(get_gitlab_pod)
  wait_for_pod_ready "$new_pod" || log "Aviso: Novo pod pode não estar totalmente pronto"
  log "Pod reiniciado: $new_pod"
  return 0
}

fix_postgresql_issues() {
  local pod=$1
  local container=$2

  log "Corrigindo problemas do PostgreSQL..."

  log "Parando todos os serviços GitLab..."
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl stop || log "Falha ao parar serviços"
  sleep 10

  log "Removendo arquivos de lock..."
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- rm -f /var/opt/gitlab/postgresql/.s.PGSQL.5432.lock || log "Falha ao remover lock"
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- rm -f /var/opt/gitlab/postgresql/postmaster.pid || log "Falha ao remover PID"

  log "Iniciando PostgreSQL..."
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl start postgresql || return 1
  sleep 20

  log "Iniciando outros serviços..."
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl start || log "Falha ao iniciar serviços"
  sleep 10

  if ! kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl status postgresql | grep -q "run"; then
    return 1
  fi

  log "PostgreSQL recuperado com sucesso"
  return 0
}

check_gitlab_services() {
  local pod=$1
  local container=$(get_container_name "$pod")

  log "Verificando serviços do GitLab..."
  kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl status || log "Alguns serviços podem não estar rodando"

  if ! kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl status postgresql | grep -q "run"; then
    log "PostgreSQL não está rodando. Tentando recuperar..."
    kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl stop sidekiq || log "Falha ao parar sidekiq"
    kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl stop puma || log "Falha ao parar puma"
    kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-ctl stop gitaly || log "Falha ao parar gitaly"
    sleep 15

    if ! fix_postgresql_issues "$pod" "$container"; then
      log "Falha ao recuperar PostgreSQL. Reiniciando pod..."
      restart_gitlab_pod
      return 0
    fi
  fi

  log "Serviços verificados com sucesso"
}

backup_gitlab() {
  local version=$1
  local version_dir=$(ensure_version_dir "$version")
  local pod=$(get_gitlab_pod)
  local container=$(get_container_name "$pod")

  log "Iniciando backup para versão $version (pod: $pod, container: $container)..."

  check_gitlab_services "$pod"

  log "Executando backup..."
  if ! kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-backup create CRON=1; then
    log "Falha no backup. Tentando corrigir PostgreSQL..."

    if ! fix_postgresql_issues "$pod" "$container"; then
      log "Falha ao corrigir PostgreSQL. Continuando sem backup..."
      return 0
    fi

    if ! kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- gitlab-backup create CRON=1; then
      log "Backup falhou novamente. Continuando sem backup..."
      return 0
    fi
  fi

  log "Copiando arquivos de backup..."
  kubectl cp "$NAMESPACE/$pod:$BACKUP_DIR" "$version_dir/" -c "$container" || log "Falha ao copiar backup"

  success "Backup para versão ${version} concluído."
  return 0
}

force_delete_old_replicasets() {
  log "Verificando ReplicaSets antigos para remoção forçada..."

  local current_rs_hash
  current_rs_hash=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.labels.pod-template-hash}')

  local old_rs
  old_rs=$(kubectl get rs -n "$NAMESPACE" -l app="$DEPLOYMENT_NAME" -o json | \
    jq -r --arg current "$current_rs_hash" '.items[] | select(.metadata.labels."pod-template-hash" != $current) | .metadata.name')

  for rs in $old_rs; do
    log "Forçando deleção do ReplicaSet antigo: $rs"
    kubectl delete rs "$rs" -n "$NAMESPACE" --grace-period=0 --force || \
      log "Erro ao forçar deleção do ReplicaSet $rs"
  done
  sleep 10
}

atualizar_versao_gitlab() {
  local version=$1
  local new_image="gitlab/gitlab-ce:${version}-ce.0"
  local version_dir=$(ensure_version_dir "$version")

  log "Atualizando para versão $version..."

  # Backup do deployment atual
  kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o yaml > "$version_dir/deployment.yaml" || 
    log "Falha ao salvar deployment"

  # Aplicar nova imagem
  log "Aplicando nova imagem $new_image..."
  kubectl patch deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${new_image}\"}]" || 
    error "Falha ao aplicar nova versão"

  force_delete_old_replicasets

  sleep 5

  # Aguardar rollout
  log "Aguardando rollout..."
  if ! kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"; then
    log "Rollout falhou! Executando rollback..."
    kubectl rollout undo deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" || error "Rollback falhou"
    error "Rollback executado após falha no rollout"
  fi

  # Limpar ReplicaSets antigos
  cleanup_old_replicasets

  # Verificar e aguardar novo pod
  local new_pod=$(get_gitlab_pod)
  wait_for_pod_ready "$new_pod" || log "Aviso: Pod pode não estar totalmente pronto"
  sleep 60

  # Verificar serviços
  check_gitlab_services "$new_pod"

  success "Upgrade para $version concluído com sucesso."
  return 0
}

cleanup_old_replicasets() {
  log "Verificando e removendo ReplicaSets antigos..."

  # Obter o hash atual do deployment
  local current_rs_hash
  current_rs_hash=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.labels.pod-template-hash}')
  log "Hash atual do deployment: $current_rs_hash"

  # Listar e filtrar ReplicaSets antigos
  local old_rs
  old_rs=$(kubectl get rs -n "$NAMESPACE" -l app="$DEPLOYMENT_NAME" -o json | \
    jq -r --arg current "$current_rs_hash" '.items[] | select(.metadata.labels."pod-template-hash" != $current) | .metadata.name')

  if [ -z "$old_rs" ]; then
    log "Nenhum ReplicaSet antigo encontrado para remoção."
  else
    for rs in $old_rs; do
      log "Deletando ReplicaSet antigo: $rs"
      kubectl delete rs "$rs" -n "$NAMESPACE" --grace-period=0 --force || \
        log "Falha ao deletar ReplicaSet $rs"
    done
  fi
}


check_pod_resources() {
  local pod=$(get_gitlab_pod)
  log "Verificando recursos do pod $pod..."
  kubectl describe pod "$pod" -n "$NAMESPACE" | grep -E "Limits|Requests"

  local node=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
  log "Verificando recursos do nó $node..."
  kubectl describe node "$node" | grep -A 5 "Allocated resources"
}

increase_pod_resources() {
  log "Aumentando recursos do pod GitLab..."
  kubectl patch deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"6Gi"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"4Gi"}
  ]' || log "Não foi possível aumentar recursos"

  kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=180s || log "Timeout no rollout"
}

backup_gitlab_with_recovery() {
  local version=$1
  if backup_gitlab "$version"; then
    return 0
  else
    log "Falha no backup. Continuando sem backup..."
    return 0
  fi
}

check_pod_structure() {
  local pod=$(get_gitlab_pod)
  log "Verificando estrutura do pod $pod..."
  kubectl get pod "$pod" -n "$NAMESPACE" -o yaml > pod_structure.yaml
  log "Containers no pod: $(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}')"
  log "Imagem: $(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].image}')"
}

