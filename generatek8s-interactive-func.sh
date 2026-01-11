#!/usr/bin/env bash
set -euo pipefail

# ========================
# Utility Functions
# ========================

trim() {
  awk '{$1=$1};1'
}

log() {
  echo "$@" >&2
}

log_success() {
  log "✅ $*"
}

log_info() {
  log "ℹ️ $*"
}

log_warning() {
  log "⚠️ $*"
}

# ========================
# Configuration Functions
# ========================

get_project_config() {
  local root_dir="${1:-.}"

  ROOT_DIR="$(realpath "$root_dir")"
  PARENT_NAME="$(basename "$ROOT_DIR")"
  K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"
  TAG="$(printf "%05d" $((RANDOM % 1000000)))"

  mkdir -p "$K8S_OUT_DIR"

  log "📦 Project: $PARENT_NAME"
  log
}

prompt_pvc_size() {
  read -p "📦 Enter PostgreSQL PVC storage size (default: 10Gi): " PVC_SIZE
  PVC_SIZE="${PVC_SIZE:-10Gi}"

  if [[ ! "$PVC_SIZE" =~ ^[0-9]+(Gi|Mi|G|M)$ ]]; then
    log_warning "PVC size format should be like '10Gi', '5Gi', '100Mi'"
    log_info "Using default: 10Gi"
    PVC_SIZE="10Gi"
  fi

  echo "$PVC_SIZE"
}

prompt_namespace() {
  local default_ns="$1"

  read -p "🏷️  Enter Kubernetes namespace (default: ${default_ns}): " USER_NAMESPACE

  local raw_ns
  if [[ -n "$USER_NAMESPACE" ]]; then
    raw_ns="$USER_NAMESPACE"
  else
    raw_ns="$default_ns"
  fi

  # DNS-1123 compliant: lowercase, alphanumeric, hyphens only, no leading/trailing hyphen
  NAMESPACE="$(echo "$raw_ns" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed 's/^-//;s/-$//')"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="app-namespace"

  log_success "Using namespace: $NAMESPACE"
  echo "$NAMESPACE"
}

# ========================
# Manifest Generation
# ========================

generate_namespace_manifest() {
  local namespace="$1"
  local output_file="$2"

  cat > "$output_file" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
EOF

  log_success "Created namespace manifest: $namespace"
}

find_env_files() {
  local root_dir="$1"
  mapfile -t ENV_FILES < <(find "$root_dir" -type f -iname ".env*" ! -iname "*.example")
  echo "${ENV_FILES[@]}"
}

