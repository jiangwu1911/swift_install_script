#!/bin/sh

SWIFT_LOCAL_IP="192.168.1.151"
USER="system:root"
PASS="testpass"

echo -e "Authentication... \c"
tmpfile=$(mktemp)
output=$(curl -k -v -H "X-Storage-User: $USER" -H "X-Storage-Pass: $PASS" \
         http://$SWIFT_LOCAL_IP:8080/auth/v1.0 >$tmpfile 2>&1)
status=$(cat  $tmpfile | grep 'HTTP/1.1 200 OK' | wc -l)
if [ $status -ne 1 ]; then
    echo " failed."
    echo $output
    exit 1
fi

echo " success."
token=$(cat $tmpfile | grep X-Auth-Token | cut -d: -f 2)
url=$(cat $tmpfile | grep X-Storage-Url | cut -d: -f 2-)
echo "Token: $token"
echo "URL:   $url"

# Check that you can HEAD the account
curl -k -v -H "X-Auth-Token: $token" $url

echo -e "\nCheck if swift works\n------------------------------------"
swift_url="http://${SWIFT_LOCAL_IP}:8080/auth/v1.0"
swift -A $swift_url -U $USER -K $PASS stat

echo -e "\nList containers\n---------------------------------------"
swift -A $swift_url -U $USER -K $PASS list

echo
