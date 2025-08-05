all : setup port-forward

setup : 
	./scripts/setup.sh

port-forward :
		kubectl port-forward deployment/wil-playground -n dev 8888:8888 >/dev/null 2>&1 &

clean : 
	k3d cluster delete gitlab
	k3d cluster delete argocd-cluster
	docker system prune -f --volumes
	rm -rf .git token IoT-p3-lcamerly deployement.yaml service.yaml

re : clean all