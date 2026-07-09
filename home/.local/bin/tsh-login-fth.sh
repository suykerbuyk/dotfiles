#!/bin/bash
USER=jsuykerbuyk
PROXY=remote.future-tech-holdings.com
PASS="$(op item get "FTH Teleport" --fields label=password --reveal)"
OTP="$(op item get "FTH Teleport" --otp)"
#echo $PASS
#echo $OTP

if [ "X${TMUX}X" != "XX" ] ; then
	tmux set-buffer "$PASS"
	echo "FTH password is now in the TMUX paste buffer."
else
	echo "Not running in tmux, you will need to enter the Teleport password manually"
fi

echo "$OTP"| wl-copy ; wl-paste ;
#echo $(tmux paste-buffer)
echo " tsh login --proxy=$PROXY --user=$USER --ttl 1800"
tsh login --proxy=$PROXY --user=$USER --ttl 1800

echo "" | wl-copy
if [ "X${TMUX}X" != "XX" ] ; then
	tmux set-buffer ""
fi
