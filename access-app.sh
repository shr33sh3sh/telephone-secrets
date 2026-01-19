#!/bin/bash
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Starting port-forwarding for the frontend service...${NC}"
echo -e "${BLUE}You will be able to access the app at http://localhost:8888${NC}"
echo -e "${BLUE}Press Ctrl+C to stop.${NC}"

kubectl port-forward -n telephone-secrets service/frontend 8888:80 \
    --address 0.0.0.0
