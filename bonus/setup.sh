#!/bin/bash

# =============================================================================
# GitLab on K3d with ArgoCD Deployment Script
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly CLUSTER_NAME="gitlab"
readonly DOMAIN_NAME="ta.mere"
readonly EMAIL="lululadebrouille@example.com"
readonly METALLB_IP_RANGE="172.22.255.200-172.22.255.250"
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
    
    while ! curl -ksf "$url" >/dev/null 2>&1; do
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

extract_certificate_chain() {
    local domain=$1
    local output_file=$2
    
    log_info "Extracting complete certificate chain for $domain"
    
    # Get the complete certificate chain
    echo | openssl s_client -showcerts -servername "$domain" -connect "$domain:443" 2>/dev/null | \
        awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "$output_file"
    
    # Verify we got certificates
    if [ ! -s "$output_file" ]; then
        log_error "Failed to extract certificates for $domain"
        return 1
    fi
    
    local cert_count
    cert_count=$(grep -c "BEGIN CERTIFICATE" "$output_file")
    log_info "Extracted $cert_count certificate(s) from $domain"
    
    return 0
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
    
    log_info "Applying MetalLB configuration..."
    kubectl apply -f ./metallb-config.yaml
    
    log_success "MetalLB configured successfully"
}

install_gitlab() {
    print_step "3" "Installing GitLab"
    
    log_info "Creating GitLab namespace..."
    kubectl create namespace gitlab
    
    log_info "Adding GitLab Helm repository..."
    helm repo add gitlab https://charts.gitlab.io/
    helm repo update
    
    log_info "Installing GitLab..."
    helm install gitlab gitlab/gitlab \
        --namespace gitlab \
        --set global.hosts.domain="${DOMAIN_NAME}" \
        --set certmanager-issuer.email="${EMAIL}" \
        --set global.ingress.configureCertmanager=true \
        --set global.ingress.tls.enabled=true \
        --set nginx-ingress.enabled=true \
        --set global.externalIngress.class=nginx \
        --set gitlab-runner.install=false \
        --timeout 30m
    
    log_success "GitLab installation initiated"
}

configure_gitlab_ssl() {
    print_step "4" "Configuring GitLab SSL certificates"
    
    if ! grep -Eq "^127\.0\.0\.1[[:space:]]+gitlab\.${DOMAIN_NAME}" /etc/hosts; then
        echo -e "127.0.0.1       gitlab.${DOMAIN_NAME}" | sudo tee -a /etc/hosts
    fi

    log_info "Waiting for GitLab to be accessible..."
    wait_for_url "https://gitlab.${DOMAIN_NAME}"
    
    log_info "Extracting SSL certificate chain..."
    extract_certificate_chain "gitlab.${DOMAIN_NAME}" "gitlab-cert-chain.pem"
    
    log_info "Configuring Git client SSL trust..."
    mkdir -p ~/.certs
    cp gitlab-cert-chain.pem ~/.certs/
    git config --global http."https://gitlab.${DOMAIN_NAME}/".sslCAInfo ~/.certs/gitlab-cert-chain.pem
    
    log_success "SSL certificates configured for Git client"
}

