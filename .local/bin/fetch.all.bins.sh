#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
for F in $(find ${SCRIPT_DIR}/fetch.bins/ -type f -executable); do
    echo $F
    $F
done
