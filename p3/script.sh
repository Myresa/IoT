#!/bin/bash

# Colors for beautiful output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Unicode symbols for visual appeal
readonly CHECKMARK="✓"
readonly CROSS="✗"
readonly ARROW="→"
readonly STAR="★"
readonly GEAR="⚙"

# Logging functions
log_info() {
    echo -e "${BLUE}${GEAR}${NC} ${WHITE}$1${NC}"
}

log_success() {
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} ${WHITE}$1${NC}"
}

log_error() {
    echo -e "${RED}${CROSS}${NC} ${WHITE}$1${NC}"
}

print_header() {
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}${STAR}${NC} ${WHITE}$1${NC} ${PURPLE}${STAR}${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "\n${CYAN}${ARROW} Step $1: ${WHITE}$2${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────${NC}"
}

# Main script execution
main() {
    print_header "ArgoCD Cluster Setup & Deployment"
    
    # Step 1: Create k3d cluster
    print_step "1" "Creating k3d cluster with 2 agents"
    log_info "Creating cluster 'argocluster'..."
    k3d cluster create argocluster --agents 2
    log_success "Cluster created successfully"
    
    # Step 2: Setup ArgoCD namespace
    print_step "2" "Setting up ArgoCD namespace"
    log_info "Creating argocd namespace..."
    kubectl create namespace argocd >/dev/null 2>&1 || log_warning "Namespace 'argocd' already exists"
    
    # Step 3: Install ArgoCD
    print_step "3" "Installing ArgoCD components"
    log_info "Applying ArgoCD manifests..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    log_success "ArgoCD manifests applied"
    
    # Step 4: Wait for ArgoCD pods
    print_step "4" "Waiting for ArgoCD pods to be ready"
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking pod status"
    
    while [[ $(kubectl get pods -n argocd -o json | jq '[.items[] | select(.status.phase=="Running" and ([.status.containerStatuses[]?.ready] | all))] | length') -lt 7 ]]; do
        echo -ne "."
        sleep 2
    done
    
    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}All ArgoCD pods are ready!${NC}"
    
    # Step 5: Setup port forwarding and authentication
    print_step "5" "Configuring ArgoCD access"
    log_info "Starting port forwarding for ArgoCD server..."
    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    sleep 1
    
    log_info "Retrieving admin password..."
    PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
    
    log_info "Logging into ArgoCD..."
    argocd login localhost:8080 --username admin --password "$PASSWORD" --insecure
    log_success "Successfully logged into ArgoCD"
    
    # Step 6: Create development namespace
    print_step "6" "Setting up development environment"
    log_info "Creating dev namespace..."
    kubectl create namespace dev >/dev/null 2>&1 || log_warning "Namespace 'dev' already exists"
    
    # Step 7: Create and sync ArgoCD application
    print_step "7" "Deploying application via ArgoCD"
    log_info "Creating ArgoCD application 'will42'..."
    argocd app create will42 \
        --repo https://github.com/Axiaaa/IoT-p3-lcamerly \
        --path . \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace dev \
        --sync-policy automated
    
    log_info "Syncing application..."
    argocd app sync will42
    log_success "Application created and synced"
    
    # Step 8: Wait for application deployment
    print_step "8" "Waiting for application pods to be ready"
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking application status"
    
    while kubectl get pods -n dev | grep playground | grep -v Running >/dev/null 2>&1; do
        echo -ne "."
        sleep 2
    done
    
    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}Application is running!${NC}"
    
    # Step 9: Setup application port forwarding
    print_step "9" "Starting application port forwarding"
    log_info "Forwarding application traffic..."
    kubectl port-forward deployment/playground -n dev 8888:8888 >/dev/null 2>&1 &
    log_success "Port forwarding active"
    
    # Final success message
    print_header "Deployment Complete!"
    
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}ArgoCD is available at:${NC} ${CYAN}https://localhost:8080${NC}"
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}Application is available at:${NC} ${CYAN}http://localhost:8888${NC}"
    echo ""
    echo -e "${YELLOW}${STAR}${NC} ${WHITE}ArgoCD Login Credentials:${NC}"
    echo -e "   ${CYAN}Username:${NC} ${WHITE}admin${NC}"
    echo -e "   ${CYAN}Password:${NC} ${WHITE}$PASSWORD${NC}"
    echo ""
    echo -e "${YELLOW}${STAR}${NC} ${WHITE}Current version of the app${NC}"
    echo -e "${CYAN}${curl http://localhost:8888 | jq '.message'}${NC}"
}

# Execute main function
main "$@"