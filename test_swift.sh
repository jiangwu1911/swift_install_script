#!/bin/sh

SWIFT_LOCAL_IP="192.168.1.151"
export ST_AUTH="http://${SWIFT_LOCAL_IP}:8080/auth/v1.0"
export ST_USER="system:root"
export ST_KEY="testpass"

echo -e "Authentication... \c"
tmpfile=$(mktemp)
output=$(curl -k -v -H "X-Storage-User: $ST_USER" -H "X-Storage-Pass: $ST_KEY" \
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
swift stat

echo -e "\nList containers\n---------------------------------------"
swift list
swift list myfiles

echo -e "\nUpload file\n----------------------------------------"
swift upload myfiles README.md
swift upload myfiles *

echo -e "\nDownload file\n--------------------------------------"
swift download myfiles README.md

echo -e "\nDelete file\n----------------------------------------"
swift delete myfiles README.md
swift delete myfiles

echo -e "\n
echo
