#!/bin/bash
SCRIPT_DIR="$(dirname $(realpath update.local.bins.sh))"
for F in $(find ${SCRIPT_DIR}/fetch.bins/ -type f -executable | sort); do
    echo $F
    $F
done
