#!/bin/bash

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
