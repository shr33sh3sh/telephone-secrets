#!/bin/bash
set -e

# Configuration
CLUSTER_NAME="staging-cluster"
BACKEND_IMAGE="phone-directory-backend:latest"
FRONTEND_IMAGE="phone-directory-frontend:latest"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for required tools
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in your PATH."
    exit 1
fi

if ! command -v kind &> /dev/null; then
    log_error "Kind is not installed or not in your PATH."
    exit 1
fi

# Function to build images
build_images() {
    log_info "Building Backend Image ($BACKEND_IMAGE)..."
    docker build -t "$BACKEND_IMAGE" ./backend

    log_info "Building Frontend Image ($FRONTEND_IMAGE)..."
    docker build -t "$FRONTEND_IMAGE" ./frontend
    
    log_info "Images built successfully."
}

# Function to create cluster
create_cluster() {
    log_info "Creating Kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME"
    log_info "Cluster '$CLUSTER_NAME' created."
}

# Check if cluster exists
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    log_info "Cluster '$CLUSTER_NAME' found."
else
    log_warn "Cluster '$CLUSTER_NAME' NOT found."
    read -p "Do you want to create the cluster '$CLUSTER_NAME'? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_cluster
    else
        log_info "Skipping cluster creation. Note: Loading images requires a running cluster."
    fi
fi

# Ask to build and load images
echo ""
read -p "Do you want to build and load images into '$CLUSTER_NAME'? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    
    # Build
    build_images

    # Load
    log_info "Loading Backend Image into '$CLUSTER_NAME'..."
    kind load docker-image "$BACKEND_IMAGE" --name "$CLUSTER_NAME"

    log_info "Loading Frontend Image into '$CLUSTER_NAME'..."
    kind load docker-image "$FRONTEND_IMAGE" --name "$CLUSTER_NAME"

    log_info "Images loaded successfully."
    
    echo ""
    log_info "You can now deploy your app using: kubectl apply -f kubernetes.yaml"
else
    log_info "Skipping build and load."
fi

log_info "Done."
