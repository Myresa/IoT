all : 
	./scripts/setup.sh


clean : 
	k3d cluster delete gitlab
	k3d cluster delete argocd-cluster
	docker system prune -f --volumes
	rm -rf .git token IoT-p3-lcamerly deployement.yaml service.yaml

re : clean all