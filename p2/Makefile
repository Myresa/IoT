all : up

up : 
	vagrant up

re : clean all

rre : fclean all

clean :
	vagrant destroy -f

fclean : 
	vagrant destroy -f 
	rm -rf .vagrant
	rm -rf "$(HOME)/VirtualBox VMs"

app1 : 
	curl -H "Host:app1.com" 192.168.56.110

app2 : 
	curl -H "Host:app2.com" 192.168.56.110

app3 : 
	curl -H "Host:app3.com" 192.168.56.110