setup_gitlab_project() {
    print_step "5" "Setting up GitLab project and repository"
    
    log_info "Starting SSH port forwarding..."
    kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &
    
    log_info "Generating GitLab access token..."
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n gitlab | grep toolbox | awk '{print $1}' | head -n1)
    
    kubectl exec -n gitlab -it -c toolbox "$toolbox_pod" -- \
        gitlab-rails runner "$(cat ./generateToken.rb)" | tr -d '\r' > token
    
    local token
    token=$(cat ./token)
    log_success "GitLab token generated"
    
    log_info "Cloning and setting up repository..."
    if [ -d "IoT-p3-lcamerly" ]; then
        rm -rf IoT-p3-lcamerly
    fi
    
    git clone https://github.com/Axiaaa/IoT-p3-lcamerly
    mv IoT-p3-lcamerly/* .
    rm -rf IoT-p3-lcamerly/
    
    log_info "Pushing code to GitLab repository..."
    git init --initial-branch=main
    git remote add origin "https://root:${token}@gitlab.${DOMAIN_NAME}/root/${PROJECT_NAME}.git"
    git add service.yaml deployement.yaml
    git commit -m "Initial commit"
    git push --set-upstream origin main
    
    log_success "GitLab project configured and code pushed"
}

setup_dns() {
    print_step "6" "Configuring DNS resolution"
    
    log_info "Applying DNS configuration..."
    kubectl apply -f configmap.yaml
    
    log_info "Restarting CoreDNS..."
    kubectl -n kube-system rollout restart deployment coredns
    
    log_success "DNS configuration applied"
}

install_argocd() {
    print_step "7" "Installing ArgoCD"
    
    log_info "Creating ArgoCD namespace..."
    kubectl create namespace argocd || true
    
    log_info "Applying ArgoCD manifests..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    log_info "Waiting for ArgoCD pods to be ready..."
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking ArgoCD pod status"
    
    while [[ $(kubectl get pods -n argocd -o json | jq '[.items[] | select(.status.phase=="Running" and ([.status.containerStatuses[]?.ready] | all))] | length') -lt 7 ]]; do
        echo -ne "."
        sleep 2
    done
    
    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}ArgoCD installed successfully${NC}"
}

configure_argocd_certificates() {
    print_step "8" "Configuring ArgoCD with SSL certificates"
    
    log_info "Extracting GitLab certificate chain for ArgoCD..."
    extract_certificate_chain "gitlab.${DOMAIN_NAME}" "gitlab-cert-chain.pem"
    
    log_info "Adding GitLab certificates to ArgoCD TLS storSe..."
    kubectl create configmap argocd-tls-certs-cm \
        --from-file="gitlab.${DOMAIN_NAME}"=gitlab-cert-chain.pem \
        -n argocd \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Configuring ArgoCD repository certificates..."
    # Get the certificate in the right format for ArgoCD
    csplit -s -f cert- gitlab-cert-chain.pem '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true
    
    if [ -f "cert-01" ] && [ -s "cert-01" ]; then
        mv cert-01 gitlab-server-cert.pem
    else
        cp gitlab-cert-chain.pem gitlab-server-cert.pem
    fi
    
    # Clean up split files
    rm -f cert-* 2>/dev/null || true
    
    log_info "Creating comprehensive certificate configuration for ArgoCD..."
    cat > argocd-certificate-config.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-tls-certs-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-tls-certs-cm
    app.kubernetes.io/part-of: argocd
data:
  "gitlab.${DOMAIN_NAME}": |
$(sed 's/^/    /' gitlab-cert-chain.pem)
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-ssh-known-hosts-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-ssh-known-hosts-cm
    app.kubernetes.io/part-of: argocd
data:
  ssh_known_hosts: |
    # GitLab SSH host key will be added here if needed
    gitlab.${DOMAIN_NAME} ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC...
EOF
    
    kubectl apply -f argocd-certificate-config.yaml
    
    log_info "Configuring ArgoCD repository server with certificate bundle..."
    kubectl patch deployment argocd-repo-server -n argocd --patch-file /dev/stdin << EOF
spec:
  template:
    spec:
      containers:
      - name: argocd-repo-server
        env:
        - name: SSL_CERT_FILE
          value: "/etc/ssl/certs/ca-certificates.crt:/app/config/tls/gitlab.${DOMAIN_NAME}"
        volumeMounts:
        - name: tls-certs
          mountPath: /app/config/tls
          readOnly: true
      volumes:
      - name: tls-certs
        configMap:
          name: argocd-tls-certs-cm
EOF
    
    log_info "Restarting ArgoCD components to load certificates..."
    kubectl rollout restart deployment argocd-repo-server -n argocd
    kubectl rollout restart deployment argocd-server -n argocd
    
    log_info "Waiting for ArgoCD rollouts to complete..."
    kubectl rollout status deployment argocd-repo-server -n argocd --timeout=300s
    kubectl rollout status deployment argocd-server -n argocd --timeout=300s
    
    # Clean up temporary files
    rm -f gitlab-cert-chain.pem gitlab-server-cert.pem argocd-certificate-config.yaml
    
    log_success "ArgoCD certificate configuration completed"
}

configure_argocd() {
    print_step "9" "Configuring ArgoCD application"
    
    configure_argocd_certificates
    
    log_info "Starting ArgoCD port forwarding..."
    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    sleep 10
    
    log_info "Retrieving ArgoCD admin password..."
    local password
    password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
    
    log_info "Logging into ArgoCD..."
    argocd login localhost:8080 --username admin --password "$password" --insecure
    
    log_info "Creating development namespace..."
    kubectl create namespace dev || true
    
    log_info "Creating ArgoCD application with secure certificate verification..."
    local token
    token=$(cat ./token)
    
    cat > argocd-app-secure.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: will42
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://root:${token}@gitlab.${DOMAIN_NAME}/root/${PROJECT_NAME}.git
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://gitlab.${DOMAIN_NAME}/root/${PROJECT_NAME}.git
  username: root
  password: ${token}
EOF
    
    kubectl apply -f argocd-app-secure.yaml
    
    sleep 5
    if kubectl get application will42 -n argocd >/dev/null 2>&1; then
        log_success "ArgoCD application created successfully with secure certificates"
    else
        log_error "Failed to create ArgoCD application"
        return 1
    fi
    
    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    rm -f argocd-app-secure.yaml
}

deploy_application() {
    print_step "10" "Deploying application"
    
    log_info "Ensuring SSH port forwarding is active..."
    kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &
    
    log_info "Checking ArgoCD application status..."
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Waiting for application recognition"
    
    local timeout=60
    local count=0
    
    while ! argocd app get will42 >/dev/null 2>&1; do
        echo -ne "."
        sleep 2
        count=$((count + 2))
        if [ $count -ge $timeout ]; then
            echo -e "\n${RED}${CROSS}${NC} ${WHITE}ArgoCD application not found after $timeout seconds${NC}"
            return 1
        fi
    done
    
    echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}Application recognized by ArgoCD${NC}"
    
    log_info "Syncing ArgoCD application..."
    argocd app sync will42
    
    log_info "Waiting for application pods to be ready..."
    echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking application deployment"
    
    timeout=300
    count=0
    while ! kubectl get pods -n dev 2>/dev/null | grep playground | grep Running >/dev/null 2>&1; do
        echo -ne "."
        sleep 5
        count=$((count + 5))
        if [ $count -ge $timeout ]; then
            echo -e "\n${YELLOW}⚠${NC} ${WHITE}Timeout waiting for application pods, checking status...${NC}"
            kubectl get pods -n dev 2>/dev/null || log_info "No pods found in dev namespace yet"
            break
        fi
        
        if [ $((count % 30)) -eq 0 ]; then
            echo -e "\n${BLUE}${GEAR}${NC} ${WHITE}Still waiting for application deployment... ($count/${timeout}s)${NC}"
            echo -ne "${BLUE}${GEAR}${NC} ${WHITE}Checking application deployment"
        fi
    done
    
    if kubectl get pods -n dev 2>/dev/null | grep playground | grep Running >/dev/null 2>&1; then
        echo -e "\n${GREEN}${CHECKMARK}${NC} ${WHITE}Application pods are running${NC}"
    else
        echo -e "\n${YELLOW}⚠${NC} ${WHITE}Application deployment may still be in progress${NC}"
    fi
}

display_access_info() {
    print_header "GitLab & ArgoCD Deployment Complete!"

    kubectl port-forward deployment/wil-playground -n dev 8888:8888 >/dev/null 2>&1 &
    kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    local argocd_password
    argocd_password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)
    
    local gitlab_password
    gitlab_password=$(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 --decode)
    
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}ArgoCD is available at:${NC} ${CYAN}https://localhost:8080${NC}"
    echo -e "   ${CYAN}Username:${NC} ${WHITE}admin${NC}"
    echo -e "   ${CYAN}Password:${NC} ${WHITE}$argocd_password${NC}"
    echo ""
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}GitLab is available at:${NC} ${CYAN}https://gitlab.${DOMAIN_NAME}${NC}"
    echo -e "   ${CYAN}Username:${NC} ${WHITE}root${NC}"
    echo -e "   ${CYAN}Password:${NC} ${WHITE}$gitlab_password${NC}"
    echo ""
    echo -e "${GREEN}${CHECKMARK}${NC} ${WHITE}Application is available at:${NC} ${CYAN}http://localhost:8888${NC}"
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════${NC}"
}

# -----------------------------------------------------------------------------
# Main Script Execution
# -----------------------------------------------------------------------------
main() {
    # Set up cleanup on script exit
    trap cleanup_on_exit EXIT INT TERM
    
    print_header "GitLab on K3d with ArgoCD"
    
    log_info "Starting secure GitLab on K3d deployment script"
    
    create_k3d_cluster
    setup_metallb
    install_gitlab
    configure_gitlab_ssl
    setup_gitlab_project
    setup_dns
    install_argocd
    configure_argocd
    deploy_application
    display_access_info
    
    log_success "Deployment completed successfully!"
}

# Run main function
main "$@"