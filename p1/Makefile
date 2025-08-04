all : up

up : 
	vagrant up

re : clean all

rre : fclean all

clean :
	vagrant destroy -f

fclean : 
	rm -rf .vagrant
	vagrant destroy -f
	rm -rf "$(HOME)/VirtualBox VMs"
