#!/bin/bash
# =============================================================================
# GitLab on K3d with ArgoCD Deployment Script 
# =============================================================================
set -euo pipefail  # Exit on error, undefined vars, pipe failures

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly CLUSTER_NAME="gitlab"
readonly DOMAIN_NAME="sara.croche"
readonly EMAIL="lululadebrouille@example.com"
readonly PROJECT_NAME="lcamerly-p3-app"
readonly SSH_KEY_TITLE="AutoAddedKey-$(date +%s)"
readonly PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"

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

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
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

wait_for_url() {
    local url=$1
    local timeout=${2:-900}
    local count=0
    
    log_info "Waiting for $url to be accessible..."
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking URL status"
    
    while ! curl -sf "$url" >/dev/null 2>&1; do
        echo -ne "."
        sleep 5
        count=$((count + 5))
        if [ $count -ge $timeout ]; then
            echo -e "\n${RED}${CROSS}${NC} ${WHITE}Timeout waiting for $url${NC}"
            return 1
        fi
        if [ $((count % 30)) -eq 0 ]; then
            echo -e "\n${BLUE}${GEAR}${NC} ${WHITE}Still waiting... ($count/${timeout}s)${NC}"
            echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking URL status"
        fi
        
        if kubectl get pods -n "$CLUSTER_NAME" | grep -qE "ErrImagePull"; then
            echo -e "\n${RED}${CROSS}${NC} ${WHITE}Error while pulling image${NC}"
        fi
    done
    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}$url is now accessible${NC}"
}

wait_for_pods() {
    local namespace=$1
    local timeout=$2
    
    log_info "Waiting for pods in namespace '$namespace' to be ready..."
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking pod status"
    
    if ! kubectl wait --namespace "$namespace" --for=condition=Ready pods --all --timeout="${timeout}s"; then
        log_error "Timeout waiting for pods in namespace '$namespace'"
        return 1
    fi
    log_success "All pods in namespace '$namespace' are ready"

    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}All pods in namespace '$namespace' are ready${NC}"
}

