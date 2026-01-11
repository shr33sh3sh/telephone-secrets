#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"

TAG="$(printf "%05d" $((RANDOM % 1000000)))"
PARENT_NAME="$(basename "$(realpath "$ROOT_DIR")")"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"

mkdir -p "$K8S_OUT_DIR"

echo "📦 Project: $PARENT_NAME"
echo

############################################
# Helpers
############################################
trim() { awk '{$1=$1};1'; }

############################################
# Interactive config
############################################
read -p "📦 PostgreSQL PVC size (default: 10Gi): " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"

read -p "🏷️  Kubernetes namespace (default: ${PARENT_NAME}): " NAMESPACE
NAMESPACE="${NAMESPACE:-$PARENT_NAME}"
NAMESPACE="$(echo "$NAMESPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"

read -p "🌐 Public hostname (Ingress) (default: ${PARENT_NAME}.local): " HOSTNAME
HOSTNAME="${HOSTNAME:-${PARENT_NAME}.local}"

############################################
# Namespace
############################################
cat > "$K8S_OUT_DIR/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

############################################
# Parse .env files
############################################
declare -A CONFIG_VARS
declare -A SECRET_VARS

mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f -iname ".env*" ! -iname "*.example")

for ENV_FILE in "${ENV_FILES[@]}"; do
  while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
    KEY="$(echo "$KEY" | trim)"
    [[ -z "$KEY" || "$KEY" =~ ^# ]] && continue
    VALUE="$(echo "${VALUE:-}" | trim | sed 's/^["'\'']//;s/["'\'']$//')"

    if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
      SECRET_VARS["$KEY"]="$VALUE"
    else
      CONFIG_VARS["$KEY"]="$VALUE"
    fi
  done < "$ENV_FILE"
done

############################################
# PostgreSQL (StatefulSet)
############################################
CONFIG_VARS["DB_HOST"]="${PARENT_NAME}-postgres"
CONFIG_VARS["DB_PORT"]="5432"

cat > "$K8S_OUT_DIR/postgres.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  clusterIP: None
  selector:
    app: ${PARENT_NAME}-postgres
  ports:
  - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  serviceName: ${PARENT_NAME}-postgres
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
              key: DB_NAME
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DB_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DB_PASSWORD
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: $PVC_SIZE
EOF

############################################
# ConfigMap + Secret
############################################
cat > "$K8S_OUT_DIR/config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-config
  namespace: $NAMESPACE
data:
EOF

for K in "${!CONFIG_VARS[@]}"; do
  echo "  $K: \"${CONFIG_VARS[$K]}\"" >> "$K8S_OUT_DIR/config.yaml"
done

cat > "$K8S_OUT_DIR/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PARENT_NAME}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
EOF

for K in "${!SECRET_VARS[@]}"; do
  echo "  $K: \"${SECRET_VARS[$K]}\"" >> "$K8S_OUT_DIR/secret.yaml"
done

############################################
# Dockerfiles → Backend / Frontend
############################################
mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -iname Dockerfile)

for FILE in "${DOCKERFILES[@]}"; do
  DIR="$(dirname "$FILE")"

  if grep -qi nginx "$FILE" || grep -qi "EXPOSE 80" "$FILE"; then
    TYPE="frontend"
  else
    TYPE="backend"
  fi

  IMAGE="${PARENT_NAME}-${TYPE}:${TAG}"
  docker build -t "$IMAGE" "$DIR" || true

  PORT=$(grep -i '^EXPOSE ' "$FILE" | awk '{print $2}' | head -1)
  PORT="${PORT:-5000}"

  if [[ "$TYPE" == "frontend" ]]; then
    CONFIG_VARS["BACKEND_URL"]="http://${PARENT_NAME}-backend-service"
  fi

  cat > "$K8S_OUT_DIR/${TYPE}.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PARENT_NAME}-${TYPE}
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PARENT_NAME}-${TYPE}
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-${TYPE}
    spec:
      containers:
      - name: ${TYPE}
        image: $IMAGE
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
EOF

  if [[ "$TYPE" == "frontend" ]]; then
    cat >> "$K8S_OUT_DIR/${TYPE}.yaml" <<EOF
        command:
        - /bin/sh
        - -c
        - |
          echo "window.__ENV__ = { BACKEND_URL: '\$BACKEND_URL' };" \
            > /usr/share/nginx/html/env.js
          exec nginx -g 'daemon off;'
EOF
  fi

  cat >> "$K8S_OUT_DIR/${TYPE}.yaml" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${PARENT_NAME}-${TYPE}-service
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-${TYPE}
  ports:
  - port: 80
    targetPort: $PORT
EOF
done

############################################
# Ingress
############################################
cat > "$K8S_OUT_DIR/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PARENT_NAME}-ingress
  namespace: $NAMESPACE
spec:
  ingressClassName: nginx
  rules:
  - host: $HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${PARENT_NAME}-frontend-service
            port:
              number: 80
EOF

############################################
# Finish
############################################
echo
echo "🎉 Kubernetes manifests generated!"
echo "📂 Location: $K8S_OUT_DIR"
echo
echo "🚀 Deploy with:"
echo "kubectl apply -f $K8S_OUT_DIR/"
echo
echo "🌐 Access app at: http://$HOSTNAME"

############################################
# 🚀 INTERACTIVE DEPLOYMENT
############################################
NS_FILE="$K8S_OUT_DIR/namespace.yaml"

echo "🚀 Deployment Options"
echo "===================="
read -p "Do you want to deploy to Kubernetes now? (y/N): " DEPLOY_CHOICE

if [[ "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]; then
  echo "📦 Deploying to Kubernetes cluster..."
  echo
  
  # 1. Deploy namespace first
  echo "1️⃣  Creating namespace: $NAMESPACE"
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "   ℹ️  Namespace '$NAMESPACE' already exists"
  else
    kubectl apply -f "$NS_FILE"
    echo "   ✅ Namespace created"
  fi
  
  # 2. Deploy all other resources
  echo "2️⃣  Deploying all Kubernetes resources..."
  
  # Get all yaml files except namespace (since we already deployed it)
  mapfile -t YAML_FILES < <(find "$K8S_OUT_DIR" -name "*.yaml" ! -name "namespace.yaml")
  
  for YAML_FILE in "${YAML_FILES[@]}"; do
    echo "   📄 Applying: $(basename "$YAML_FILE")"
    kubectl apply -f "$YAML_FILE" --namespace="$NAMESPACE"
  done
  
  echo "   ✅ All resources deployed"
  
  # 3. Set current context to namespace
  echo "3️⃣  Setting current context to namespace: $NAMESPACE"
  kubectl config set-context --current --namespace="$NAMESPACE"
  
  # 4. Wait for deployments to be ready
  echo "4️⃣  Waiting for deployments to be ready..."
  echo
  sleep 5
  
  # Check deployments
  echo "📊 Deployment Status:"
  echo "-------------------"
  
  # Check Postgres if it exists
  if kubectl get statefulset "${PARENT_NAME}-postgres" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "🔍 Checking PostgreSQL StatefulSet..."
  for i in {1..30}; do
    READY=$(kubectl get statefulset "${PARENT_NAME}-postgres" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$READY" == "1" ]]; then
      echo "   ✅ PostgreSQL is ready"
      break
    fi
    [[ $i -eq 30 ]] && echo "   ⚠️ PostgreSQL still not ready"
    sleep 1
  done
  fi