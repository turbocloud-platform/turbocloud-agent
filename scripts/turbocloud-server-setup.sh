#!/bin/bash

#Set default value for $HOME because it doesn't exist in cloudinit

DEFAULT_HOME='/root'
HOME=${HOME:-$DEFAULT_HOME}


url_download_vpn_certs=""
domain=""
token_to_generate_vpn_certs_url=""
webhook_url=""
agent_env="main"
tui_env="main"

while getopts j:d:k:h:a:t option
do
    case "${option}"
        in
        j)url_download_vpn_certs=${OPTARG};;
        d)domain=${OPTARG};;
        k)token_to_generate_vpn_certs_url=${OPTARG};;
        h)webhook_url=${OPTARG};;
        a)agent_env=${OPTARG};;
        t)tui_env=${OPTARG};;
    esac
done

server_ip="$(curl https://turbocloud.dev/ip)"
server_ip_without_dots="${server_ip//./-}"

if [ "$domain" = "" ]; then
    #Set automatic domain
    domain="l-$server_ip_without_dots.dns.turbocloud.dev"
fi

cd $HOME

#Download VPN certificates if requried
if [ "$url_download_vpn_certs" != "" ]; then
    wget $url_download_vpn_certs -O turbocloud-join-vpn.zip
fi

if [ "$url_download_vpn_certs" = "" ] && [ "$domain" = "" ]; then
  echo ""
  echo ""
  echo "==================================================================================="
  echo ""
  echo "No domain and no URL to join VPN is specified in the command."
  echo ""
  echo "Use 'curl https://turbocloud.dev/install | bash -s -- -d your_domain' to provision the first server in the project, where your_domain is, for example, turbocloud.domain.com; DNS A record for this domain name should be pointed to IP address of this server. The domain will be used for adding new servers/local machines and for deployment webhooks (for example, for deploying changes after you push code to GitHub/Bitbucket). "
  echo ""
  echo "Or use 'curl https://turbocloud.dev/install | bash -s -- -j url_to_join_project' to join the exiting TurboCloud project."
  echo ""
  echo "More information can be found at https://turbocloud.dev/docs"
  echo ""
  echo "==================================================================================="
  exit 1
fi

echo "Installing TurboCloud Agent ..."

#wait until another process are trying updating the system
while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do sleep 1; done
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done

#Disable "Pending kernel upgrade" message. OVH cloud instances show this message very often, for
sudo sed -i "s/#\$nrconf{kernelhints} = -1;/\$nrconf{kernelhints} = -1;/g" /etc/needrestart/needrestart.conf
sudo sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf

#Open only necessary ports
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 22
sudo ufw allow 9418
sudo ufw allow 4242
sudo ufw --force enable

#Install Docker
DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

#Set Docker with UFW
sudo wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
ufw-docker install
sudo systemctl restart ufw

sudo echo -e "{\"insecure-registries\" : [\"192.168.202.1:7000\"]}" >> /etc/docker/daemon.json
sudo systemctl restart docker


#echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
#echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
#DEBIAN_FRONTEND=noninteractive sudo apt-get -y install iptables-persistent

#Generate SSH keys
sudo ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

sudo ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts
sudo ssh-keyscan github.com >> ~/.ssh/known_hosts

#Note: Ubuntu 22.04 specific only
#Set DNS resolvers
sudo mkdir /etc/systemd/resolved.conf.d/
echo -e "[Resolve]\nDNS=8.8.8.8 208.67.222.222" | sudo tee /etc/systemd/resolved.conf.d/dns_servers.conf
sudo systemctl restart systemd-resolved

#Install Caddy Server
wget https://turbocloud.dev/caddy -O /usr/bin/caddy
chmod +x /usr/bin/caddy
sudo groupadd --system caddy
sudo useradd --system     --gid caddy     --create-home     --home-dir /var/lib/caddy     --shell /usr/sbin/nologin     --comment "Caddy web server"     caddy
wget https://raw.githubusercontent.com/caddyserver/dist/master/init/caddy.service -O /etc/systemd/system/caddy.service
mkdir /etc/caddy
echo "" >> /etc/caddy/Caddyfile

