#!/bin/bash
server="vault01.syketech.arpa"
base_dir="/" # Optional: Prefix local mounts (e.g., /mnt/nfs/ark01/foo); set to "" for direct /ark01/foo
fs_dir="ark01"

mkdir -p "${base_dir}${fs_dir}"

for X in $(showmount -e "$server" 2>/dev/null | grep ${fs_dir} | awk '{print $1}' | sort); do
    local_path=$(echo "${base_dir}${X}" | sed 's|//|/|g')
    #mkdir -p "$(dirname "$local_path")" && echo "mkdir $local_path"
    if ! mountpoint -q "$local_path" 2>/dev/null; then
        echo "Mounting $server:$X to $local_path"
        if ! sudo mount -o nolock,rw "$server:$X" "$local_path"; then
            echo "Failed to mount $X"
        fi
    else
        echo "$local_path already mounted"
    fi
done
