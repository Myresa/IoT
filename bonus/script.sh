#!/bin/bash

CLUSTER_NAME="gitlab"
DOMAIN_NAME="ta.mere"
EMAIL="lululadebrouille@example.com"
METALLB_IP_RANGE="172.22.255.200-172.22.255.250"

k3d cluster create ${CLUSTER_NAME} \
  -p "80:80@loadbalancer" \
  -p "443:443@loadbalancer" \
  -p "2222:2222@server:0" \
  --agents 2 \
  --k3s-arg "--disable=traefik@server:*"


kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml

echo "⏳ Waiting for MetalLB pods to be ready..."
kubectl wait --namespace metallb-system --for=condition=Ready pods --all --timeout=90s

kubectl apply -f ./metallb-config.yaml

kubectl create namespace gitlab

helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm install gitlab gitlab/gitlab \
    --namespace gitlab \
    --set global.hosts.domain=${DOMAIN_NAME} \
    --set certmanager-issuer.email=${EMAIL} \
    --set global.ingress.configureCertmanager=true \
    --set global.ingress.tls.enabled=true \
    --set nginx-ingress.enabled=true \
    --set global.externalIngress.class=nginx \
    --set gitlab-runner.install=false \
    --timeout 15m


kubectl get svc -n gitlab | grep nginx-ingress-controller

echo "✅ GitLab is deploying..."
while ! curl -ksf https://gitlab.${DOMAIN_NAME} >/dev/null 2>&1; do
  sleep 5
done
echo | openssl s_client -showcerts -servername gitlab.ta.mere -connect gitlab.ta.mere:443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > gitlab-ta-mere.pem
mkdir -p ~/.certs
cp gitlab-ta-mere.pem ~/.certs/
git config --global http."https://gitlab.ta.mere/".sslCAInfo ~/.certs/gitlab-ta-mere.pem
rm gitlab-ta-mere.pem
echo "🌐 Added certs to trusted autorities !"
echo "🌐 Access it after a few minutes at: https://gitlab.${DOMAIN_NAME}"
echo "Username : root ; Password : $(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 --decode)"

kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &
