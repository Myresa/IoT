ARGO_HOST = argocd.selfhosted
TEMPLATE_DIR = template
OUTPUT_DIR = conf

all : conf-generation
	./script/script.sh

clean : 
	k3d cluster delete argocluster

re : clean all

clone : 
	https://github.com/Axiaaa/IoT-p3-lcamerly

conf-generation:
	./script/generate-configuration.sh $(TEMPLATE_DIR) $(OUTPUT_DIR) ARGO_HOST=$(ARGO_HOST) 
