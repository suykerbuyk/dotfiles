#!/bin/bash
for F in $(find fetch.bins/ -type f -executable); do
    echo $F
    $F
done
