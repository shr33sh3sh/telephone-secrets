#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Interactive Kubernetes Manifest Generator
# 
# Scans a project directory for Dockerfile, .env, and init.sql files,
# then generates appropriate Kubernetes manifests based on what's found.
################################################################################

# Color codes for better UX
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# Configuration
ROOT_DIR="${1:-.}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
PARENT_NAME="$(basename "$(realpath "$ROOT_DIR")")"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests-$TIMESTAMP"

# Helper functions
print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

trim() { 
    echo "$1" | awk '{$1=$1};1'; 
}

################################################################################
# STEP 1: Project Discovery
################################################################################
print_header "📦 STEP 1: Project Discovery"
echo "Project: $PARENT_NAME"
echo "Scanning directory: $ROOT_DIR"
echo

# Find Dockerfiles
echo "🔍 Scanning for Dockerfiles..."
mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -type f -iname "Dockerfile" 2>/dev/null || true)
if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
    print_success "Found ${#DOCKERFILES[@]} Dockerfile(s):"
    for df in "${DOCKERFILES[@]}"; do
        echo "   📄 ${df#$ROOT_DIR/}"
    done
else
    print_info "No Dockerfiles found"
fi
echo

# Find .env files
echo "🔍 Scanning for .env files..."
mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f \( -iname ".env" -o -iname ".env.*" \) ! -iname "*.example" 2>/dev/null || true)
if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
    print_success "Found ${#ENV_FILES[@]} .env file(s):"
    for ef in "${ENV_FILES[@]}"; do
        echo "   📄 ${ef#$ROOT_DIR/}"
    done
else
    print_info "No .env files found"
fi
echo

