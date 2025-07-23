#!/bin/bash

CLUSTER_NAME="gitlab"
DOMAIN_NAME="ta.mere"
EMAIL="lululadebrouille@example.com"
METALLB_IP_RANGE="172.22.255.200-172.22.255.250"
PROJECT_NAME="lcamerly-p3-app"
SSH_KEY_TITLE="AutoAddedKey-$(date +%s)"
PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"

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



echo "✅ GitLab is deploying..."
while ! curl -ksf https://gitlab.${DOMAIN_NAME} >/dev/null 2>&1; do
  sleep 5
done
echo | openssl s_client -showcerts -servername gitlab.ta.mere -connect gitlab.ta.mere:443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > gitlab-ta-mere.pem
mkdir -p ~/.certs
cp gitlab-ta-mere.pem ~/.certs/
git config --global http."https://gitlab.ta.mere/".sslCAInfo ~/.certs/gitlab-ta-mere.pem
rm gitlab-ta-mere.pem

kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &

kubectl exec -n gitlab -it -c toolbox "$(kubectl get pods -n gitlab | grep toolbox | cut -d ' ' -f1)" -- gitlab-rails runner "$(cat ./generateToken.rb)" | tr -d '\r' >token

TOKEN="$(cat ./token)"

git clone https://github.com/Axiaaa/IoT-p3-lcamerly
mv IoT-p3-lcamerly/* .
rf -fr IoT-p3-lcamerly/
git init --initial-branch=main
git remote add origin https://root:$TOKEN@gitlab.ta.mere/root/lcamerly-p3-app.git
git add service.yaml deployement.yaml
git commit -m "Initial commit"
git push --set-upstream origin main

k3d cluster create argocluster --agents 2

kubectl apply -f configmap.yaml
kubectl -n kube-system rollout restart deployment coredns

kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for all ArgoCD pods to be ready..."
while [[ $(kubectl get pods -n argocd -o json | jq '[.items[] | select(.status.phase=="Running" and ([.status.containerStatuses[]?.ready] | all))] | length') -lt 7 ]]; do
  sleep 2
  echo "Waiting..."
done

kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
sleep 1

PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)

argocd login localhost:8080 --username admin --password "$PASSWORD" --insecure

kubectl create namespace dev || true

echo | openssl s_client -showcerts -connect gitlab.ta.mere:443 | \
  sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > gitlab-lcamerly.pem

argocd cert add-tls gitlab.ta.mere --from gitlab-lcamerly.pem
kubectl -n argocd rollout restart deployment argocd-repo-server
rm gitlab-lcamerly.pem

argocd app create will42 \
  --repo https://root:$(cat ./token)@gitlab.ta.mere/root/lcamerly-p3-app.git \
  --insecure \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace dev \
  --sync-policy automated


kubectl port-forward svc/gitlab-nginx-ingress-controller -n gitlab 2222:22 >/dev/null 2>&1 &

argocd app sync will42

echo "Waiting for the application to be ready..."
while kubectl get pods -n dev | grep playground | grep -v Running; do
  sleep 2
done

kubectl port-forward deployment/playground -n dev 8888:8888 >/dev/null 2>&1 &


echo "You can view the application in ArgoCD at https://localhost:8080"
echo "You can log in to ArgoCD with the following credentials:"
echo "Username: admin"
echo "Password: $PASSWORD"
echo "🌐 Access Gitlab at https://gitlab.${DOMAIN_NAME}"
echo "Username : root ; Password : $(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 --decode)"
