#!/usr/bin/env bash  
  
ADMIN_PASSWORD=admin  
ENABLE_SWIFT=1  
ENABLE_ENDPOINTS=1  
SWIFT_HOST_IP=$1
KEYSTONE_HOST_IP=$1
  
KEYSTONE_CONF=${KEYSTONE_CONF:-/etc/keystone/keystone.conf}  
SERVICE_PASSWORD=${SERVICE_PASSWORD:-$ADMIN_PASSWORD}  
  
# Extract some info from Keystone's configuration file  
if [[ -r "$KEYSTONE_CONF" ]]; then  
    CONFIG_SERVICE_TOKEN=$(sed 's/[[:space:]]//g' $KEYSTONE_CONF | grep ^admin_token= | cut -d'=' -f2)  
    CONFIG_ADMIN_PORT=$(sed 's/[[:space:]]//g' $KEYSTONE_CONF | grep ^admin_port= | cut -d'=' -f2)  
fi  
  
export SERVICE_TOKEN=${SERVICE_TOKEN:-$CONFIG_SERVICE_TOKEN}  
if [[ -z "$SERVICE_TOKEN" ]]; then  
    echo "No service token found."  
    echo "Set SERVICE_TOKEN manually from keystone.conf admin_token."  
    exit 1  
fi  
  
export SERVICE_ENDPOINT=${SERVICE_ENDPOINT:-http://127.0.0.1:${CONFIG_ADMIN_PORT:-35357}/v2.0}  
  
function get_id () {  
    echo `"$@" | grep ' id ' | awk '{print $4}'`  
}  
  
# Tenants  
ADMIN_TENANT=$(get_id keystone tenant-create --name=admin)  
SERVICE_TENANT=$(get_id keystone tenant-create --name=service)  
DEMO_TENANT=$(get_id keystone tenant-create --name=demo)  
  
  
# Users  
ADMIN_USER=$(get_id keystone user-create --name=admin \
                                         --pass="$ADMIN_PASSWORD" \
                                         --email=admin@example.com)
DEMO_USER=$(get_id keystone user-create --name=demo \
                                        --pass="$ADMIN_PASSWORD" \
                                        --email=admin@example.com)  
  
# Roles  
ADMIN_ROLE=$(get_id keystone role-create --name=admin)  
MEMBER_ROLE=$(get_id keystone role-create --name=Member)  
KEYSTONEADMIN_ROLE=$(get_id keystone role-create --name=KeystoneAdmin)  
KEYSTONESERVICE_ROLE=$(get_id keystone role-create --name=KeystoneServiceAdmin)  
SYSADMIN_ROLE=$(get_id keystone role-create --name=sysadmin)  
  
# Add Roles to Users in Tenants  
keystone user-role-add --user-id $ADMIN_USER --role-id $ADMIN_ROLE --tenant-id $ADMIN_TENANT  
keystone user-role-add --user-id $DEMO_USER --role-id $MEMBER_ROLE --tenant-id $DEMO_TENANT  
keystone user-role-add --user-id $DEMO_USER --role-id $SYSADMIN_ROLE --tenant-id $DEMO_TENANT  
keystone user-role-add --user-id $ADMIN_USER --role-id $ADMIN_ROLE --tenant-id $DEMO_TENANT  
  
# TODO(termie): these two might be dubious  
keystone user-role-add --user-id $ADMIN_USER --role-id $KEYSTONEADMIN_ROLE --tenant-id $ADMIN_TENANT  
keystone user-role-add --user-id $ADMIN_USER --role-id $KEYSTONESERVICE_ROLE --tenant-id $ADMIN_TENANT  
  
  
# Services  
KEYSTONE_SERVICE=$(get_id \
keystone service-create --name=keystone \
                        --type=identity \
                        --description="Keystone Identity Service")  
if [[ -n "$ENABLE_ENDPOINTS" ]]; then  
    keystone endpoint-create --region RegionOne --service_id $KEYSTONE_SERVICE \
        --publicurl "http://${KEYSTONE_HOST_IP}:\$(public_port)s/v2.0" \
        --adminurl "http://${KEYSTONE_HOST_IP}:\$(admin_port)s/v2.0" \
        --internalurl "http://${KEYSTONE_HOST_IP}:\$(admin_port)s/v2.0"
fi  
  
if [[ -n "$ENABLE_SWIFT" ]]; then  
    SWIFT_SERVICE=$(get_id keystone service-create --name=swift \
                            --type="object-store" \
                            --description="Swift Service")  
    SWIFT_USER=$(get_id keystone user-create --name=swift \
                                             --pass="$SERVICE_PASSWORD" \
                                             --tenant_id $SERVICE_TENANT \
                                             --email=swift@example.com)  
    keystone user-role-add --tenant-id $SERVICE_TENANT \
                           --user-id $SWIFT_USER \
			               --role-id $ADMIN_ROLE  
    keystone endpoint-create --region RegionOne --service_id $SWIFT_SERVICE \
        --publicurl "http://${SWIFT_HOST_IP}:8080/v1/AUTH_\$(tenant_id)s" \
        --adminurl "http://${SWIFT_HOST_IP}:8080/" \
        --internalurl "http://${SWIFT_HOST_IP}:8080/v1/AUTH_\$(tenant_id)s"
fi                                                 