# Find init.sql files
echo "🔍 Scanning for init.sql files..."
mapfile -t INIT_SQL_FILES < <(find "$ROOT_DIR" -type f -iname "init.sql" 2>/dev/null || true)
if [[ ${#INIT_SQL_FILES[@]} -gt 0 ]]; then
    print_success "Found ${#INIT_SQL_FILES[@]} init.sql file(s):"
    for sql in "${INIT_SQL_FILES[@]}"; do
        echo "   📄 ${sql#$ROOT_DIR/}"
    done
else
    print_info "No init.sql files found"
fi
echo

################################################################################
# STEP 2: Interactive Configuration
################################################################################
print_header "⚙️  STEP 2: Configuration"

# Repository name (becomes namespace)
read -p "🏷️  Repository/Namespace name (default: ${PARENT_NAME}): " REPO_NAME
REPO_NAME="${REPO_NAME:-$PARENT_NAME}"
# Sanitize: lowercase, replace underscores with hyphens, remove invalid chars
NAMESPACE="$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-' | sed 's/^-//;s/-$//')"
print_success "Namespace: $NAMESPACE"
echo

# PVC size
read -p "💾 PVC size for persistent storage (default: 10Gi): " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"
print_success "PVC Size: $PVC_SIZE"
echo

################################################################################
# STEP 3: Generate Manifests
################################################################################
print_header "📝 STEP 3: Generating Kubernetes Manifests"
mkdir -p "$K8S_OUT_DIR"
print_success "Output directory created: $K8S_OUT_DIR"
echo

MANIFESTS_CREATED=()

# --- Namespace (always created) ---
echo "📄 Generating namespace.yaml..."
cat > "$K8S_OUT_DIR/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    name: $NAMESPACE
EOF
MANIFESTS_CREATED+=("namespace.yaml")
print_success "Created: namespace.yaml"
echo

# --- Parse .env files if present ---
declare -A CONFIG_VARS
declare -A SECRET_VARS

if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
    echo "🔐 Parsing .env files..."
    for ENV_FILE in "${ENV_FILES[@]}"; do
        while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
            # Trim whitespace
            KEY="$(trim "$KEY")"
            # Skip empty lines and comments
            [[ -z "$KEY" || "$KEY" =~ ^# ]] && continue
            # Trim and remove quotes from value
            VALUE="$(trim "$VALUE")"
            VALUE="${VALUE#\"}"
            VALUE="${VALUE%\"}"
            VALUE="${VALUE#\'}"
            VALUE="${VALUE%\'}"

            # Classify as secret or config
            if [[ "$KEY" =~ (PASSWORD|TOKEN|KEY|SECRET|API_KEY) ]]; then
                SECRET_VARS["$KEY"]="$VALUE"
            else
                CONFIG_VARS["$KEY"]="$VALUE"
            fi
        done < "$ENV_FILE"
    done
    print_success "Parsed ${#CONFIG_VARS[@]} config variables and ${#SECRET_VARS[@]} secret variables"
    echo
fi

# --- ConfigMap (only if .env exists) ---
if [[ ${#ENV_FILES[@]} -gt 0 && ${#CONFIG_VARS[@]} -gt 0 ]]; then
    echo "📄 Generating configmap.yaml..."
    cat > "$K8S_OUT_DIR/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${NAMESPACE}-config
  namespace: $NAMESPACE
data:
EOF
    for K in "${!CONFIG_VARS[@]}"; do
        echo "  $K: \"${CONFIG_VARS[$K]}\"" >> "$K8S_OUT_DIR/configmap.yaml"
    done
    MANIFESTS_CREATED+=("configmap.yaml")
    print_success "Created: configmap.yaml (${#CONFIG_VARS[@]} variables)"
    echo
fi

# --- Secret (only if .env exists and has secrets) ---
if [[ ${#ENV_FILES[@]} -gt 0 && ${#SECRET_VARS[@]} -gt 0 ]]; then
    echo "📄 Generating secret.yaml..."
    cat > "$K8S_OUT_DIR/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${NAMESPACE}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
EOF
    for K in "${!SECRET_VARS[@]}"; do
        echo "  $K: \"${SECRET_VARS[$K]}\"" >> "$K8S_OUT_DIR/secret.yaml"
    done
    MANIFESTS_CREATED+=("secret.yaml")
    print_success "Created: secret.yaml (${#SECRET_VARS[@]} secrets)"
    echo
fi

# --- Deployments and Services (only if Dockerfile exists) ---
if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
    echo "🚢 Generating Deployments and Services..."
    
    for DF in "${DOCKERFILES[@]}"; do
        DIR="$(dirname "$DF")"
        DIR_NAME="$(basename "$DIR")"
        
        # Determine service type
        if grep -qi nginx "$DF" 2>/dev/null || grep -qi "EXPOSE 80" "$DF" 2>/dev/null; then
            SERVICE_TYPE="frontend"
        elif grep -qi python "$DF" 2>/dev/null || grep -qi flask "$DF" 2>/dev/null || grep -qi node "$DF" 2>/dev/null; then
            SERVICE_TYPE="backend"
        else
            SERVICE_TYPE="$DIR_NAME"
        fi
        
        # Extract port from Dockerfile
        PORT=$(grep -i '^EXPOSE ' "$DF" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
        PORT="${PORT:-8080}"
        
        # Generate deployment and service
        MANIFEST_FILE="${SERVICE_TYPE}-deployment.yaml"
        echo "📄 Generating $MANIFEST_FILE..."
        
        cat > "$K8S_OUT_DIR/$MANIFEST_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAMESPACE}-${SERVICE_TYPE}
  namespace: $NAMESPACE
  labels:
    app: ${SERVICE_TYPE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${SERVICE_TYPE}
  template:
    metadata:
      labels:
        app: ${SERVICE_TYPE}
    spec:
      containers:
      - name: ${SERVICE_TYPE}
        image: ${NAMESPACE}-${SERVICE_TYPE}:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $PORT
EOF

        # Add env from ConfigMap/Secret only if they exist
        if [[ ${#CONFIG_VARS[@]} -gt 0 || ${#SECRET_VARS[@]} -gt 0 ]]; then
            cat >> "$K8S_OUT_DIR/$MANIFEST_FILE" <<EOF
        envFrom:
EOF
            [[ ${#CONFIG_VARS[@]} -gt 0 ]] && cat >> "$K8S_OUT_DIR/$MANIFEST_FILE" <<EOF
        - configMapRef:
            name: ${NAMESPACE}-config
EOF
            [[ ${#SECRET_VARS[@]} -gt 0 ]] && cat >> "$K8S_OUT_DIR/$MANIFEST_FILE" <<EOF
        - secretRef:
            name: ${NAMESPACE}-secret
EOF
        fi

        # Add service
        cat >> "$K8S_OUT_DIR/$MANIFEST_FILE" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAMESPACE}-${SERVICE_TYPE}-service
  namespace: $NAMESPACE
  labels:
    app: ${SERVICE_TYPE}
spec:
  selector:
    app: ${SERVICE_TYPE}
  ports:
  - protocol: TCP
    port: $PORT
    targetPort: $PORT
  type: ClusterIP
EOF
        
        MANIFESTS_CREATED+=("$MANIFEST_FILE")
        print_success "Created: $MANIFEST_FILE (port: $PORT)"
    done
    echo
fi

# --- Database StatefulSet (only if init.sql does NOT exist) ---
if [[ ${#INIT_SQL_FILES[@]} -eq 0 ]]; then
    echo "🗄️  No init.sql found - generating database StatefulSet..."
    echo "📄 Generating postgres-statefulset.yaml..."
    
    cat > "$K8S_OUT_DIR/postgres-statefulset.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${NAMESPACE}-postgres
  namespace: $NAMESPACE
  labels:
    app: postgres
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${NAMESPACE}-postgres
  namespace: $NAMESPACE
spec:
  serviceName: ${NAMESPACE}-postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: "${NAMESPACE}_db"
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${NAMESPACE}-secret
              key: DB_USER
              optional: true
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${NAMESPACE}-secret
              key: DB_PASSWORD
              optional: true
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: $PVC_SIZE
EOF
    
    MANIFESTS_CREATED+=("postgres-statefulset.yaml")
    print_success "Created: postgres-statefulset.yaml (PVC: $PVC_SIZE)"
    echo
else
    print_info "Skipping database StatefulSet (init.sql found - assuming external/managed database)"
    echo
fi

################################################################################
# STEP 4: Summary
################################################################################
print_header "🎉 Generation Complete!"
echo "📂 Output directory: $K8S_OUT_DIR"
echo
echo "📄 Generated manifests:"
for manifest in "${MANIFESTS_CREATED[@]}"; do
    echo "   ✓ $K8S_OUT_DIR/$manifest"
done
echo
echo "🚀 To deploy:"
echo "   kubectl apply -f $K8S_OUT_DIR/"
echo
echo "🔍 To verify:"
echo "   kubectl get all -n $NAMESPACE"
echo

################################################################################
# STEP 5: Interactive Deployment to Kind Cluster
################################################################################
echo
read -p "📦 Do you want to deploy to a Kind cluster now? (y/N): " DEPLOY_CHOICE

if [[ ! "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]; then
    print_info "Deployment skipped. You can deploy later using: kubectl apply -f $K8S_OUT_DIR/"
    exit 0
fi

print_header "🚀 STEP 5: Deploying to Kind Cluster"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    print_error "Kind is not installed. Please install it from https://kind.sigs.k8s.io/"
    exit 1
fi

# Check if docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# List available Kind clusters using kubectl contexts
echo "🔍 Checking for Kind clusters..."
mapfile -t KIND_CONTEXTS < <(kubectl config get-contexts -o name 2>/dev/null | grep "^kind-" || echo "")

if [[ ${#KIND_CONTEXTS[@]} -eq 0 || -z "${KIND_CONTEXTS[0]}" ]]; then
    print_info "No Kind clusters found."
    read -p "📦 Create a new Kind cluster? (y/N): " CREATE_CLUSTER
    
    if [[ "$CREATE_CLUSTER" =~ ^[Yy]$ ]]; then
        read -p "🏷️  Cluster name (default: kind): " CLUSTER_NAME
        CLUSTER_NAME="${CLUSTER_NAME:-kind}"
        
        echo "🔨 Creating Kind cluster '$CLUSTER_NAME'..."
        kind create cluster --name "$CLUSTER_NAME"
        
        if [[ $? -eq 0 ]]; then
            print_success "Kind cluster '$CLUSTER_NAME' created successfully"
            CONTEXT_NAME="kind-$CLUSTER_NAME"
        else
            print_error "Failed to create Kind cluster"
            exit 1
        fi
    else
        print_info "Deployment cancelled. No cluster available."
        exit 0
    fi
else
    # Get current context
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
    
    echo "📋 Available Kind clusters:"
    for i in "${!KIND_CONTEXTS[@]}"; do
        CONTEXT="${KIND_CONTEXTS[$i]}"
        if [[ "$CONTEXT" == "$CURRENT_CONTEXT" ]]; then
            echo "   $((i+1)). $CONTEXT (current) ⭐"
        else
            echo "   $((i+1)). $CONTEXT"
        fi
    done
    echo
    
    if [[ ${#KIND_CONTEXTS[@]} -eq 1 ]]; then
        CONTEXT_NAME="${KIND_CONTEXTS[0]}"
        # Extract cluster name from context (remove "kind-" prefix)
        CLUSTER_NAME="${CONTEXT_NAME#kind-}"
        print_info "Using cluster: $CONTEXT_NAME"
    else
        read -p "🏷️  Enter cluster number (default: 1): " CLUSTER_CHOICE
        CLUSTER_CHOICE="${CLUSTER_CHOICE:-1}"
        
        # Check if input is a number
        if [[ "$CLUSTER_CHOICE" =~ ^[0-9]+$ ]]; then
            idx=$((CLUSTER_CHOICE - 1))
            if [[ $idx -ge 0 && $idx -lt ${#KIND_CONTEXTS[@]} ]]; then
                CONTEXT_NAME="${KIND_CONTEXTS[$idx]}"
                CLUSTER_NAME="${CONTEXT_NAME#kind-}"
            else
                print_error "Invalid cluster number"
                exit 1
            fi
        else
            print_error "Please enter a valid number"
            exit 1
        fi
        
        print_success "Selected cluster: $CONTEXT_NAME"
    fi
fi
echo

# Set kubectl context to the Kind cluster
echo "🔄 Setting kubectl context to $CONTEXT_NAME..."
kubectl config use-context "$CONTEXT_NAME"
echo

# Build and load Docker images
if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
    print_header "🐳 Building and Loading Docker Images"
    
    for DF in "${DOCKERFILES[@]}"; do
        DIR="$(dirname "$DF")"
        DIR_NAME="$(basename "$DIR")"
        
        # Determine service type (same logic as before)
        if grep -qi nginx "$DF" 2>/dev/null || grep -qi "EXPOSE 80" "$DF" 2>/dev/null; then
            SERVICE_TYPE="frontend"
        elif grep -qi python "$DF" 2>/dev/null || grep -qi flask "$DF" 2>/dev/null || grep -qi node "$DF" 2>/dev/null; then
            SERVICE_TYPE="backend"
        else
            SERVICE_TYPE="$DIR_NAME"
        fi
        
        IMAGE_NAME="${NAMESPACE}-${SERVICE_TYPE}:latest"
        
        echo "🔨 Building image: $IMAGE_NAME"
        echo "   📂 From: ${DIR#$ROOT_DIR/}"
        
        docker build -t "$IMAGE_NAME" "$DIR"
        
        if [[ $? -eq 0 ]]; then
            print_success "Built: $IMAGE_NAME"
            
            echo "📦 Loading image into Kind cluster '$CLUSTER_NAME'..."
            kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
            
            if [[ $? -eq 0 ]]; then
                print_success "Loaded: $IMAGE_NAME → kind-$CLUSTER_NAME"
            else
                print_error "Failed to load image into Kind cluster"
                exit 1
            fi
        else
            print_error "Failed to build image: $IMAGE_NAME"
            exit 1
        fi
        echo
    done
fi

# Deploy manifests to Kind cluster
print_header "📦 Deploying Manifests to Kubernetes"

# Create namespace first
echo "1️⃣  Creating namespace: $NAMESPACE"
kubectl apply -f "$K8S_OUT_DIR/namespace.yaml"
echo

# Deploy all other manifests
echo "2️⃣  Deploying resources..."
for manifest in "${MANIFESTS_CREATED[@]}"; do
    if [[ "$manifest" != "namespace.yaml" ]]; then
        echo "   📄 Applying: $manifest"
        kubectl apply -f "$K8S_OUT_DIR/$manifest" -n "$NAMESPACE"
    fi
done
echo

# Wait for deployments to be ready
if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
    echo "3️⃣  Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment --all -n "$NAMESPACE" 2>/dev/null || true
    echo
fi

# Show deployment status
print_header "📊 Deployment Status"
echo "Pods:"
kubectl get pods -n "$NAMESPACE"
echo
echo "Services:"
kubectl get svc -n "$NAMESPACE"
echo

# Show access instructions
print_header "✅ Deployment Complete!"
echo "📝 Next steps:"
echo
echo "1️⃣  View all resources:"
echo "   kubectl get all -n $NAMESPACE"
echo
echo "2️⃣  View pod logs:"
echo "   kubectl logs -n $NAMESPACE -l app=frontend --tail=50"
echo "   kubectl logs -n $NAMESPACE -l app=backend --tail=50"
echo
echo "3️⃣  Port-forward to access services:"
echo "   kubectl port-forward -n $NAMESPACE svc/${NAMESPACE}-frontend-service 8080:80"
echo "   kubectl port-forward -n $NAMESPACE svc/${NAMESPACE}-backend-service 5000:5000"
echo
echo "4️⃣  Access your application:"
echo "   Frontend: http://localhost:8080"
echo "   Backend:  http://localhost:5000"
echo