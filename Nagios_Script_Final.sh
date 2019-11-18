#To Setup the script:
#1. Setup SSH between Host and Monitoring
#2. Setup Auto Discovery script
#check current user by whoami
#check sudo privileges by sudo -v
#sed -i '/dont_blame_nrpe/c\dont_blame_nrpe=1' /usr/local/nagios/etc/nrpe.cfg

nagiosPlugin()
{
	#install Plugins
	cd /tmp
	wget https://nagios-plugins.org/download/nagios-plugins-2.2.1.tar.gz
	tar xzf nagios-plugins-2.2.1.tar.gz
	cd nagios-plugins-2.2.1
	./configure
	make
	make install
	ls /usr/local/nagios/libexec/
	echo "Nagios Plugins installed"
}

nagiosInstall()
{
	#checking nagios user exist 
	#cut -d: -f1 /etc/passwd | grep nagios
	echo -n "Enter Password for nagios user: "
	read -s password
	echo
	echo -n "Enter email for notification:"
	read email
	echo -n "Password for nagiosadmin: "
	read -s npasswd
	echo
	monitoringIP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)
	yum -y update
	yum -y install httpd php gcc glibc glibc-common gd gd-devel
	adduser -m nagios
	echo $password | passwd --stdin nagios
	groupadd nagcmd
	usermod -a -G nagcmd nagios
	usermod -a -G nagcmd apache
	cd /tmp
	wget https://assets.nagios.com/downloads/nagioscore/releases/nagios-4.4.5.tar.gz
	tar zxvf nagios-4.4.5.tar.gz
	cd nagios-4.4.5
	./configure --with-command-group=nagcmd
	make all
	make install
	make install-init
	make install-config
	make install-commandmode
	sed -i '/email/c\    email                   '$email' ; <<***** CHANGE THIS TO YOUR EMAIL ADDRESS ******' /usr/local/nagios/etc/objects/contacts.cfg
	make install-webconf
	htpasswd -b -c /usr/local/nagios/etc/htpasswd.users nagiosadmin $npasswd
	service httpd restart
	chkconfig nagios on
	/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
	nagiosPlugin
	systemctl start nagios
	echo "Nagios Monitoring server installed"
	echo "Please login to http://$monitoringIP/nagios"
}

nRPEPlugin()
{
	rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-6.noarch.rpm
	sudo yum install -y nagios-plugins-nrpe.x86_64 nrpe
	service nrpe start
	chkconfig nrpe on
	cat <<EOF >> /usr/local/nagios/etc/objects/commands.cfg
###############################################################################
# NRPE CHECK COMMAND
#
# Command to use NRPE to check remote host systems
###############################################################################

define command{
		command_name check_nrpe
		command_line \$USER1$/check_nrpe -H \$HOSTADDRESS$ -c \$ARG1$
		}
EOF
	cp /usr/lib64/nagios/plugins/check_nrpe /usr/local/nagios/libexec/
	echo "NRPE Plugin Installed"
	touch /usr/local/nagios/etc/hosts.cfg
	touch /usr/local/nagios/etc/services.cfg
	echo "cfg_file=/usr/local/nagios/etc/services.cfg" >>/usr/local/nagios/etc/nagios.cfg
	echo "cfg_file=/usr/local/nagios/etc/hosts.cfg" >>/usr/local/nagios/etc/nagios.cfg
	service nagios restart
}

nRPEAgent()
{
	echo "Enter IP of Host: "
	read hostIP
	echo "Enter Username for Host: "
	read hostName
	echo "Is current server the Monitoring Server? (y/n) :"
	read checkCurrentServer
	echo "Do you want to install Plugins? (y/n) :"
	read pluginInstall
	if [ $checkCurrentServer = "y" ]
	then
		monitoringIP=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)
	else
		echo "Enter the IP of Monitoring Server: "
		read monitoringIP
	fi
		
	ssh -T $hostName@$hostIP <<'ENDSSH'
yum install -y gcc glibc glibc-common openssl openssl-devel
cd /tmp
wget https://github.com/NagiosEnterprises/nrpe/releases/download/nrpe-3.2.1/nrpe-3.2.1.tar.gz 
tar zxvf nrpe-3.2.1.tar.gz
cd nrpe-3.2.1
./configure --enable-command-args --with-nrpe-user=nagios --with-nrpe-group=nagios 
make install-groups-users
id nagios
make all
make install
make install-config
make install-init
echo 'nrpe            5666/tcp                # NRPE Service' >> /etc/services

systemctl start nrpe
systemctl enable nrpe
systemctl enable nrpe



ENDSSH

	ssh $hostName@$hostIP "bash -c 'sed -i '/allowed_hosts=127.0.0.1/c\allowed_hosts=127.0.0.1,'$monitoringIP'' /usr/local/nagios/etc/nrpe.cfg;systemctl restart nrpe'"
#sed -i '/#server_address=127.0.0.1/c\server_address=127.0.0.1' /usr/local/nagios/etc/nrpe.cfg

	if [ $pluginInstall = "y" ]
	then
		ssh -T $hostName@$hostIP "$(typeset -f); nagiosPlugin"
	fi
}

pluginOnHost()
{
	echo "Enter IP of Host: "
	read hostIP
	echo "Enter Username for Host: "
	read hostName
	ssh -T $hostName@$hostIP "$(typeset -f); nagiosPlugin"
}
	
autoDiscovery()
{
	#yum install pip
	#yum install python2-pip.noarch
	#pip install boto
	#add template
	#change contact group in template or make ops contact group
	#add check commands in file
	cd /root/nagios-aws-autoconfig
	python nagios_aws_autoconfig.py
	cd /root/nagios-aws-autoconfig/nagios_config_dir/hosts
	for f in *; do (cat "${f}"; echo) >> hosts.cfg; done
	cat  /root/nagios-aws-autoconfig/nagios_templates_dir/common_host.template | cat - hosts.cfg > temp && mv -f temp hosts.cfg
	cd /root/nagios-aws-autoconfig/nagios_config_dir/services
	for f in *; do (cat "${f}"; echo) >> services.cfg; done
	cat /root/nagios-aws-autoconfig/nagios_templates_dir/common_service.template | cat - services.cfg > temp && mv -f temp services.cfg
	mv -f /root/nagios-aws-autoconfig/nagios_config_dir/hosts/hosts.cfg /usr/local/nagios/etc/hosts.cfg
	mv -f /root/nagios-aws-autoconfig/nagios_config_dir/services/services.cfg /usr/local/nagios/etc/services.cfg
	/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
	service nagios restart
	echo "Hosts and Services Updated"
}

clear

while :
do
 echo -ne "\n\n\n\tNagios Installation and Configuration Script\n\nWhat would you like to do? \n1. Install Nagios and Plugins \n2. Install NRPE Plugin \n3. Install NRPE Agent on Host \n4. Install Plugin on Host \n5. Run Auto Discovery \n6. Exit\nEnter a number: "
 read mainMenuOption
 case $mainMenuOption in
	1) 	nagiosInstall
		;;
	2)	nRPEPlugin
		;;
	3)	nRPEAgent
		;;
	4)	pluginOnHost
		;;
	5)	autoDiscovery
		;;
	6)	break
		;;
#	7)
#		;;
#	8)
#		;;
	*)	echo "Please enter a number between 1 and 6."
		read
		;;
 esac
 
 
done
clear
echo "Thank you for using Nagios Installation and Configuration Script"