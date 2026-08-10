#!/bin/bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

USER=suykerbuyk
PROXY=syketech.com
PASS="$(op item get "Syketech Teleport" --fields label=password --reveal)"
OTP="$(op item get "Syketech Teleport" --otp)"
export TELEPORT_TLS_ROUTING_CONN_UPGRADE=true

#echo $PASS
#echo $OTP

SESSION="${XDG_SESSION_TYPE:-unknown}"

case "$SESSION" in
    x11)
        echo "Running on x11"
        ;;
    tty)
        echo "Running on console mode only"
        ;;
    wayland)
        echo "Running on wayland"
        ;;
    *)
        echo "Session type '$SESSION' is unmapped"
        ;;
esac

export TELEPORT_USE_LOCAL_SSH_AGENT=false
echo "tsh login --proxy=$PROXY --user=$USER --ttl 1800 (with TELEPORT_USE_LOCAL_SSH_AGENT=false to bypass hung ssh-agent)"

if [ "X${TMUX}X" != "XX" ]; then
    tmux set-buffer "$(op item get "Syketech Teleport" --fields label=password --reveal)"
    echo "Syketech password is now in the TMUX paste buffer."
else
    echo "Not running in tmux, you will need to enter the Teleport password manually"
fi

echo "One time password: $OTP"
tsh login --proxy="${PROXY}" --user="${USER}" --ttl 1800

if [ "X${TMUX}X" != "XX" ]; then
    tmux set-buffer ""
fi
