#!/usr/bin/env bash
set -euo pipefail

echo "🚀 GitHub Repository Deployment to Kubernetes"
echo "============================================"
echo

############################################
# 🎯 GitHub Repository Configuration
############################################
read -p "🔗 Enter GitHub repository URL (https format): " GITHUB_REPO_URL
if [[ ! "$GITHUB_REPO_URL" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/)?$ ]]; then
  echo "❌ Invalid GitHub URL format. Should be: https://github.com/username/repository"
  exit 1
fi

read -p "🌿 Enter branch name (default: main): " GITHUB_BRANCH
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

echo -n "🔑 Enter GitHub token (press Enter if public repo): "
read -s GITHUB_TOKEN
echo

REPO_NAME=$(basename "$GITHUB_REPO_URL" .git)
WORK_DIR="/tmp/k8s-deploy-$REPO_NAME-$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "📥 Cloning repository..."
if [[ -n "$GITHUB_TOKEN" ]]; then
  GITHUB_REPO_URL_WITH_TOKEN=$(echo "$GITHUB_REPO_URL" | sed "s|https://|https://$GITHUB_TOKEN@|")
  git clone -b "$GITHUB_BRANCH" "$GITHUB_REPO_URL_WITH_TOKEN" "$REPO_NAME" || { echo "❌ Failed to clone repo"; exit 1; }
else
  git clone -b "$GITHUB_BRANCH" "$GITHUB_REPO_URL" "$REPO_NAME" || { echo "❌ Failed to clone repo"; exit 1; }
fi

cd "$REPO_NAME"
ROOT_DIR="$(pwd)"
PARENT_NAME="$REPO_NAME"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"
mkdir -p "$K8S_OUT_DIR"

