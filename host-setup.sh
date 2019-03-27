#!/bin/bash

function display_syntax()
{
    echo -e "\nUsage: ./host-setup.sh [-t|-g]\n\n-t:    execute from downloaded tarball\n-g:    execute connected to project github"
}

function set_sensor_interface()
{
    if [ ! -f /etc.network/interfaces.bak ]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak
    fi
    sensorIP=""
    sensorSubnet=""
    sensorGW=""
    sensorDNS=""
    while true; do
        read -p "Please enter an ip address for $1: " sensorIP
        read -p "Please enter a subnet mask for $1: " sensorSubnet
        read -p "Please enter a default gateway for $1: " sensorGW
        read -p "Please enter a DNS server for $1: " sensorDNS
        echo -e "\n\nSensor Interface will be $1\nIP: $sensorIP\nSubnet: $sensorSubnet\nGateway: $sensorGW\nDNS1: $sensorDNS"
        read -p "Do you want to continue and write these values? [yn]" yn
        case $yn in
            [Yy]* ) ifdown $1 && cat /etc/network/interfaces.bak > /etc/network/interfaces 2> /dev/null; echo -e "\nauto $1\niface $1 inet static\n  address $sensorIP\n  gateway $sensorGW\n  netmask $sensorSubnet\n  dns-nameservers $sensorDNS" >> /etc/network/interfaces; ifup $1; break;;
            [Nn]* ) set_sensor_interface $1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

#logstash modification plugin
function modify_logstash()
{
    #modify the logstash and get done
    if [ -d ./configs ]; then
        cd configs

        #copy template IOC files and plugin into directories
        cp -R ./ioc /
        chmod 777 /ioc

        #make changes to so-logstash-start
        sed 's|                        \$LOGSTASH_OPTIONS|                        --volume /ioc:/ioc \\\n                        \$LOGSTASH_OPTIONS|g' /usr/sbin/so-logstash-start

        #restart logstash and wait for changes
        restart_logstash()

        #install prune plugin from docker command
        echo "Installing prune plugin to logstash docker container"
        docker exec -u 0 -it so-logstash /opt/logstash/bin/logstash-plugin install file:///ioc/logstash-prune-xml.zip

        echo "Committing installation and running container snapshot"
        docker commit -m "installed prune plugin" so-logstash securityonionsolutions/so-logstash

        #restart logstash to make sure it comes up with the prune plugin
        restart_logstash

        #copy custom files into place to overwrite original files
        cp -Rf ./logstash/*  /etc/logstash/

        #grab master ip address from existing configs
        masterIP=grep SERVER_HOST /etc/nsm/$(hostname)-$1/http_agent.conf | awk '{print $NF}'

        #set elastic outputs in config files with masterIP
        sed -i "s/ipaddr/$masterIP/g" /etc/logstash/custom/995*-winevent*

        #commit new configs with snapshot and message
        docker commmit -m "copied configs into place for new mappings" so-logstash securityonionsolutions/so-logstash

        restart_logstash

        #get IP address to receive beats from
        read -p "Please enter subnet or ip to receive beats from: " beater
        sudo ufw allow tcp from $beater to any port 5044

        read -p "Please enter the username to connect to $masterIP: " masterUser
        echo "Connecting to $masterIP and running so-allow"
        echo "Please allow $1 to connect to $masterIP over Elastic REST API (9200), use the [e] option."
        echo "Enter the password for $masterUser on $masterIP"
        ssh $masterUser@$masterIP "so-allow"
    else
        echo "configs directory not found...exiting"
        exit 1
    fi
}

function restart_logstash()
{
    echo "Restarting logstash docker container."
    so-logstash-restart
    echo "Please wait for script to continue..."
    while [ -z $(so-logstash-status | grep \[OK\])
    do
        if [ ! -z "$(so-logstash-status | grep FAIL)" ]; then
            echo "Logstash has failed to start, plesae check /var/log/logstash/logstash.log for details and try again"
            exit 1
        else
            echo -ne "."
        fi
    done
    echo "Logstash successfully restarted. Now continuing."
}

#verify run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

#files should be extracted now
#identify interfaces
#first identify mgmtInterface
mgmtInterface=""
while true
do
    for interface in $(seq 1 1 $(ls /etc/nsm | grep $(hostname) | awk -F\- '{print $2}' | wc -l))
    do
        currInterface="$(ls /etc/nsm | grep $(hostname) | awk -F\- '{print $2}' | head -n$interface | tail -n1)"
        echo "[$interface] $currInterface"
    done
    read -p "Please identify your management interface from the list below:" mgmtNum
    mgmtInterface="$(ls /etc/nsm | grep $(hostname) | awk -F\- '{print $2}' | head -n$mgmtNum | tail -n1)"
    if [ ! -z "$(ls /etc/nsm | grep $(hostname)-$mgmtInterface)" ]; then
        break
    fi
done

#now identify sensor interface
sensorInterface=""
while true
do
    for interface in $(seq 1 1 $(ls /etc/nsm | grep $(hostname) | grep -v $mgmtInterface | awk -F\- '{print $2}' | wc -l))
    do
        currInterface="$(ls /etc/nsm | grep $(hostname) | grep -v $mgmtInterface | awk -F\- '{print $2}' | head -n$interface | tail -n1)"
        echo "[$interface] $currInterface"
    done
    read -p "Please identify your sensor interface from the list below:" sensorNum
    sensorInterface="$(ls /etc/nsm | grep $(hostname) | grep -v $mgmtInterface | awk -F\- '{print $2}' | head -n$sensorNum | tail -n1)"
    if [ ! -z "$(ls /etc/nsm | grep $(hostname)-$sensorInterface)" ]; then
        break
    fi
done

#apply user choices to networking files
set_sensor_interface $sensorInterface

#run logstash function for modifications
modify_logstash $mgmtInterface
