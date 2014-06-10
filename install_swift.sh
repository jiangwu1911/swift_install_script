#!/bin/sh

PROXY_NODE="192.168.1.151"
STORAGE_NODES="192.168.1.152 192.168.1.153"
ALL_NODES="$PROXY_NODE $STORAGE_NODES"
STORAGE_DEVICE="sdb"
PROXY_LOCAL_NET_IP="192.168.1.151"
MYSQL_PASSWORD="password"


function exec_cmd() {
    remote_ip=$1
    cmd=$2
    output=$(ssh $remote_ip "$cmd" 2>&1)
    echo -e "host:    $remote_ip
command: $2
output:  $output\n" >> $log_file
    echo $output
}

function exec_script() {
    remote_ip=$1
    script=$2

    tmpfile=$(mktemp)
    echo "$script" > $tmpfile

    scp $tmpfile root@$remote_ip:/tmp
    remote_tmpfile=$(basename $tmpfile)
    remote_tmpfile="/tmp/$remote_tmpfile"
    output=$(exec_cmd $remote_ip "sh $remote_tmpfile")
    
    exec_cmd $remote_ip "rm -f $remote_tmpfile"
    rm -f $tmpfile
    echo $output
}

function copy_file() {
    file=$1
    remote_ip=$2
    remote_path=$3
    
    output=$(scp $file root@$remote_ip:$remote_path)
    echo -e "Copy file $file to $remote_ip:$remote_path
result: $output\n" >> $log_file
    echo $output
}

function enable_password_less_ssh() {
    for node in $ALL_NODES; do
        ssh-copy-id $node >/dev/null 2>&1
    done
}


function disable_selinux() {
    echo -e "\nDisable SELinux on each node... \c"
    for node in $ALL_NODES; do
        script="sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
setenforce Permissive"
        output=$(exec_script $node "$script")
    done
    echo "done."
}

function disable_firewall() {
    echo -e "\nDisable firewall on each node... \c"
    for node in $ALL_NODES; do
        script="service iptables stop
chkconfig iptables off"
        output=$(exec_script $node "$script")
    done
    echo "done."
}

function install_ntp() {
    echo -e "\nConfig ntp on each node:"

    for node in $ALL_NODES; do
        echo -e "    Installing ntp on $node... \c"
        script="yum install -y ntp
ntpdate 0.cn.pool.ntp.org
touch  /var/spool/cron/root
echo '*/30 * * * *  /usr/sbin/ntpdate 0.cn.pool.ntp.org >/dev/null 2>&1' > /var/spool/cron/root
crontab -u root /var/spool/cron/root
chkconfig crond on
service crond restart"
        output=$(exec_script $node "$script")
        echo "done."
    done
}

function create_device_on_a_storage_node() {
    node=$1 
    device=$2

    echo -e "    Creating storage device on $1... \c"
    script="fdisk /dev/$device <<EOF
n
p
1


w
EOF
kpartx -s /dev/$device
mkfs.xfs /dev/${device}1
mkdir -p /srv/node/${device}1
echo \"/dev/${device}1 /srv/node/${device}1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 0\" >> /etc/fstab
mount -a"
    output=$(exec_script $node "$script")
    echo "done."
}

function create_device() {
    echo -e "\nCreate storage device on storage nodes:"
    for node in $STORAGE_NODES; do 
        create_device_on_a_storage_node $node $STORAGE_DEVICE
    done 
}


function add_openstack_repo() {
    echo -e "\nAdd OpenStack yum repos... \c"
    for node in $ALL_NODES; do
        script="cat >/etc/yum.repos.d/openstack.repo <<EOF
[openstack-icehouse]
name=OpenStack Icehouse Repository
baseurl=http://192.168.1.124/openstack-icehouse/epel-6/
enabled=1
gpgcheck=0
EOF"
        output=$(exec_script $node "$script")
    done
    echo "done."
}