parse_env_files() {
  local env_files=("$@")

  declare -gA CONFIG_VARS
  declare -gA SECRET_VARS

  for ENV_FILE in "${env_files[@]}"; do
    log "  Processing: $ENV_FILE"
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
      KEY="$(echo "$KEY" | trim)"
      [[ -z "$KEY" || "$KEY" =~ ^# ]] && continue

      VALUE="${VALUE:-}"
      VALUE="$(echo "$VALUE" | trim)"
      VALUE="${VALUE#\"}"; VALUE="${VALUE%\"}"
      VALUE="${VALUE#\'}"; VALUE="${VALUE%\'}"

      if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
        SECRET_VARS["$KEY"]="$VALUE"
      else
        CONFIG_VARS["$KEY"]="$VALUE"
      fi
    done < "$ENV_FILE"
  done
}

generate_config_and_secret_manifests() {
  local parent_name="$1"
  local namespace="$2"
  local cm_file="$3"
  local sec_file="$4"

  cat > "$cm_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${parent_name}-config
  namespace: $namespace
data:
EOF

  for KEY in "${!CONFIG_VARS[@]}"; do
    echo "  $KEY: \"${CONFIG_VARS[$KEY]}\"" >> "$cm_file"
  done

  cat > "$sec_file" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${parent_name}-secret
  namespace: $namespace
type: Opaque
stringData:
EOF

  for KEY in "${!SECRET_VARS[@]}"; do
    echo "  $KEY: \"${SECRET_VARS[$KEY]}\"" >> "$sec_file"
  done

  log_success "Created ConfigMap and Secret manifests"
}

find_sql_init_files() {
  local root_dir="$1"
  mapfile -t SQL_FILES < <(find "$root_dir" -maxdepth 2 -type f \( -iname "init.sql" -o -iname "*.sql" \))
  echo "${SQL_FILES[@]}"
}

generate_postgres_manifests() {
  local parent_name="$1"
  local namespace="$2"
  local pvc_size="$3"
  local sql_files=("$4")

  if [[ ${#sql_files[@]} -eq 0 ]]; then
    log_warning "No SQL init files found. Skipping Postgres generation."
    return 0
  fi

  local sql_file="${sql_files[0]}"
  log_success "Found SQL init file: $sql_file"

  # ConfigMap for init script
  cat > "$K8S_OUT_DIR/postgres-init-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${parent_name}-postgres-init
  namespace: $namespace
data:
  init.sql: |
$(sed 's/^/    /' "$sql_file")
EOF

  # PVC
  cat > "$K8S_OUT_DIR/postgres-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${parent_name}-postgres-pvc
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $pvc_size
EOF

  # Deployment
  cat > "$K8S_OUT_DIR/postgres-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${parent_name}-postgres
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${parent_name}-postgres
  template:
    metadata:
      labels:
        app: ${parent_name}-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          valueFrom:
            configMapKeyRef:
              name: ${parent_name}-config
              key: DATABASE_NAME
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${parent_name}-secret
              key: DATABASE_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${parent_name}-secret
              key: DATABASE_PASSWORD
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: ${parent_name}-postgres-pvc
      - name: init-script
        configMap:
          name: ${parent_name}-postgres-init
EOF

  # Service
  cat > "$K8S_OUT_DIR/postgres-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${parent_name}-postgres
  namespace: $namespace
spec:
  selector:
    app: ${parent_name}-postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF

  # Override DATABASE_HOST
  CONFIG_VARS["DATABASE_HOST"]="${parent_name}-postgres"
  log_info "Overriding DATABASE_HOST to: ${parent_name}-postgres"
}

find_dockerfiles() {
  local root_dir="$1"
  mapfile -t DOCKERFILES < <(find "$root_dir" -type f \
    \( -iname "Dockerfile" -o -iname "Dockerfile.*" -o -iname "dockerfile" \))
  echo "${DOCKERFILES[@]}"
}

generate_app_manifests_and_build() {
  local parent_name="$1"
  local namespace="$2"
  local tag="$3"
  shift 3
  local dockerfiles=("$@")

  if [[ ${#dockerfiles[@]} -eq 0 ]]; then
    log "❌ No Dockerfiles found. Exiting."
    exit 1
  fi

  log
  log "🐳 Building Docker images + generating manifests..."
  log

  for FILE in "${dockerfiles[@]}"; do
    local dir_path="$(dirname "$FILE")"
    local dir_name="$(basename "$dir_path")"

    local component_name image_suffix deploy_name service_name image_name port

    if [[ "$dir_path" == "$ROOT_DIR" ]]; then
      component_name="$parent_name"
      image_suffix=""
      deploy_name="$parent_name"
    else
      component_name="$dir_name"
      image_suffix="-$dir_name"
      deploy_name="${parent_name}${image_suffix}"
    fi

    image_name="${parent_name}${image_suffix}:${tag}"
    service_name="${deploy_name}-service"

    log "  Building: $image_name from $dir_path"
    docker build -f "$FILE" -t "$image_name" "$dir_path"
    kind load docker-image "$image_name" --name staging-cluster || log_warning "Failed to load image into kind (ignore if not using kind)"

    port=$(grep -i '^EXPOSE ' "$FILE" | awk '{print $2}' | head -1 || echo "8000")
    [[ -z "$port" ]] && port=8000

    # === Deployment ===
    cat > "$K8S_OUT_DIR/${component_name}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deploy_name
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $deploy_name
  template:
    metadata:
      labels:
        app: $deploy_name
    spec:
      containers:
      - name: app
        image: $image_name
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $port
        envFrom:
        - configMapRef:
            name: ${parent_name}-config
        - secretRef:
            name: ${parent_name}-secret
        readinessProbe:
          httpGet:
            path: /health
            port: $port
          initialDelaySeconds: 30
          periodSeconds: 5
          failureThreshold: 12
        livenessProbe:
          httpGet:
            path: /health
            port: $port
          initialDelaySeconds: 60
          periodSeconds: 10
          failureThreshold: 6
EOF

    # === Service ===
    cat > "$K8S_OUT_DIR/${component_name}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $namespace
spec:
  selector:
    app: $deploy_name
  ports:
  - port: 80
    targetPort: $port
    protocol: TCP
  type: ClusterIP
EOF

    log_success "Generated manifests for component: $component_name → deployment: $deploy_name, service: $service_name (port: $port)"
  done
}

# ========================
# Deployment Functions
# ========================

prompt_deploy() {
  read -p "Do you want to deploy to Kubernetes now? (y/N): " DEPLOY_CHOICE
  [[ "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]
}

deploy_to_kubernetes() {
  local namespace="$1"
  local ns_file="$2"

  log "📦 Deploying to Kubernetes cluster..."
  log

  # Namespace
  log "1️⃣  Creating namespace: $namespace"
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    log_info "Namespace '$namespace' already exists"
  else
    kubectl apply -f "$ns_file"
    log_success "Namespace created"
  fi

  # All other resources
  log "2️⃣  Deploying all Kubernetes resources..."
  mapfile -t YAML_FILES < <(find "$K8S_OUT_DIR" -name "*.yaml" ! -name "namespace.yaml")

  for YAML_FILE in "${YAML_FILES[@]}"; do
    log "   📄 Applying: $(basename "$YAML_FILE")"
    kubectl apply -f "$YAML_FILE" --namespace="$namespace"
  done
  log_success "All resources deployed"

  # Set namespace context
  log "3️⃣  Setting current context to namespace: $namespace"
  kubectl config set-context --current --namespace="$namespace"

  # Wait and check readiness
  log "4️⃣  Waiting for deployments to be ready..."
  sleep 5

  # Postgres check
  if [[ -f "$K8S_OUT_DIR/postgres-deployment.yaml" ]]; then
    wait_for_deployment "${PARENT_NAME}-postgres" "$namespace"
  fi

  # Other deployments
  for deploy_file in "$K8S_OUT_DIR"/*-deployment.yaml; do
    [[ -f "$deploy_file" ]] || continue
    local name=$(basename "$deploy_file" -deployment.yaml)
    [[ "$name" == "postgres" ]] && continue
    wait_for_deployment "$name" "$namespace"
  done

  # Final status
  log
  log "📊 Final Status Summary:"
  log "========================="
  log "📦 Namespace: $namespace"
  log
  kubectl get all -n "$namespace"
  log
  kubectl get pvc -n "$namespace"
  log
  kubectl get svc -n "$namespace"
  log
  kubectl get pods -n "$namespace" -o wide

  log
  log "📝 Useful Commands:"
  log "-------------------"
  log "View logs (PostgreSQL): kubectl logs -f deployment/${PARENT_NAME}-postgres -n $namespace"
  log "Get shell: kubectl exec -it <pod-name> -n $namespace -- bash"
  log "Delete everything: kubectl delete namespace $namespace"
  log
  log "🎉 Deployment completed!"
}

wait_for_deployment() {
  local deploy_name="$1"
  local namespace="$2"

  log "🔍 Checking $deploy_name deployment..."
  for i in {1..30}; do
    local ready=$(kubectl get deployment "$deploy_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$ready" == "1" ]]; then
      log_success "   $deploy_name is ready"
      return
    fi
    sleep 1
  done
  log_warning "   $deploy_name still not ready after 30 seconds"
}

show_manual_deploy_instructions() {
  local namespace="$1"

  log
  log "📋 Manual deployment instructions:"
  log "=================================="
  log "⚡ Deploy using:"
  log "   kubectl apply -f $K8S_OUT_DIR/"
  log
  log "⭐ Then select namespace:"
  log "   kubectl config set-context --current --namespace=$namespace"
  log
  log "📊 View resources:"
  log "   kubectl get all -n $namespace"
}

# ========================
# Main Execution
# ========================

main() {
  local root_dir="${1:-.}"

  get_project_config "$root_dir"

  log "🎯 Configuration Options"
  log "========================"

  local pvc_size
  pvc_size=$(prompt_pvc_size)

  local namespace
  namespace=$(prompt_namespace "$PARENT_NAME")

  local ns_file="$K8S_OUT_DIR/namespace.yaml"
  generate_namespace_manifest "$namespace" "$ns_file"

  log "🔍 Scanning for .env files..."
  local env_files=($(find_env_files "$ROOT_DIR"))
  if [[ ${#env_files[@]} -gt 0 ]]; then
    parse_env_files "${env_files[@]}"
  else
    log_info "No .env files found."
  fi

  local cm_file="$K8S_OUT_DIR/config.yaml"
  local sec_file="$K8S_OUT_DIR/secret.yaml"
  generate_config_and_secret_manifests "$PARENT_NAME" "$namespace" "$cm_file" "$sec_file"

  log "🔍 Scanning for database init SQL files..."
  local sql_files=($(find_sql_init_files "$ROOT_DIR"))
  generate_postgres_manifests "$PARENT_NAME" "$namespace" "$pvc_size" "${sql_files[*]}"

  log "🔍 Scanning for Dockerfiles..."
  local dockerfiles=($(find_dockerfiles "$ROOT_DIR"))
  generate_app_manifests_and_build "$PARENT_NAME" "$namespace" "$TAG" "${dockerfiles[@]}"

  log
  log "🎉 Finished building images + generating Kubernetes manifests."
  log "📂 Output in: $K8S_OUT_DIR"
  log

  if prompt_deploy; then
    deploy_to_kubernetes "$namespace" "$ns_file"
  else
    show_manual_deploy_instructions "$namespace"
  fi
}

# Run main
main "$@"