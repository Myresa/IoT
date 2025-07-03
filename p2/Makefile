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