function install_swift_on_proxy_node() {
    node=$1
    echo -e "    Installing packages on $node... \c"

    pkgs="openstack-swift openstack-swift-proxy"
    script="yum install -y $pkgs"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_swift_on_storage_node() {
    node=$1
    echo -e "    Installing packages on $node... \c"

    pkgs="openstack-swift-account openstack-swift-object openstack-swift-container"
    script="yum install -y $pkgs
chown -R swift:swift /srv/node"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_swift() {
    echo -e "\nInstalling swift packages on proxy node:"
    install_swift_on_proxy_node $PROXY_NODE
    
    echo -e "\nInstalling swift packages on storage node:"
    for node in $STORAGE_NODES; do
        install_swift_on_storage_node $node
    done
}


function install_mysql_packages() {
    node=$1
    echo -e "\nInstalling MySQL server on $node... \c"
    script="yum install -y mysql-server
service mysqld start
chkconfig mysqld on

mysql_secure_installation <<EOF

Y
$MYSQL_PASSWORD
$MYSQL_PASSWORD
Y
Y
Y
EOF

mysql -u root -p$MYSQL_PASSWORD <<EOF
CREATE DATABASE keystone;  
GRANT ALL ON keystone.* TO 'keystone'@'%' IDENTIFIED BY 'keystone';  
commit;  
EOF

service mysqld restart
"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_keystone_packages() {
    node=$1
    echo -e "\nInstalling keystone packages on $node... \c"
    script="yum install -y openstack-keystone openstack-utils
openstack-config --set /etc/keystone/keystone.conf \
    database connection mysql://keystone:keystone@$node/keystone

keystone-manage db_sync

ADMIN_TOKEN=\$(openssl rand -hex 10)
echo \$ADMIN_TOKEN
openstack-config --set /etc/keystone/keystone.conf DEFAULT \
    admin_token \$ADMIN_TOKEN

keystone-manage pki_setup --keystone-user=keystone --keystone-group=keystone
chown -R keystone:keystone /etc/keystone/ssl
chmod -R o-rwx /etc/keystone/ssl
chown -R keystone:keystone /var/log/keystone

service openstack-keystone start
chkconfig openstack-keystone on
sleep 10
"

    output=$(exec_script $node "$script")
    echo "done."
}

function config_keystone() {
    node=$1
    echo -e "\nConfig keystone on $node... \c"
    scp config_keystone.sh root@$node:/tmp >/dev/null 2>&1 
    output=$(exec_cmd $node "sh /tmp/config_keystone.sh $PROXY_NODE >/dev/null 2>&1")
    
    echo "done."
    $(exec_cmd $node "rm -f /tmp/config_keystone.sh >/dev/null 2>&1")
    echo $output 
}

function install_keystone() {
    install_mysql_packages $PROXY_NODE
    install_keystone_packages $PROXY_NODE
    config_keystone $PROXY_NODE
}


function check_connection() {
    fail_count=0
    echo -e "\nCheck network connection on each node:"
    for node in $ALL_NODES; do
        echo -e "    Checking $node... \c"
        output=$(exec_cmd $node "ping -c 1 mirrors.sohu.com | grep '1 received' | wc -l")
        if [ "$output" = "1" ]; then
            echo "success."
        else 
            echo "failed."
            fail_count=`expr $fail_count + 1`
        fi
    done

    if [ $fail_count -gt 0 ]; then
        echo -e "Fail to connect some nodes, fix the problem and try again.\n"
        exit 1
    fi
}


function config_swift_conf() {
    echo -e "\nConfigure /etc/swift/swift.conf on each node:"

    tmpfile=$(mktemp)
    cat >$tmpfile <<EOF
[swift-hash]
# random unique strings that can never change (DO NOT LOSE)
swift_hash_path_prefix = `od -t x8 -N 8 -A n </dev/urandom`
swift_hash_path_suffix = `od -t x8 -N 8 -A n </dev/urandom`
EOF

    for node in $ALL_NODES; do
        echo -e "    Copying files to $node... \c"
        $(copy_file $tmpfile $node "/etc/swift/swift.conf")
        echo "done."
    done
    rm -f $tmpfile
}

function config_proxy_conf() {
    echo -e "\nConfig /etc/swift/proxy-server.conf on $PROXY_NODE... \c"
    script="mkdir -p /home/swift/keystone-signing
chown -R swift:swift /home/swift/keystone-signing

cat >/etc/swift/proxy-server.conf <<EOF
[DEFAULT]
bind_port = 8080
workers = 8
user = swift

[pipeline:main]
pipeline = healthcheck cache authtoken keystoneauth proxy-server

[app:proxy-server]
use = egg:swift#proxy
allow_account_management = true
account_autocreate = true

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = Member,admin,swiftoperator

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:authtoken]
paste.filter_factory = keystoneclient.middleware.auth_token:filter_factory
delay_auth_decision = true
signing_dir = /home/swift/keystone-signing
auth_protocol = http
auth_host = ${PROXY_NODE}
auth_port = 35357
admin_tenant_name = service
admin_user = swift
admin_password = admin

[filter:cache]
use = egg:swift#memcache
memcache_servers = ${PROXY_NODE}:11211
EOF"
    output=$(exec_script $PROXY_NODE "$script")
    echo "done."
}

