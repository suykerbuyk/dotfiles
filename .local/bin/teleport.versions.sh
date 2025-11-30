#!/bin/bash
IFS='\n'; for X in "$(tsh ls -f json | jq -r  '.[].spec | .hostname + " " + .cmd_labels.teleport.result + " " + .cmd_labels.platform.result'  )" ; do IFS=' '  ; echo $X | awk '{printf "%020s %s %s %s\n", $1,$2,$3,$4}'; done
