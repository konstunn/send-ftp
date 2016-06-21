#!/bin/bash

function sleep_and_retry 
{
	sleep $TIMEOUT_ON_FAIL
	$0 &
	exit
}

FTP_CONF_FILE="ftp.conf"
CIFS_CONF_FILE="cifs.conf"

RECEIVERS_CONF_DIR="receivers.conf.d"

ERR_LOG="send-ftp.err.log"
OUT_LOG="send-ftp.out.log"

# duplicate STDOUT to $OUT_LOG file
exec > >(tee -a $OUT_LOG)

# duplicate STDERR to $ERR_LOG file
exec 2> >(tee -a $ERR_LOG)

# read ftp and cifs config
# XXX potential security holes
source $FTP_CONF_FILE
source $CIFS_CONF_FILE

FILES_TO_SEND=""

export LC_TIME="en_US.UTF-8"

echo "$(date --utc): $0 started" | tee /dev/stderr

cd $RECEIVERS_CONF_DIR 
for receiver_conf_file in $(ls) ; do

	# read receiver config
	# XXX potential security hole
	source $receiver_conf_file
	
	# mount receiver cifs directory
	mkdir -p /mnt/$receiver_conf_file-cifs/

	mount -t cifs $RECEIVER_DIR /mnt/$receiver_conf_file-cifs/ \
		-o username=$CIFS_USERNAME,password=$CIFS_PASSWORD,domain=$CIFS_DOMAIN
		# FIXME may need additional options

	# TODO rinex, rename, compress, zip and append them to $FILE_TO_SEND
	# here	


	# unmount receiver cifs directory
	umount /mnt/$receiver_conf_file/
	rmdir /mnt/$receiver_conf_file/
done
cd ..

curl -T "$FILES_TO_SEND" -u $FTP_USERNAME:$FTP_PASSWORD $FTP_HOST/$FTP_DIR/