sudo systemctl daemon-reload
sudo systemctl enable --now caddy

#Download TLS certificates for the web console
#We need TLS certificates for private VPN IPs to make request over HTTPS
#ToDo: Upload certificates
#sudo wget https://turbocloud.dev/local_vpn_certificate -O /etc/ssl/vpn_fullchain.pem
#sudo wget https://turbocloud.dev/local_vpn_key -O /etc/ssl/vpn_private.key

cd $HOME

#Install Nebula

#Get architecture
OSArch=$(uname -m)
if [ "$OSArch" = "aarch64" ]; then
    wget https://github.com/slackhq/nebula/releases/download/v1.9.5/nebula-linux-arm64.tar.gz
    tar -xzf nebula-linux-arm64.tar.gz
    rm nebula-linux-arm64.tar.gz
else
    wget https://github.com/slackhq/nebula/releases/download/v1.9.5/nebula-linux-amd64.tar.gz
    tar -xzf nebula-linux-amd64.tar.gz
    rm nebula-linux-amd64.tar.gz
fi

sudo chmod +x nebula
sudo chmod +x nebula-cert

sudo mv nebula /usr/local/bin/nebula
sudo mv nebula-cert /usr/local/bin/nebula-cert
sudo mkdir /etc/nebula

#Install RQLite
curl -L https://github.com/rqlite/rqlite/releases/download/v8.31.3/rqlite-v8.31.3-linux-amd64.tar.gz -o rqlite-v8.31.3-linux-amd64.tar.gz
tar xvfz rqlite-v8.31.3-linux-amd64.tar.gz
cd rqlite-v8.31.3-linux-amd64
sudo chmod +x rqlited
mv rqlited /usr/local/bin/rqlited

cd $HOME
rm rqlite-v8.31.3-linux-amd64.tar.gz
rm -rf rqlite-v8.31.3-linux-amd64

#Install Go
sudo wget https://go.dev/dl/go1.22.6.linux-amd64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.6.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
rm go1.22.6.linux-amd64.tar.gz

#Clone and build TurboCloud agent
git clone -b $agent_env https://github.com/turbocloud-platform/turbocloud-agent.git
cd turbocloud-agent
go build
sudo chmod +x turbocloud-agent
mv turbocloud-agent /usr/local/bin/turbocloud-agent

cd $HOME
rm -rf turbocloud-agent

#Clone and build TurboCloud TUI
git clone -b $tui_env https://github.com/turbocloud-dev/turbocloud-cli.git
cd turbocloud-cli
go build -o turbocloud
sudo chmod +x turbocloud
mv turbocloud /usr/local/bin/turbocloud

cd $HOME
rm -rf turbocloud-cli