function config_memcached() {
    echo -e "\nConfigure memcache on $PROXY_NODE... \c"
    script="yum install -y memcached
service memcached start
chkconfig memcached on"
    output=$(exec_script $PROXY_NODE "$script")
    echo "done."
}

function config_rsync() {
    echo -e "\nConfigure rsync on each node:"
    for node in $STORAGE_NODES; do
        echo -e "    Installing rsync on $node... \c"
        script="yum install -y xinetd rsync

sed -i -s 's#disable.*=.*yes#disable = no#' /etc/xinetd.d/rsync

cat > /etc/rsyncd.conf <<EOF
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = 0.0.0.0
# should be changed to private IP in production env

[account]
max connections = 2
path = /srv/node/
read only = false
lock file = /var/lock/account.lock

[container]
max connections = 2
path = /srv/node/
read only = false
lock file = /var/lock/container.lock

[object]
max connections = 2
path = /srv/node/
read only = false
lock file = /var/lock/object.lock
EOF

chkconfig xinetd on
service xinetd restart
"
        output=$(exec_script $node "$script")
        echo "done"
    done
}

function config() {
    config_swift_conf
    config_proxy_conf
    config_memcached
    config_rsync
}


function create_rings() {
    echo -e "\nCreate rings... \c"
    
    script="cd /etc/swift
swift-ring-builder account.builder create 18 2 1
swift-ring-builder container.builder create 18 2 1
swift-ring-builder object.builder create 18 2 1"

    for node in $STORAGE_NODES; do
        script="$script
swift-ring-builder object.builder add z1-$node:6000/${STORAGE_DEVICE}1 100
swift-ring-builder container.builder add z1-$node:6001/${STORAGE_DEVICE}1 100
swift-ring-builder account.builder add z1-$node:6002/${STORAGE_DEVICE}1 100"
    done

    script="$script
swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance"

    output=$(exec_script $PROXY_NODE "$script")

    # Copy the generated .gz file to each storage node
    mkdir -p /tmp/swift_install
    scp $PROXY_NODE:/etc/swift/*gz /tmp/swift_install >/dev/null
    for node in $STORAGE_NODES; do
        scp /tmp/swift_install/*gz $node:/etc/swift >/dev/null
    done

    echo "done."

}


function start_service_on_proxy_node() {
    echo -e "    Start service on $PROXY_NODE... \c"
        script="chown -R swift:swift /etc/swift
cd /etc/init.d
for service in \$(ls openstack-swift*); do
    chkconfig \$service on
    service \$service start
done"
    output=$(exec_script $PROXY_NODE "$script")
    echo "done"
}

function start_service_on_storage_node() {
    for node in $STORAGE_NODES; do
        echo -e "    Start service on $node... \c"
        script="chown -R swift:swift /etc/swift
sed -i -s 's#bind_ip.*#/bind_ip = 0.0.0.0#' /etc/swift/account-server.conf
sed -i -s 's#bind_ip.*#/bind_ip = 0.0.0.0#' /etc/swift/container-server.conf
sed -i -s 's#bind_ip.*#/bind_ip = 0.0.0.0#' /etc/swift/object-server.conf

cd /etc/init.d
for service in \$(ls openstack-swift*); do
    chkconfig \$service on
    service \$service start
done"
        output=$(exec_script $node "$script")
        echo "done"
    done
}

function start_service() {
    echo -e "\nStart service on each node:"
    start_service_on_proxy_node
    start_service_on_storage_node
}


function init_log() {
    dt=$(date '+%Y_%m_%d_%H_%M_%S')
    log_file="swift_install_$dt.log"
    echo -e "\nSave log information in file $log_file."
}


# Main Program
init_log

# Check environment
enable_password_less_ssh
check_connection

# Prepare to install
disable_selinux
disable_firewall
install_ntp
create_device

# Install and config
add_openstack_repo
install_keystone
install_swift
config

# Start service
create_rings
start_service

echo
