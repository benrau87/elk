#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
dir=$PWD

##Logging setup
logfile=/var/log/elk_install.log
mkfifo ${logfile}.pipe
tee < ${logfile}.pipe $logfile &
exec &> ${logfile}.pipe
rm ${logfile}.pipe

##Functions
function print_status ()
{
    echo -e "\x1B[01;34m[*]\x1B[0m $1"
}

function print_good ()
{
    echo -e "\x1B[01;32m[*]\x1B[0m $1"
}

function print_error ()
{
    echo -e "\x1B[01;31m[*]\x1B[0m $1"
}

function print_notification ()
{
	echo -e "\x1B[01;33m[*]\x1B[0m $1"
}

function error_check
{

if [ $? -eq 0 ]; then
	print_good "$1 successfully."
else
	print_error "$1 failed. Please check $logfile for more details."
exit 1
fi

}

function install_packages()
{

apt-get update &>> $logfile && apt-get install -y --allow-unauthenticated ${@} &>> $logfile
error_check 'Package installation completed'

}

function dir_check()
{

if [ ! -d $1 ]; then
	print_notification "$1 does not exist. Creating.."
	mkdir -p $1
else
	print_notification "$1 already exists. (No problem, We'll use it anyhow)"
fi

}

########################################
##BEGIN MAIN SCRIPT##
#Pre checks: These are a couple of basic sanity checks the script does before proceeding.
print_status "OS Version Check.."
release=`lsb_release -r|awk '{print $2}'`
if [[ $release == "16."* ]]; then
	print_good "OS is Ubuntu. Good to go."
else
    print_notification "This is not Ubuntu 16.x, this autosnort script has NOT been tested on other platforms."
	print_notification "You continue at your own risk!(Please report your successes or failures!)"
fi


echo -e "${YELLOW} What would you like your Kibana username to be?${NC}"
read kibanauser
echo "What is the IP or Hostname of your Logstash server?"
read IP

print_status "${YELLOW}Adding repos${NC}"
add-apt-repository -y ppa:webupd8team/java &>> $logfile
wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch |  apt-key add - &>> $logfile
echo "deb http://packages.elastic.co/elasticsearch/2.x/debian stable main" | sudo tee -a /etc/apt/sources.list.d/elasticsearch-2.x.list &>> $logfile
echo "deb http://packages.elastic.co/kibana/4.6/debian stable main" | sudo tee -a /etc/apt/sources.list.d/kibana-4.6.x.list &>> $logfile
echo 'deb http://packages.elastic.co/logstash/2.4/debian stable main' | sudo tee -a /etc/apt/sources.list.d/logstash-2.4.x.list &>> $logfile
error_check 'Repos added'

##Holding pattern for dpkg...
print_status "${YELLOW}Waiting for dpkg process to free up...${NC}"
print_status "${YELLOW}If this takes too long try running ${RED}sudo rm -f /var/lib/dpkg/lock${YELLOW} in another terminal window.${NC}"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
   sleep 1
done
print_status "${YELLOW}Performing apt-get update and upgrade (May take a while if this is a fresh install)..${NC}"
apt-get update &>> $logfile && apt-get -y upgrade &>> $logfile
error_check 'Updated system'

##Holding pattern for dpkg...
print_status "${YELLOW}Waiting for dpkg process to free up...${NC}"
print_status "${YELLOW}If this takes too long try running ${RED}sudo rm -f /var/lib/dpkg/lock${YELLOW} in another terminal window.${NC}"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
   sleep 1
done
print_status "${YELLOW}Upgrading PIP${NC}"
pip install --upgrade pip &>> $logfile
error_check 'PIP upgraded'

print_status "${YELLOW}Installing Java${NC}"
echo debconf shared/accepted-oracle-license-v1-1 select true | \
  sudo debconf-set-selections &>> $logfile
apt-get install oracle-java8-installer -y &>> $logfile
error_check 'Java Installed'

