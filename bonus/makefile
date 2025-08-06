TEMPLATE_DIR = template
OUTPUT_DIR = confs
ARGO_HOST=argocd.selfhosted
BONJOUR=ceci
METALLB_IP_RANGE="172.22.255.200-172.22.255.250"

all : setup 

setup : conf-generation
	./scripts/setup.sh

conf-generation:
	./scripts/generate-configuration.sh $(TEMPLATE_DIR) $(OUTPUT_DIR) \
	ARGO_HOST=$(ARGO_HOST) \
	BONJOUR=$(BONJOUR) \
	METALLB_IP_RANGE=$(METALLB_IP_RANGE)


port-forward :
		kubectl port-forward deployment/wil-playground -n dev 8888:8888 >/dev/null 2>&1 &

clean : 
	k3d cluster delete gitlab
	k3d cluster delete argocd-cluster
	docker system prune -f --volumes
	rm -rf .git token IoT-p3-lcamerly deployement.yaml service.yaml

re : clean all

all : conf-generation
	./script/script.sh

clone : 
	https://github.com/Axiaaa/IoT-p3-lcamerly