# 🧹 Clean old manifests before generating new ones
echo "🧹 Cleaning old manifests..."
rm -f "$K8S_OUT_DIR"/*.yaml

############################################
# Helper: trim whitespace
############################################
trim() { awk '{$1=$1};1'; }

############################################
# 🎯 Interactive configuration
############################################
TAG=$(printf "%05d" $((RANDOM % 100000)))
read -p "🏷️  Use auto-generated tag '$TAG' or enter custom tag? (press enter for auto/custom): " CUSTOM_TAG_INPUT
[[ -n "$CUSTOM_TAG_INPUT" ]] && TAG="$CUSTOM_TAG_INPUT"

read -p "📦 Enter PVC storage size (default: 10Gi): " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"
[[ ! "$PVC_SIZE" =~ ^[0-9]+(Gi|Mi|G|M)$ ]] && echo "⚠️  Invalid PVC size, using default 10Gi" && PVC_SIZE="10Gi"

read -p "🏷️  Enter Kubernetes namespace (default: ${PARENT_NAME}): " USER_NAMESPACE
if [[ -n "$USER_NAMESPACE" ]]; then
  NAMESPACE="$(echo "$USER_NAMESPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed 's/^-//;s/-$//')"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="${PARENT_NAME}"
else
  NAMESPACE="$(echo "$PARENT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  NAMESPACE="${NAMESPACE##-}"
  NAMESPACE="${NAMESPACE%%-}"
fi
[[ -z "$NAMESPACE" ]] && NAMESPACE="app-namespace"

############################################
# 🎯 Namespace YAML (always created)
############################################
NS_FILE="$K8S_OUT_DIR/namespace.yaml"
cat > "$NS_FILE" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

############################################
# 🔍 .env parsing & DB detection
############################################
echo "🔍 Scanning for .env files and init.sql..."
mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f -iname ".env*" ! -iname "*.example")
mapfile -t SQL_FILES < <(find "$ROOT_DIR" -maxdepth 2 -type f \( -iname "init.sql" -o -iname "*.sql" \))

declare -A CONFIG_VARS
declare -A SECRET_VARS

HAS_ENV=false
HAS_SQL=false

if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
  HAS_ENV=true
  echo "📄 Found ${#ENV_FILES[@]} .env file(s)"
else
  echo "ℹ️  No .env files found → skipping ConfigMap and Secret"
fi

if [[ ${#SQL_FILES[@]} -gt 0 ]]; then
  HAS_SQL=true
  echo "🗄️  Found SQL init file(s)"
fi

DB_REQUIRED=false
DB_TYPE=""

if $HAS_ENV; then
  for ENV_FILE in "${ENV_FILES[@]}"; do
    echo "  Processing: $ENV_FILE"
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
      KEY="$(echo "$KEY" | trim)"
      [[ -z "$KEY" ]] && continue
      [[ "$KEY" =~ ^# ]] && continue
      VALUE="${VALUE:-}"; VALUE="$(echo "$VALUE" | trim)"
      VALUE="${VALUE#\"}"; VALUE="${VALUE%\"}"; VALUE="${VALUE#\'}"; VALUE="${VALUE%\'}"

      if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
        SECRET_VARS["$KEY"]="$VALUE"
      else
        CONFIG_VARS["$KEY"]="$VALUE"
      fi

      if [[ "$KEY" == "DATABASE_HOST" ]]; then
        DB_REQUIRED=true
        DB_TYPE="$VALUE"
      fi
    done < "$ENV_FILE"
  done
fi

############################################
# 🔹 Generate DB resources ONLY if needed
############################################
if [[ "$DB_REQUIRED" == true && "$HAS_ENV" == true ]]; then
  echo "🛢️ Database requested via DATABASE_HOST=$DB_TYPE"

  case "$DB_TYPE" in
    postgres)
      if [[ "$HAS_SQL" == true ]]; then
        SQL_FILE="${SQL_FILES[0]}"
        cat > "$K8S_OUT_DIR/postgres-init-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-postgres-init
  namespace: $NAMESPACE
data:
  init.sql: |
$(sed 's/^/    /' "$SQL_FILE")
EOF
      fi

      cat > "$K8S_OUT_DIR/postgres-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PARENT_NAME}-postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $PVC_SIZE
EOF

      cat > "$K8S_OUT_DIR/postgres-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PARENT_NAME}-postgres
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-postgres
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
              name: ${PARENT_NAME}-config
              key: DATABASE_NAME
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_PASSWORD
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: ${PARENT_NAME}-postgres-pvc
      - name: init-script
        configMap:
          name: ${PARENT_NAME}-postgres-init
          defaultMode: 0777
EOF

      cat > "$K8S_OUT_DIR/postgres-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF

      CONFIG_VARS["DATABASE_HOST"]="${PARENT_NAME}-postgres"
      ;;

    mysql)
      # Similar for MySQL (omitted for brevity — you already have it)
      # Just wrap in the same condition if needed
      ;;

    *)
      echo "⚠️ Unsupported DATABASE_HOST: $DB_TYPE. Skipping DB."
      ;;
  esac
else
  echo "ℹ️ No database required or no .env found → skipping DB resources."
fi

############################################
# 🔍 Scan Dockerfiles & build images
############################################
mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -type f \( -iname "Dockerfile" -o -iname "Dockerfile.*" -o -iname "dockerfile" \))
[[ ${#DOCKERFILES[@]} -eq 0 ]] && echo "❌ No Dockerfiles found. Exiting." && exit 1

for FILE in "${DOCKERFILES[@]}"; do
  DIR_PATH="$(dirname "$FILE")"
  
  YAML_PREFIX="${REPO_NAME}"

  if [[ "$DIR_PATH" == "$ROOT_DIR" ]]; then
    SERVICE_NAME_PART="$REPO_NAME"
    DEPLOY_NAME="${PARENT_NAME}"
  else
    SUBDIR="$(basename "$DIR_PATH")"
    YAML_PREFIX="${REPO_NAME}-${SUBDIR}"
    SERVICE_NAME_PART="$SUBDIR"
    DEPLOY_NAME="${PARENT_NAME}-${SUBDIR}"
  fi

  SERVICE_NAME="${DEPLOY_NAME}-service"
  IMAGE_NAME="${PARENT_NAME}-${SERVICE_NAME_PART}:${TAG}"

  echo "🐳 Building image: $IMAGE_NAME from $FILE"
  docker build -f "$FILE" -t "$IMAGE_NAME" "$DIR_PATH"

  if kind get clusters 2>/dev/null | grep -q "staging-cluster"; then
    kind load docker-image "$IMAGE_NAME" --name staging-cluster
  fi

  PORT=$(grep -Ei '^\s*EXPOSE\s+' "$FILE" | awk '{print $2}' | head -1 || echo "")
  [[ -z "$PORT" ]] && PORT=8000

  cat > "$K8S_OUT_DIR/${YAML_PREFIX}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
    spec:
      containers:
      - name: $SERVICE_NAME_PART
        image: $IMAGE_NAME
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
            optional: true
        - secretRef:
            name: ${PARENT_NAME}-secret
            optional: true
        readinessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 30
          periodSeconds: 5
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 60
          periodSeconds: 10
          failureThreshold: 6
EOF

  cat > "$K8S_OUT_DIR/${YAML_PREFIX}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $DEPLOY_NAME
  ports:
  - port: 80
    targetPort: $PORT
    protocol: TCP
  type: ClusterIP
EOF

  echo "✅ Generated: ${YAML_PREFIX}-deployment.yaml and ${YAML_PREFIX}-service.yaml"
done

############################################
# ConfigMap & Secret YAML — only if .env exists
############################################
if [[ "$HAS_ENV" == true ]]; then
  CM_FILE="$K8S_OUT_DIR/config.yaml"
  SEC_FILE="$K8S_OUT_DIR/secret.yaml"

  cat > "$CM_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-config
  namespace: $NAMESPACE
data:
EOF
  for KEY in "${!CONFIG_VARS[@]}"; do
    echo "  $KEY: \"${CONFIG_VARS[$KEY]}\"" >> "$CM_FILE"
  done

  cat > "$SEC_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PARENT_NAME}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
EOF
  for KEY in "${!SECRET_VARS[@]}"; do
    echo "  $KEY: \"${SECRET_VARS[$KEY]}\"" >> "$SEC_FILE"
  done

  echo "✅ Generated ConfigMap and Secret from .env files"
else
  echo "ℹ️  No .env files → skipping ConfigMap and Secret"
fi

echo
echo "✅ Kubernetes manifests generated in: $K8S_OUT_DIR"

############################################
# 🚀 Interactive deployment
############################################
read -p "Do you want to deploy to Kubernetes now? (y/N): " DEPLOY_CHOICE
if [[ "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]; then
  kubectl apply -f "$NS_FILE"

  mapfile -t YAML_FILES < <(find "$K8S_OUT_DIR" -name "*.yaml")
  for YAML in "${YAML_FILES[@]}"; do
    kubectl apply -f "$YAML" --namespace="$NAMESPACE"
  done

  echo "⏳ Waiting for deployments to become ready..."
  if kubectl wait --for=condition=Available --timeout=300s deployment --all -n "$NAMESPACE"; then
    echo "✅ All deployments are ready!"
  else
    echo "⚠️  Some deployments failed to become ready."
    echo "🔍 Status:"
    kubectl get deployments,pods -n "$NAMESPACE" -o wide
    echo
    echo "💡 Run: kubectl describe pod <name> -n $NAMESPACE"
  fi

  echo
  echo "🎉 Deployment completed!"
  echo "📂 Workspace: $WORK_DIR"
  echo "📁 Manifests: $K8S_OUT_DIR"
  echo "🏷️  Images tagged: $TAG"
fi