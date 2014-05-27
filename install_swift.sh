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
    echo -e "\nCheck connection to each node:"
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
    echo 
}

function memcached() {
    echo
}

function config_rsync() {
    echo
}

function config() {
    echo
}


# Main Program
dt=$(date '+%Y_%m_%d_%H_%M_%S')
log_file="swift_install_$dt.log"
echo -e "\nSave log information in file $log_file."

check_connection
create_device
install_packages
config
echo
