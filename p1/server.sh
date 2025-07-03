#Install curl 
set -e
apt-get update && apt-get install curl -y

# K3s Configuration
export INSTALL_K3S_VERSION="v1.28.7+k3s1"
export K3S_KUBECONFIG_MODE="644"
export INSTALL_K3S_EXEC="--flannel-iface=eth1"

#Install K3s server
curl -sfL https://get.k3s.io | sh -

#Make the auth token available for worker nodes
cp /var/lib/rancher/k3s/server/token /vagrant/token

# wait for node to be ready
until kubectl get nodes | grep -q " Ready"; do
    echo "Waiting for node to be ready..."
    sleep 2
done