cleanup_on_exit() {
    log_warning "Script interrupted. Cleaning up background processes..."
    jobs -p | xargs -r kill 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Main Functions
# -----------------------------------------------------------------------------
create_k3d_cluster() {
    print_step "1" "Creating K3d cluster '$CLUSTER_NAME'"
    
    log_info "Setting up k3d cluster with load balancer and port forwarding..."
    k3d cluster create "${CLUSTER_NAME}" \
        -p "80:80@loadbalancer" \
        -p "443:443@loadbalancer" \
        -p "88:88@loadbalancer" \
        -p "2222:2222@server:0" \
        --agents 2 \
        --k3s-arg "--disable=traefik@server:*"
    
    log_success "K3d cluster created successfully"
}

setup_metallb() {
    print_step "2" "Setting up MetalLB load balancer"
    
    log_info "Installing MetalLB manifests..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
    log_info "Waiting for MetalLB pods to be ready..."
    wait_for_pods "metallb-system" 90
    log_info "Creating MetalLB configuration..."
    kubectl apply -f confs/metallb-config.yaml
    log_success "MetalLB configured successfully"
}

install_gitlab() {
    print_step "3" "Installing GitLab"
    
    log_info "Creating GitLab namespace..."
    kubectl create namespace gitlab
    
    log_info "Adding GitLab Helm repository..."
    helm repo add gitlab https://charts.gitlab.io/
    helm repo update
    
    log_info "Creating GitLab configuration..."
    
    log_info "Installing GitLab with configuration..."
    helm install gitlab gitlab/gitlab \
        --namespace gitlab \
        -f ./confs/gitlab.yaml \
        --set global.hosts.domain=${DOMAIN_NAME} \
        --timeout 30m
    
    log_success "GitLab installation initiated"
}

setup_gitlab_project() {
    print_step "4" "Setting up GitLab project and repository"
    
    if ! grep -Eq "^127\.0\.0\.1[[:space:]]+gitlab\.${DOMAIN_NAME}" /etc/hosts; then
        echo -e "127.0.0.1       gitlab.${DOMAIN_NAME}" | sudo tee -a /etc/hosts
    fi
    
    log_info "Waiting for GitLab to be accessible via HTTP..."
    wait_for_url "http://gitlab.${DOMAIN_NAME}"
    
    log_info "Starting SSH port forwarding..."
    kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &
    
    log_info "Generating GitLab access token..."
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n gitlab | grep toolbox | awk '{print $1}' | head -n1)
    kubectl exec -n gitlab -it -c toolbox "$toolbox_pod" -- \
        gitlab-rails runner "$(cat ./scripts/generatetoken.rb)" | tr -d '\r' > token
    
    local token
    token=$(cat ./token)
    log_success "GitLab token generated"
    
    export GITLAB_IP=$(kubectl get svc -n gitlab gitlab-nginx-ingress-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    export REPO_URL="http://root:${token}@gitlab.${DOMAIN_NAME}/root/${PROJECT_NAME}.git"

    echo -e $REPO_URL

    log_info "Cloning and setting up repository..."
    if [ -d "IoT-p3-lcamerly" ]; then
        rm -rf IoT-p3-lcamerly
    fi
    
    git clone https://github.com/Axiaaa/IoT-p3-lcamerly
    mv IoT-p3-lcamerly/* .
    rm -rf IoT-p3-lcamerly/ 
    
    log_info "Configuring Git for HTTP access..."
    git config --global http.sslVerify false
    
    log_info "Pushing code to GitLab repository via HTTP..."
    git init --initial-branch=main
    git remote add origin "http://root:${token}@gitlab.${DOMAIN_NAME}/root/${PROJECT_NAME}.git"
    git add service.yaml deployement.yaml
    git commit -m "Initial commit"
    git push --set-upstream origin main
    
    log_success "GitLab project configured and code pushed"

}

configure_map() {

    cat > coredns.yaml << EOF
EOF
    kubectl apply -f "coredns.yaml" -n kube-system
    kubectl rollout restart deployment coredns -n kube-system

    ./scripts/generate-configuration.sh template/coredns.yaml confs/ \
      GITLAB_IP=$GITLAB_IP \
      DOMAIN_NAME=$DOMAIN_NAME

    echo "CoreDNS updated for gitlab.$DOMAIN_NAME -> $GITLAB_IP"
}


install_argocd() {
    print_step "5" "Installing ArgoCD and configuring application deployment"

    log_info "Creating 'argocd' namespace..."
    kubectl create namespace argocd || log_warning "'argocd' namespace already exists"

    log_info "Deploying ArgoCD manifests..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    log_info "Waiting for ArgoCD pods to be ready..."
    wait_for_pods "argocd" 120

    log_info "Creating 'dev' namespace for application deployment..."
    kubectl create namespace dev || log_warning "'dev' namespace already exists"

    log_info "Adding Git repository to ArgoCD..."

    # We do a port-forward in background to access ArgoCD API locally
    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 5

    argocd login localhost:8080 --username admin --password "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)" --insecure

    argocd repo add $REPO_URL --insecure-skip-server-verification

    log_info "Creating ArgoCD application to deploy project in 'dev' namespace..."

    # Create ArgoCD application YAML manifest
    cat > argocd-app.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${PROJECT_NAME}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

    kubectl apply -f argocd-app.yaml

    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    log_success "ArgoCD installation and application setup complete"
    rm -f argocd-app.yaml

    print_step "6" "Waiting for application pods to be ready"
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking application status"
    
    while kubectl get pods -n dev | grep playground | grep -v Running >/dev/null 2>&1; do
        echo -ne "."
        sleep 2
    done
    
    kubectl port-forward deployment/wil-playground -n dev 8888:8888 >/dev/null 2>&1 &

}


display_access_info() {
    print_header "GitLab & ArgoCD Deployment Complete!"


    local argocd_password
    argocd_password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)
    
    local gitlab_password
    gitlab_password=$(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 --decode)
    
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}ArgoCD is available at:${NC} ${CYAN}http://127.0.0.1:8080${NC}"
    echo -e "   ${CYAN}Username:${NC} ${WHITE}admin${NC}"
    echo -e "   ${CYAN}Password:${NC} ${WHITE}$argocd_password${NC}"
    echo ""
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}GitLab is available at:${NC} ${CYAN}http://gitlab.${DOMAIN_NAME}${NC}"
    echo -e "   ${CYAN}Username:${NC} ${WHITE}root${NC}"
    echo -e "   ${CYAN}Password:${NC} ${WHITE}$gitlab_password${NC}"
    echo ""
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}Application is available at:${NC} ${CYAN}http://127.0.0.1:8888${NC}"
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════${NC}"
}

# -----------------------------------------------------------------------------
# Main Script Execution
# -----------------------------------------------------------------------------
main() {
    # Set up cleanup on script exit
    trap cleanup_on_exit INT TERM
    
    print_header "GitLab on K3d with ArgoCD"
    
    log_info "Starting GitLab on K3d deployment script"
    
    create_k3d_cluster
    setup_metallb
    install_gitlab
    setup_gitlab_project
    configure_map
    install_argocd
    display_access_info
    
    log_success "Deployment completed successfully!"
}

# Run main function
main "$@"