if [ "$url_download_vpn_certs" != "" ]; then

    echo "Downloading a zip archive with Nebula certificates"
    DEBIAN_FRONTEND=noninteractive  sudo apt-get install unzip
    unzip -o turbocloud-join-vpn.zip
    sudo mv config.yaml /etc/nebula/config.yaml
    sudo mv ca.crt /etc/nebula/ca.crt
    sudo mv host.crt /etc/nebula/host.crt
    sudo mv host.key /etc/nebula/host.key

    sudo rm turbocloud-join-vpn.zip

    sudo ufw allow from 192.168.202.0/24

    #Start Nebula
    sudo echo -e "[Unit]\nDescription=Nebula overlay networking tool\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target\nBefore=sshd.service" >> /etc/systemd/system/turbocloud-nebula.service
    sudo echo -e "[Service]\nSyslogIdentifier=nebula\nExecReload=/bin/kill -HUP $MAINPID\nExecStart=/usr/local/bin/nebula -config /etc/nebula/config.yaml\nRestart=always" >> /etc/systemd/system/turbocloud-nebula.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/turbocloud-nebula.service
    sudo systemctl enable turbocloud-nebula.service
    sudo systemctl start turbocloud-nebula.service

    #Parse machine details from a crt
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y jq
    json=$(nebula-cert print -json -path /etc/nebula/host.crt)
    name=$(echo "$json" | jq -r '.details.name')
    private_ip_mask=$(echo "$json" | jq -r '.details.ips[0]')
    secondString=""
    private_ip=$(echo "$private_ip_mask" | sed "s/\/24/$secondString/")


    #Install RQLite instance as a replica
    #Start RQLite
    sudo echo -e "[Unit]\nDescription=RQLite Agent\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target" >> /etc/systemd/system/rqlite-agent.service
    sudo echo -e "[Service]\nSyslogIdentifier=turbocloud-agent\nExecStart=/usr/local/bin/rqlited -node-id $name -raft-reap-node-timeout=30s -http-addr  $private_ip:4001 -raft-addr $private_ip:4002 -join 192.168.202.1:4002 $HOME/rqlite \nRestart=always" >> /etc/systemd/system/rqlite-agent.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/rqlite-agent.service
    sudo systemctl enable rqlite-agent.service
    sudo systemctl start rqlite-agent.service


    #We dont set a public domain for the non-first server now because the current version has just one load balancer and build machine
    #Will be improved in next versions

    #Start turbocloud-agent as systemd service
    sudo echo -e "[Unit]\nDescription=TurboCloud Agent\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target" >> /etc/systemd/system/turbocloud-agent.service
    sudo echo -e "[Service]\nSyslogIdentifier=turbocloud-agent\nExecStart=/usr/local/bin/turbocloud-agent \nRestart=always\n" >> /etc/systemd/system/turbocloud-agent.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/turbocloud-agent.service
    sudo systemctl enable turbocloud-agent.service
    sudo systemctl start turbocloud-agent.service

else

    echo "Generate new Nebula certificates"

    private_ip="192.168.202.1"
    name="lighthouse_1"

    sudo nebula-cert ca -name "TurboCloud" -duration 34531h

    sudo nebula-cert sign -name "$name" -ip "$private_ip/24"
    #nebula-cert sign -name "local_machine_1" -ip "192.168.202.2/24" -groups "devs"

    wget https://raw.githubusercontent.com/turbocloud-platform/turbocloud-agent/refs/heads/main/config/nebula_lighthouse_config.yaml -O lighthouse_config.yaml
    sed -i -e "s/{{lighthouse_ip}}/$server_ip/g" lighthouse_config.yaml

    wget https://raw.githubusercontent.com/turbocloud-platform/turbocloud-agent/refs/heads/main/config/nebula_node_config.yaml -O node_config.yaml
    sed -i -e "s/{{lighthouse_ip}}/$server_ip/g" node_config.yaml

    sudo mv lighthouse_config.yaml /etc/nebula/config.yaml
    sudo mv ca.crt /etc/nebula/ca.crt
    sudo mv ca.key /etc/nebula/ca.key
    sudo mv $name.crt /etc/nebula/host.crt
    sudo mv $name.key /etc/nebula/host.key

    #Start Nebula
    sudo echo -e "[Unit]\nDescription=Nebula overlay networking tool\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target\nBefore=sshd.service" >> /etc/systemd/system/turbocloud-nebula.service
    sudo echo -e "[Service]\nSyslogIdentifier=nebula\nExecReload=/bin/kill -HUP $MAINPID\nExecStart=/usr/local/bin/nebula -config /etc/nebula/config.yaml\nRestart=always" >> /etc/systemd/system/turbocloud-nebula.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/turbocloud-nebula.service
    sudo systemctl enable turbocloud-nebula.service
    sudo systemctl start turbocloud-nebula.service

    #Start RQLite
    sudo echo -e "[Unit]\nDescription=RQLite Agent\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target" >> /etc/systemd/system/rqlite-agent.service
    sudo echo -e "[Service]\nSyslogIdentifier=turbocloud-agent\nExecStart=/usr/local/bin/rqlited -node-id $name -raft-reap-node-timeout=30s -http-addr $private_ip:4001 -raft-addr $private_ip:4002  $HOME/rqlite \nRestart=always" >> /etc/systemd/system/rqlite-agent.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/rqlite-agent.service
    sudo systemctl enable rqlite-agent.service
    sudo systemctl start rqlite-agent.service


    #Start RQLite replica, we need 2 instances on a lighthouse because rqlite doesn't work in case we have 2 machines with rqlite in a cluster mode and we delete one server without uninstalling rqlite
    sudo echo -e "[Unit]\nDescription=RQLite Agent\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target" >> /etc/systemd/system/rqlite-replica-agent.service
    sudo echo -e "[Service]\nSyslogIdentifier=turbocloud-agent\nExecStart=/usr/local/bin/rqlited -node-id $name-replica -raft-reap-node-timeout=30s -http-addr $private_ip:4003 -raft-addr $private_ip:4004 -join 192.168.202.1:4002 $HOME/rqlite-replica \nRestart=always" >> /etc/systemd/system/rqlite-replica-agent.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/rqlite-replica-agent.service
    sudo systemctl enable rqlite-replica-agent.service
    sudo systemctl start rqlite-replica-agent.service


    #Start TurboCloud agent
    #We set a public domain for the first server

    sudo echo -e "[Unit]\nDescription=TurboCloud Agent\nWants=basic.target network-online.target nss-lookup.target time-sync.target\nAfter=basic.target network.target network-online.target" >> /etc/systemd/system/turbocloud-agent.service
    sudo echo -e "[Service]\nSyslogIdentifier=turbocloud-agent\nExecStart=/usr/local/bin/turbocloud-agent \nRestart=always\nEnvironment=TURBOCLOUD_AGENT_DOMAIN=$domain\nEnvironment=TURBOCLOUD_VPN_NODE_NAME=$name\nEnvironment=TURBOCLOUD_VPN_NODE_PRIVATE_IP=$private_ip" >> /etc/systemd/system/turbocloud-agent.service
    sudo echo -e "[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/turbocloud-agent.service
    sudo systemctl enable turbocloud-agent.service
    sudo systemctl start turbocloud-agent.service

