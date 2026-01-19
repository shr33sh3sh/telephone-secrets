#!/bin/bash
set -e

# Configuration
OUTPUT_DIR="k8s-prod"
DEFAULT_NAMESPACE="telephone-secrets"
DEFAULT_APP_NAME="phone-directory"
DEFAULT_PVC_SIZE="5Gi"
DEFAULT_CLUSTER_NAME="staging-cluster"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

mkdir -p "$OUTPUT_DIR"

# 1. Gather User Input
echo -e "${GREEN}Welcome to the Production Manifest Generator!${NC}"
echo "---------------------------------------------"

read -p "Enter Namespace [${DEFAULT_NAMESPACE}]: " NAMESPACE
NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}

read -p "Enter App Name label [${DEFAULT_APP_NAME}]: " APP_NAME
APP_NAME=${APP_NAME:-$DEFAULT_APP_NAME}

read -p "Enter Postgres PVC Size [${DEFAULT_PVC_SIZE}]: " PVC_SIZE
PVC_SIZE=${PVC_SIZE:-$DEFAULT_PVC_SIZE}

# Generate random 5-digit tag
RANDOM_TAG=$(printf "%05d" $((RANDOM % 100000)))

read -p "Enter Image Tag (applied to both) [${RANDOM_TAG}]: " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-$RANDOM_TAG}

BACKEND_TAG=$IMAGE_TAG
FRONTEND_TAG=$IMAGE_TAG

log_info "generating manifests in '$OUTPUT_DIR' for namespace '$NAMESPACE'..."


# 2. Namespace Manifest
cat > "$OUTPUT_DIR/00-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    name: $NAMESPACE
EOF
log_success "Generated 00-namespace.yaml"


# 3. Secrets & ConfigMaps
# Parse .env if exists, otherwise use defaults
if [ -f .env ]; then
    log_info "Reading .env file..."
    export $(grep -v '^#' .env | xargs)
fi

POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}
POSTGRES_DB=${POSTGRES_DB:-phone_directory}
SECRET_KEY=${SECRET_KEY:-default-production-secret-key-CHANGE-ME}

# Encode secrets
ENC_PG_USER=$(echo -n "$POSTGRES_USER" | base64)
ENC_PG_PASS=$(echo -n "$POSTGRES_PASSWORD" | base64)
ENC_PG_DB=$(echo -n "$POSTGRES_DB" | base64)
ENC_SECRET_KEY=$(echo -n "$SECRET_KEY" | base64)

cat > "$OUTPUT_DIR/01-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: $NAMESPACE
type: Opaque
data:
  POSTGRES_USER: $ENC_PG_USER
  POSTGRES_PASSWORD: $ENC_PG_PASS
  POSTGRES_DB: $ENC_PG_DB
  SECRET_KEY: $ENC_SECRET_KEY
EOF
log_success "Generated 01-secrets.yaml"


# Postgres Init Script
if [ -f database/init.sql ]; then
    log_info "Found init.sql..."
    cat > "$OUTPUT_DIR/02-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: $NAMESPACE
data:
  init.sql: |
$(sed 's/^/    /' database/init.sql)
EOF
    log_success "Generated 02-configmap.yaml"
else
    log_warn "No database/init.sql found! Skipping ConfigMap generation."
fi


# 4. Postgres Deployment
cat > "$OUTPUT_DIR/03-postgres.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $PVC_SIZE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $NAMESPACE
  labels:
    app: $APP_NAME
    component: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_NAME
      component: database
  template:
    metadata:
      labels:
        app: $APP_NAME
        component: database
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
            - name: init-script
              mountPath: /docker-entrypoint-initdb.d/init.sql
              subPath: init.sql
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
        - name: init-script
          configMap:
            name: postgres-init
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: $APP_NAME
    component: database
  ports:
    - port: 5432
      targetPort: 5432
EOF
log_success "Generated 03-postgres.yaml"


# 5. Backend Deployment
cat > "$OUTPUT_DIR/04-backend.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: $NAMESPACE
  labels:
    app: $APP_NAME
    component: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $APP_NAME
      component: backend
  template:
    metadata:
      labels:
        app: $APP_NAME
        component: backend
    spec:
      containers:
        - name: backend
          image: phone-directory-backend:$BACKEND_TAG
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          env:
            - name: DB_HOST
              value: "postgres"
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_DB
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: POSTGRES_PASSWORD
            - name: SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: SECRET_KEY
            - name: FLASK_DEBUG
              value: "false"
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: $NAMESPACE
spec:
  selector:
    app: $APP_NAME
    component: backend
  ports:
    - port: 5000
      targetPort: 5000
EOF
log_success "Generated 04-backend.yaml"


# 6. Frontend Deployment
cat > "$OUTPUT_DIR/05-frontend.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: $NAMESPACE
  labels:
    app: $APP_NAME
    component: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_NAME
      component: frontend
  template:
    metadata:
      labels:
        app: $APP_NAME
        component: frontend
    spec:
      containers:
        - name: frontend
          image: phone-directory-frontend:$FRONTEND_TAG
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "100m"
          readinessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  selector:
    app: $APP_NAME
    component: frontend
  ports:
    - port: 80
      targetPort: 80
EOF
log_success "Generated 05-frontend.yaml"

echo ""
echo -e "${GREEN}Done!${NC} Production manifests are in '${OUTPUT_DIR}/'"
echo "To deploy, run: kubectl apply -f ${OUTPUT_DIR}/"

# --- Kind Cluster Integration ---

# Functions
create_cluster() {
    log_info "Creating Kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME"
    log_info "Cluster '$CLUSTER_NAME' created."
}

build_images() {
    log_info "Building Backend Image (phone-directory-backend:$BACKEND_TAG)..."
    docker build -t "phone-directory-backend:$BACKEND_TAG" ./backend

    log_info "Building Frontend Image (phone-directory-frontend:$FRONTEND_TAG)..."
    docker build -t "phone-directory-frontend:$FRONTEND_TAG" ./frontend
}

# Main Kind Logic
read -p "Enter Kind Cluster Name [${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    log_info "Cluster '$CLUSTER_NAME' found."
else
    log_warn "Cluster '$CLUSTER_NAME' NOT found."
    read -p "Do you want to create the cluster '$CLUSTER_NAME'? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_cluster
    else
        log_info "Skipping cluster creation."
    fi
fi

# Build and Load
echo ""
read -p "Do you want to build and load images into '$CLUSTER_NAME'? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    
    # Build
    build_images

    # Load
    log_info "Loading Backend Image into '$CLUSTER_NAME'..."
    kind load docker-image "phone-directory-backend:$BACKEND_TAG" --name "$CLUSTER_NAME"

    log_info "Loading Frontend Image into '$CLUSTER_NAME'..."
    kind load docker-image "phone-directory-frontend:$FRONTEND_TAG" --name "$CLUSTER_NAME"

    log_info "Images loaded successfully."
    
else
    log_info "Skipping build and load."
fi

echo ""
read -p "Do you want to deploy the manifests to '$CLUSTER_NAME' now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl apply -f "$OUTPUT_DIR/"
    log_success "Deployed manifests to $CLUSTER_NAME"
fi
