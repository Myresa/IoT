#!/bin/bash    print_step "3" "Installing GitLab"
    
k3d cluster create --agent 2 

kubectl create namespace gitlab

helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm install gitlab gitlab/gitlab \
    --namespace gitlab \
    -f gitlab.yaml \
    --timeout 30m
    # --set global.hosts.domain="${DOMAIN_NAME}" \
    # --set certmanager-issuer.email="${EMAIL}" \
    # --set nginx-ingress.enabled=true \
    # --set global.externalIngress.class=nginx \
    # --set gitlab-runner.install=false \
