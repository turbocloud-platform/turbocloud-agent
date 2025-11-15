#!/bin/bash

##Parameters
##-i 1.2.3.4.5 - public ip address of a server
##-d domain.com - domain, A record should be resolved to a public ip address typed in -i

##Example:
##
##curl https://turbocloud.dev/deploy | bash -s -- -i 12.32.22.43 -d myproject.com
##
##

public_ip=""
domain=""
project_port=""
project_folder=${PWD}
folder_name=$(pwd | sed 's#.*/##')

MD5_BIN="md5sum" # default for windows git bash and linux

COMMAND_OUTPUT=$(command -v md5sum)
if [ ${#COMMAND_OUTPUT} -lt 1 ]; then
    MD5_BIN="md5" # OSX
fi

local_project_folder="$(echo $(date | ${MD5_BIN} | tr -dc '[:alnum:]\n\r' | tr '[:upper:]' '[:lower:]'))"
server_project_folder="/root/$local_project_folder"

while getopts i:d:t:p: option
do
    case "${option}"
        in
        i)public_ip=${OPTARG};;
        d)domain=${OPTARG};;
        p)project_port=${OPTARG};;
    esac
done

#Check if it'sa git repository
if git rev-parse --git-dir > /dev/null 2>&1; then
    mkdir $local_project_folder
    git ls-files --others --cached --exclude-standard -z | grep -zvF "turbocloud.tar.gz" | tar --null -T - -czvf $local_project_folder/turbocloud.tar.gz
    scp -r $local_project_folder root@$public_ip:$server_project_folder
    rm -rf $local_project_folder
else
    scp -r $project_folder root@$public_ip:$server_project_folder
fi

#scp_response=$(script -qefc "scp -r $project_folder root@$public_ip:$server_project_folder" /dev/null)

#if [[ $scp_response == *"REMOTE HOST IDENTIFICATION HAS CHANGED!"* ]]; then
#  echo "$scp_response"
#  exit 1
#fi

ssh root@$public_ip server_project_folder=$server_project_folder 'bash -s' <<'ENDSSH'

echo "Checking if TurboCloud is installed on server with IP $public_ip"

status_code=$(curl --write-out %{http_code} --silent --output /dev/null localhost:5445/hey)

    if [[ "$status_code" -ne 200 ]] ; then
        echo "Installing TurboCloud agent and all required tools..."
        curl https://turbocloud.dev/setup | bash -s
    else
        echo "TurboCloud is installed already"
    fi

    cd $server_project_folder
    if test -f turbocloud.tar.gz; then
        tar -xvzf  turbocloud.tar.gz
    fi

ENDSSH

if [[ $(lsof -i tcp:5445 ) ]]; then
    lsof -i tcp:5445 | awk 'NR!=1 {print $2}' | xargs kill
else
    echo "Port 5445 is free"
fi

echo "Starting port mapping for 5445. TurboCloud API uses port 5445, all requests to API will be secured by SSH."

ssh -o ExitOnForwardFailure=yes -f -N -L 5445:localhost:5445 root@$public_ip

status_code=$(curl --write-out %{http_code} --silent --output /dev/null localhost:5445/hey)
echo "Checking that TurboCloud API is available"
echo "Response code to GET /hey: $status_code"

echo "Checking if this is the first deployment from this folder"
echo "TurboCloud stores service id and environment id in .turbocloud inside a project's root folder."

environmentId=""
serviceId=""

if test -f .turbocloud; then
    echo "TurboCloud config file has been found."
    environmentId=$(awk -F'=' '/^environmentId/ { print $2}'  .turbocloud)
    serviceId=$(awk -F'=' '/^serviceId/ { print $2}'  .turbocloud)
    echo "Deploying an environment with ID $environmentId in service with ID $serviceId"

    #Check if there is a service and environment in VPN, if no - we should create a new service and environment
    response=$(curl -s "http://localhost:5445/service/$serviceId/environment")

    # Check if the environmentId exists in the JSON response
    if [[ "$response" == *"$environmentId"* ]]; then
        echo "Environment with Id '$environmentId' has been found."
    else
        echo "Environment with Id '$environmentId' NOT found. Creating a new service and environment"
        environmentId=""
        serviceId=""
    fi

fi

if [ "$environmentId" = "" ]; then

  echo "No TurboCloud config file has been found or EnvironmentId hasn't be specified."

  echo "Creating a service for this project."
  serviceId=$(curl -d '{"Name":"'"$folder_name"'", "GitURL":"", "ProjectId":""}' -H "Content-Type: application/json" -X POST http://localhost:5445/service | sed -n 's|.*"Id": *"\([^"]*\)".*|\1|p')
  echo "New service has been created with Id: $serviceId"

  echo "Creating an environment."
  if [ "$domain" = "" ]; then
    domains='"Domains":[]'
  else
    domains='"Domains":["'"$domain"'"]'
  fi

  environmentId=$(curl -s -X POST http://localhost:5445/environment \
  -H "Content-Type: application/json" \
  -d '{"Name":"prod","Branch":"","Port":"'"$project_port"'",'$domains',"MachineIds":[],"GitTag":"","ServiceId":"'"$serviceId"'"}' | \
  sed -n 's|.*"Id":[[:space:]]*"\([^"]*\)".*|\1|p')

  echo "New environment has been created with Id: $environmentId"

  echo "Saving service Id and environment Id to .turbocloud"
  rm .turbocloud
  echo -e "serviceId=$serviceId" >> .turbocloud
  echo -e "environmentId=$environmentId" >> .turbocloud
fi

echo "Scheduling a deployment. Your project should be online within seconds/minutes (depending on your project type and size)"

deploymentId=$(curl -s -X POST "http://localhost:5445/deploy/environment/$environmentId" \
  -H "Content-Type: application/json" \
  -d "{\"SourceFolder\":\"$server_project_folder\"}" | \
  sed -n 's|.*"Id":[[:space:]]*"\([^"]*\)".*|\1|p')

echo "New deployment has been scheduled with Id: $deploymentId"
echo "--------------------------------------------------------"
echo "Open in a browser:"
echo "https://console.turbocloud.dev/services/$serviceId/environments/$environmentId"
echo "to find a domain, manage deployments, and view logs."
echo ""
echo "Docs are available at https://turbocloud.dev/docs"
echo "--------------------------------------------------------"
