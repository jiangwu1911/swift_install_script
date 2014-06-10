#!/bin/sh

export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=admin
export OS_AUTH_URL="http://192.168.1.151:35357/v2.0/"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <tenant_name> <username> <password>"
    exit 1
fi

new_tenant_name=$1
new_username=$2
new_password=$3

function get_id () {
    echo `"$@" | grep ' id ' | awk '{print $4}'`
}

role_id=$(keystone role-list |  grep Member | awk '{print $2}')
tenant_id==$(get_id keystone tenant-create --name=$new_tenant_name)
user_id=$(get_id keystone user-create --name=$new_username \
                                      --password=$new_password \
                                      --role-id=$rold_id)
