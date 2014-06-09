#!/bin/sh

PROXY_NODE="192.168.1.151"
STORAGE_NODE="192.168.1.152 192.168.1.153"
STORAGE_DEVICE="sdb"
PROXY_LOCAL_NET_IP="192.168.1.151"


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
    for node in $PROXY_NODE $STORAGE_NODE; do
        ssh-copy-id $node
    done
}


function disable_selinux() {
    echo -e "\nDisable SELinux... \c"
    for node in $PROXY_NODE $STORAGE_NODE; do
        script="sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
setenforce Permissive"
        output=$(exec_script $node "$script")
    done
    echo "done."
}

function disable_firewall() {
    echo -e "\nDisable firewall... \c"
    for node in $PROXY_NODE $STORAGE_NODE; do
        script="service iptables stop
chkconfig iptables off"
        output=$(exec_script $node "$script")
    done
    echo "done."
}

function install_ntp() {
    echo -e "\nConfig ntp on each node:"

    for node in $PROXY_NODE $STORAGE_NODE; do
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
    for node in $STORAGE_NODE; do 
        create_device_on_a_storage_node $node $STORAGE_DEVICE
    done 
}


function install_packages_on_proxy_node() {
    node=$1
    echo -e "    Installing packages on $node... \c"

    pkgs="openstack-swift openstack-swift-proxy"
    script="yum install -y http://rdo.fedorapeople.org/rdo-release.rpm
yum install -y $pkgs"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_packages_on_storage_node() {
    node=$1
    echo -e "    Installing packages on $node... \c"

    pkgs="openstack-swift-account openstack-swift-object openstack-swift-container"
    script="yum install -y http://rdo.fedorapeople.org/rdo-release.rpm
yum install -y $pkgs
chown -R swift:swift /srv/node"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_packages() {
    echo -e "\nInstall packages on proxy node:"
    
    for node in $PROXY_NODE; do
        install_packages_on_proxy_node $node
    done
    
    echo -e "\nInstall packages on storage node:"
    for node in $STORAGE_NODE; do
        install_packages_on_storage_node $node
    done
}


function check_connection() {
    fail_count=0
    echo -e "\nCheck network connection on each node:"
    for node in $PROXY_NODE $STORAGE_NODE; do
        echo -e "    To $node... \c"
        output=$(exec_cmd $node "ping -c 1 baidu.com | grep '1 received' | wc -l")
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
    cat >$tmpfile << EOF
[swift-hash]
# random unique strings that can never change (DO NOT LOSE)
swift_hash_path_prefix = `od -t x8 -N 8 -A n </dev/urandom`
swift_hash_path_suffix = `od -t x8 -N 8 -A n </dev/urandom`
EOF

    for node in $PROXY_NODE $STORAGE_NODE; do
        echo -e "    Copying files to $node... \c"
        $(copy_file $tmpfile $node "/etc/swift/swift.conf")
        echo "done."
    done
    rm -f $tmpfile
}

function config_proxy_conf() {
    echo -e "\nConfig /etc/swift/proxy-server.conf on $PROXY_NODE... \c"
    script="cat >/etc/swift/proxy-server.conf <<EOF
[DEFAULT]
cert_file = /etc/swift/cert.crt
key_file = /etc/swift/cert.key
bind_port = 8080
workers = 8
user = swift

[pipeline:main]
pipeline = healthcheck proxy-logging cache tempauth proxy-logging proxy-server

[app:proxy-server]
use = egg:swift#proxy
allow_account_management = true
account_autocreate = true

[filter:proxy-logging]
use = egg:swift#proxy_logging

[filter:tempauth]
use = egg:swift#tempauth
user_system_root = testpass .admin http://$PROXY_LOCAL_NET_IP:8080/v1/AUTH_system

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:cache]
use = egg:swift#memcache
memcache_servers = $PROXY_LOCAL_NET_IP:11211
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
    for node in $STORAGE_NODE; do
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

    for node in $STORAGE_NODE; do
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
    for node in $STORAGE_NODE; do
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
    for node in $STORAGE_NODE; do
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

enable_password_less_ssh
check_connection

disable_selinux
disable_firewall
install_ntp
create_device
install_packages

config
create_rings
start_service

echo
