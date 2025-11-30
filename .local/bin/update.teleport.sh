#!/bin/bash
#for X in $(tsh ls | awk '{print $1}' | grep -v Node | grep -v '\--' |grep -v dac | grep -v miner1 | grep -v -e '^[[:space:]]*$' ); do echo -n "$X  "; tsh ssh root@${X} 'rm -rf teleport-*; wget -q https://cdn.teleport.dev/teleport-v11.1.2-linux-amd64-bin.tar.gz ; tar -xf teleport-*.gz ; cd teleport; ./install;  teleport version'  ; sleep 1 ; done

#for X in $(tsh ls | awk '{print $1}' | grep -v Node | grep -v '\--' |grep  dac | grep -v -e '^[[:space:]]*$' ); do echo -n "$X  "; tsh ssh root@${X} 'rm -rf teleport-*; wget -q https://cdn.teleport.dev/teleport-v11.1.2-linux-amd64-centos7-bin.tar.gz ; tar -xf teleport-*.gz ; cd teleport; ./install;  teleport version'  ; sleep 1 ; done
#
tctl get nodes --format=json | jq '.[].spec | ("Version: " + .cmd_labels.teleport.result + " Hostname: " + .hostname)'
#VERSION="15.0.0"
VERSION=$(curl --silent https://syketech.com/v1/webapi/ping | jq -r '.server_version')
echo "Targeting Teleport Version: $VERSION"

for X in $(tsh ls | awk '{print $1}' | grep -v Node | grep -v syketech | grep -v archx | grep -v '\--' | grep -v -e '^[[:space:]]*$')
do
	printf "%s :\n" $X
	tsh ssh root@${X} "curl https://goteleport.com/static/install.sh | bash -s ${VERSION}"
	tsh ssh root@${X} "nohup systemctl restart teleport 1>/dev/null 2>/dev/null &"
done


#for X in gerovit frondi kedi san1-1c-ggc-xl-768891 san1-4g-cgc-xl-1bdc19 catnip bensw1 avavilin-01
#do
#	tsh ssh root@${X} ' NEEDRESTART_MODE=a  apt update; apt install -y teleport'
#done
