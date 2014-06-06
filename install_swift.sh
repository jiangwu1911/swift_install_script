#!/bin/sh

PROXY_NODE="swift01"
STORAGE_NODE="swift02 swift03"
STORAGE_DEVICE="sdb"


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


function install_ntp() {
    echo -e "\nConfig ntp on each node:"

    for node in $PROXY_NODE $STORAGE_NODE; do
        echo -e "    Installing ntp on $node... \c"
        script="yum install -y ntp
ntpdate 0.cn.pool.ntp.org
sed -i -s 's#^.*ntpdate.*#*/30 * * * * root /usr/sbin/ntpdate 0.cn.pool.ntp.org#' /etc/crontab
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
yum install -y $pkgs"
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
    echo -e "\nConfigure /etc/swift/swift.conf on each node... \c"

    tmpfile=$(mktemp)
    cat >$tmpfile << EOF
[swift-hash]
# random unique strings that can never change (DO NOT LOSE)
swift_hash_path_prefix = `od -t x8 -N 8 -A n </dev/random`
swift_hash_path_suffix = `od -t x8 -N 8 -A n </dev/random`
EOF

    for node in $PROXY_NODE $STORAGE_NODE; do
        copy_file $tmpfile $node "/etc/swift/swift.conf"
    done
        
    rm -f $tmpfile
    echo "done."
}

function config_memcached() {
    echo
}

function config_rsync() {
    echo
}

function config() {
    config_swift_conf
    config_memcached
    config_rsync
}


# Main Program
dt=$(date '+%Y_%m_%d_%H_%M_%S')
log_file="swift_install_$dt.log"
echo -e "\nSave log information in file $log_file."

#check_connection
install_ntp
#create_device
#install_packages
config
echo
