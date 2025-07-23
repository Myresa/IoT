all : 
	./gitlab.sh
	./argocd.sh

p3 : 
	./p3.sh

clean : 
	k3d cluster delete gitlab
	k3d cluster delete argocluster
	rm -rf .git token 
	

re : clean all