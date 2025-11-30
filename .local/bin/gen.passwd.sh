#!/bin/sh
# https://www.howtogeek.com/30184/10-ways-to-generate-a-random-password-from-the-command-line/

< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo

# openssl rand -base64 32
# tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1
# < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c20
