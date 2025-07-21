all : 
	./script.sh

p3 : 
	./p3.sh

clean : 
	k3d cluster delete gitlab
	k3d cluster delete argocluster

re : clean all