#!/bin/sh

echo "drop database keystone;" | mysql -u root -ppassword
echo "create database keystone;" | mysql -u root -ppassword
keystone-manage db_sync
