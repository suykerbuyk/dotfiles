#!/bin/bash
USER=suykerbuyk
PROXY=syketech.com
PASS="$(op item get "Syketech Teleport" --fields label=password --reveal)"
OTP="$(op item get "Syketech Teleport" --otp)"
export TELEPORT_TLS_ROUTING_CONN_UPGRADE=true

#echo $PASS
#echo $OTP

SESSION="$(echo $XDG_SESSION_TYPE)"
case $(SESSION) in
x11)
    echo "Running on x11"
    ;;
tty)
    echo "Running on in console mode only"
    ;;
*)
    echo "Session type $SESSION is unmapped"
    ;;
esac

echo "tsh login --proxy=syketech.com --user=suykerbuyk --ttl 1800"

if [ "X${TMUX}X" != "XX" ]; then
    tmux set-buffer "$(op item get "Syketech Teleport" --fields label=password --reveal)"
    echo "SykeTech password is now in the TMUX paste buffer."
else
    echo "Not running in tmux, you will need to enter the Teleport password manually"
fi

which wl-copy >/dev/null
if [ $(which xsel) ]; then
    echo "$OTP" | xsel --primary
    echo "One time password is now in primary clipboard: $OTP"
elif [ $(which wl-copy) ]; then
    echo "$OTP" | wl-copy
    echo "One time password is now in primary clipboard: $OTP"
else
    echo "No system clipboard functions detected."
    echo "OTP: $OTP"
fi
echo "tsh login --proxy=${PROXY} --user=${USER} --ttl 1800"
tsh login --proxy=${PROXY} --user=${USER} --ttl 1800

echo "" | wl-copy
if [ "X${TMUX}X" != "XX" ]; then
    tmux set-buffer ""
fi