fi

#Wait until turbocloud-agent agent is started
echo "Waiting when turbocloud_agent is online"

timeout 10 bash -c 'while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' localhost:5445/hey)" != "200" ]]; do sleep 1; done' || false

if [ "$url_download_vpn_certs" != "" ]; then
    echo ""
    echo ""
    echo "==================================================================================="
    echo ""
    echo ""
    echo "TurboCloud agent is installed. Use https://console.turbocloud.dev or TurboCLoud CLI to manage servers, local machines, services, apps, deployments and localhost tunnels. Check turbocloud.dev/docs for more information."
    echo ""
    echo ""
    echo "==================================================================================="
    echo ""
    echo ""
else

    #Start Docker container registry, in the current version the first server/root server is a build machine as well
    #We ll add special build nodes/machines in next version
    sudo docker container run -dt -p 7000:5000 --restart unless-stopped --name depl-registry --volume depl-registry:/var/lib/registry:Z docker.io/library/registry:2


    #Check if a join token is specified
    #if [ "$token_to_generate_vpn_certs_url" = "" ]; then
    #    echo "No join token is specified, skip generating of a join URL"
    #else
    #    echo "Generating a join URL to join VPN with this server"
     #   curl -d '{"name":"local_machine_1", "type":"local_machine", "join_token":"'"$token_to_generate_vpn_certs_url"'"}' -H "Content-Type: application/json" -X POST http://localhost:5005/vpn_node
    #fi

    echo ""
    echo ""
    echo "==================================================================================="
    echo ""
    echo ""
    echo "TurboCloud agent is installed. Use https://console.turbocloud.dev or TurboCLoud CLI to manage servers, local machines, services, apps, deployments and localhost tunnels. Check turbocloud.dev/docs for more information."
    echo ""
    echo ""
    echo "==================================================================================="
    echo ""
    echo ""
fi

#Call webhook if specified in flag -h
if [ "$webhook_url" != "" ]; then
    vpn_info=`sudo nebula-cert print -json -path /etc/nebula/host.crt`
    curl -d "$vpn_info" -H "Content-Type: application/json" -X POST $webhook_url
fi

#Reboot (optional)
#reboot