##Holding pattern for dpkg...
print_status "${YELLOW}Waiting for dpkg process to free up...${NC}"
print_status "${YELLOW}If this takes too long try running ${RED}sudo rm -f /var/lib/dpkg/lock${YELLOW} in another terminal window.${NC}"
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
   sleep 1
done
print_status "${YELLOW}Installing dependecies${NC}"
apt-get -qq install ctags curl git vim vim-doc vim-scripts exfat-fuse exfat-utils zip unzip python-virtualenv geoip-database-contrib jq elasticsearch kibana nginx apache2-utils logstash -y &>> $logfile
error_check 'Dependencies installed'

print_status "${YELLOW}Installing tshark${NC}"
DEBIAN_FRONTEND=noninteractive apt-get -y install tshark &>> $logfile
error_check 'Dependencies tshark'

###Start services
print_status "${YELLOW}Configuring startups for ELK stack${NC}"
update-rc.d elasticsearch defaults 95 10 &>> $logfile
systemctl enable elasticsearch.service &>> $logfile
service elasticsearch start &>> $logfile
sleep 2
update-rc.d logstash 95 10 &>> $logfile
systemctl enable logstash.service &>> $logfile
service logstash start &>> $logfile
sleep 2
echo "server.host: 127.0.0.1" | tee -a /opt/kibana/config/kibana.yml  &>> $logfile
update-rc.d kibana defaults 95 10 &>> $logfile
systemctl enable kibana.service &>> $logfile
service kibana start &>> $logfile
sleep 2
error_check 'Services started'

###Config
htpasswd -c /etc/nginx/htpasswd.users $kibanauser &>> $logfile

#####Creates site default file
print_status "${YELLOW}Doing a lot of setup...${NC}"
mv /etc/nginx/sites-available/default /etc/nginx/ &>> $logfile
cp $dir/lib/default /etc/nginx/sites-available/ &>> $logfile
service nginx restart &>> $logfile
sleep 2
###Create Certs
mkdir -p /etc/pki/tls/certs &>> $logfile
mkdir /etc/pki/tls/private &>> $logfile
cd /etc/pki/tls; sudo openssl req -subj '/CN=ELK_Server/' -x509 -days 3650 -batch -nodes -newkey rsa:2048 -keyout private/logstash-forwarder.key -out certs/logstash-forwarder.crt &>> $logfile
###Setup Beats for Logstash input to Elastisearch output
cp $dir/logstash_conf/default/*.conf /etc/logstash/conf.d/ &>> $logfile
###Install netflow dashboards for Kibana
cd  $dir
curl -L -O https://download.elastic.co/beats/dashboards/beats-dashboards-1.1.0.zip &>> $logfile
/opt/logstash/bin/plugin install logstash-input-beats &>> $logfile
sleep 2
unzip beats-dashboards-*.zip &>> $logfile
cd beats-dashboards-* &>> $logfile
./load.sh &>> $logfile
echo


##############
##Put beats configuration here
##############


bash $dir/supporting_scripts/ELK_reload.sh &>> $logfile
mkdir /$HOME/clientinstall.$HOSTNAME &>> $logfile
cp -r $dir/beats/packetbeat/ /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
cp -r $dir/beats/filebeat/ /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
cp -r $dir/beats/metricbeat/ /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
cp -r $dir/beats/topbeat/ /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
cp -r $dir/beats/winlogbeat/ /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
cp /etc/pki/tls/certs/logstash-forwarder.crt /$HOME/clientinstall.$HOSTNAME/ &>> $logfile
bash $dir/supporting_scripts/sof-elk_setup.sh &>> $logfile
bash $dir/supporting_scripts/test.sh &>> $logfile
bash $dir/supporting_scripts/ELK_reload.sh &>> $logfile
echo
echo
echo "Your ELK stack has been installed, client installations are located in your home folder called clientinstall.$HOSTNAME"
echo
echo "Your Kibana dashboard is at $HOSTNAME:88"
echo
echo "If you need to configure packetbeat, you will need to modify the yml file by replacing the server:5044 with the logstash server host/ip. You will also need to install the included .crt for the client to use."
echo

