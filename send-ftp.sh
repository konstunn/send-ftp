#!/bin/bash

FTP_CONF_FILE="ftp.conf"
CIFS_CONF_FILE="cifs.conf"

RECEIVERS_CONF_DIR="receivers.conf.d"

# read ftp and cifs config
# XXX potential security holes
source $FTP_CONF_FILE
source $CIFS_CONF_FILE

# mount ftp filesystem
mkdir -p /mnt/ftpfs/
curlftpfs ftp://$FTP_USERNAME:$FTP_PASSWORD@$FTP_HOST/$FTP_DIR/ /mnt/ftpfs/
	# FIXME may need additional options


cd $RECEIVERS_CONF_DIR 
for receiver_conf_file in $(ls) ; do

	# read receiver config
	# XXX potential security hole
	source $receiver_conf_file
	
	# mount receiver cifs directory
	mkdir -p /mnt/$receiver_conf_file/

	mount -t cifs $RECEIVER_DIR /mnt/$receiver_conf_file-cifs/ \
		-o username=$CIFS_USERNAME,password=$CIFS_PASSWORD,domain=$CIFS_DOMAIN
		# FIXME may need additional options

	# TODO rinex, rename, compress, zip and move (send)
	# here	


	# unmount receiver cifs directory
	umount /mnt/$receiver_conf_file/
	rmdir /mnt/$receiver_conf_file/
done
cd ..

# umount ftp filesystem
umount /mnt/ftpfs/
rmdir /mnt/ftpfs/
