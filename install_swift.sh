#!/bin/sh

PROXY_NODE="swift01"
STORAGE_NODE="swift02 swift03"
STORAGE_DEVICE="sdb"


function exec_cmd() {
    remote_ip=$1
    cmd=$2
    output=$(ssh $remote_ip "$cmd" 2>&1)
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

    echo -e "Preparing storage device on $1...   \c"
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
    for node in $1; do 
        create_device_on_a_storage_node $node $STORAGE_DEVICE
    done 
}

function install_packages_on_proxy_node() {
    node=$1
    echo -e "    Installing $node...   \c"

    pkgs="openstack-swift openstack-swift-proxy"
    script="yum install -y http://rdo.fedorapeople.org/rdo-release.rpm
yum install -y $pkgs"
    output=$(exec_script $node "$script")
    echo "done."
}

function install_packages_on_storage_node() {
    node=$1
    echo -e "    Installing $node...   \c"

    pkgs="openstack-swift-account openstack-swift-object openstack-swift-container"
    script="yum install -y http://rdo.fedorapeople.org/rdo-release.rpm
yum install -y $pkgs"
    output=$(exec_script $node "$script")
    echo "done."
}


function check_connection() {
    fail_count=0
    echo -e "\nCheck connection to each node:"
    for node in $PROXY_NODE $STORAGE_NODE; do
        echo -e "    To $node... \c"
        output=$(exec_cmd $node "echo \"hello\"")
        if [ "$output" = "hello" ]; then
            echo "success."
        else 
            echo "failed."
            fail_count=`expr $fail_count + 1`
        fi
    done

    if [ $fail_count -gt 0 ]; then
        echo "Fail to connect some nodes, please check again."
        exit 1
    fi
}


# Main Program
check_connection
#create_device "$STORAGE_NODE" 

echo -e "\nInstall packages on proxy node:"
for node in $PROXY_NODE; do
    install_packages_on_proxy_node $node
done

echo -e "\nInstall packages on storage node:"
for node in $STORAGE_NODE; do
    install_packages_on_storage_node $node
done
echo
