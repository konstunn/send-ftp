#!/bin/bash

function sleep_and_retry 
{
	# echo both to stdout and stderr
	echo "Gone to sleep $TIMOUT_ON_FAIL" | tee /dev/stderr
	sleep $TIMEOUT_ON_FAIL
	$0 &
	exit
}

# $1 - time_t
function unixtime_to_seconds_of_day
{
	YYYY=`date +%Y -u -d @$1`
	MM=`date +%m -u -d @$1`
	DD=`date +%d -u -d @$1`

	MIDNIGHT=`date +%s --utc --date $YYYY-$MM-$DD`
	SECONDS_OF_DAY=$(($1 - $MIDNIGHT))
	echo $SECONDS_OF_DAY
}

# $1 - RECEIVER_PREFIX, $2 - file_unixtime
function build_rnx_filename_base
{
	RECEIVER_PREFIX="$1"
	FILE_UNIXTIME=$2

	HOUR_LETTER=({a..x})
	HOUR=`date +%H -u @$FILE_UNIXTIME`
	HOUR_LETTER=${HOUR_LETTER[$HOUR]}

	DOY=`date +%j -u -d @$FILE_UNIXTIME`					
	YY=`date +%y -u -d @$FILE_UNIXTIME`

	RNX_FILENAME_BASE="$RECEIVER_PREFIX"$DOY""$HOUR_LETTER"."$YY""
	echo $RNX_FILENAME_BASE
}

# $1 - mount_point, $2 - FILE_UNIXTIME_VAR, $3 - RECEIVER_PREFIX
function build_jps_file_path 
{
	MOUNT_POINT="$1"
	FILE_UNIXTIME_VAR="$2"
	RECEIVER_PREFIX="$3"

	YYYY=`date +%Y -u -d @$FILE_UNIXTIME_VAR`
	MM=`date +%m -u -d @$FILE_UNIXTIME_VAR`
	DD=`date +%d -u -d @$FILE_UNIXTIME_VAR`
	YY=`date +%y -u -d @$FILE_UNIXTIME_VAR`

	SECONDS_OF_DAY=`unixtime_to_seconds_of_day $FILE_UNIXTIME_VAR`

	JPS_FILE_NAME=""$RECEIVER_PREFIX"_$YY$MM"$DD"_"$SECONDS_OF_DAY".jps"

	JPS_FILE_PATH="$MOUNT_POINT/raw_hourly/$YYYY/$MM/$DD/$JPS_FILE_NAME"

	echo $JPS_FILE_PATH
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

TMP_REPO_DIR=".tmp_repo/"

mkdir -p $TMP_REPO_DIR 

# read general config
source "send-ftp.conf"

# read ftp and cifs config
# XXX potential security holes
source $FTP_CONF_FILE
source $CIFS_CONF_FILE

export LC_TIME="en_US.UTF-8"

echo "$(date --utc): $0 started" | tee /dev/stderr

for receiver_conf_file in $(ls "$RECEIVERS_CONF_DIR") ; do

	# read receiver config
	# XXX potential security hole
	source "$RECEIVERS_CONF_DIR/$receiver_conf_file"

	# mount receiver cifs directory
	mount_point="/mnt/$receiver_conf_file-cifs/"
	mkdir -p "$mount_point"

	if [ $? -ne 0 ] ; then
		sleep_and_retry
	fi

	mount -t cifs "$RECEIVER_CIFS_DIR" "$mount_point" \
		-o "username="$CIFS_USERNAME",password="$CIFS_PASSWORD",\
		domain="$CIFS_DOMAIN""
		# FIXME may need additional options
	
	if [ $? -ne 0 ] ; then
		rmdir "$mount_point"
		sleep_and_retry
	fi

	# define path of the file to process and send
	
	# compute seconds elapsed since UTC midnight 
	now=`date +%s --utc --date now`
	midnight=`date +%s --utc --date 00:00:00`
	seconds_of_day=$(($now - $midnight))

	# round backwards
	seconds_hrly_rounded=`expr $seconds_of_day - $seconds_of_day % 3600`

	yyyy=`date +%Y`
	mm=`date +%m`
	dd=`date +%d`
	yy=`date +%y`

	# construct .jps file path
	JPS_FILE_NAME=""$RECEIVER_PREFIX"_$yy$mm"$dd"_"$seconds_hrly_rounded".jps"

	JPS_FILE_PATH="$mount_point/raw_hourly/$yyyy/$mm/$dd/$JPS_FILE_NAME"

	# rinexize
	jps2rin --rn --fd --lz --dt=30000 --AT="$ANTENNA_TYPE" \
		--RT="$RECEIVER_TYPE" "$JPS_FILE_PATH" -o "$TMP_REPO_DIR"

	if [ $? -ne 0 ] ; then sleep_and_retry ; fi

	hour_letter=({a..x})
	hour=`expr seconds_hrly_rounded / 3600`
	hour_letter=${hour_letter[$hour]}
	doy=`date +%j`					

	FILE_NAME_BASE="$RECEIVER_PREFIX"$doy""$hour_letter"."$yy""

	# compress .o file, get .d file
	rnx2crx "$TMP_REPO_DIR/"$FILE_NAME_BASE"o"

	# remove .o file
	rm "$TMP_REPO_DIR/"$FILE_NAME_BASE"o"

	# compress files
	gzip -S.Z "$TMP_REPO_DIR/$FILE_NAME_BASE*"

	cd "$TMP_REPO_DIR"

	# change presuffixes
	mv ""$FILE_NAME_BASE"N.Z" ""$FILE_NAME_BASE"n.Z"
	mv ""$FILE_NAME_BASE"G.Z" ""$FILE_NAME_BASE"g.Z"

	for file_to_send in $(ls) ; do
		# send
		curl --upload-file "$file_to_send" \
			--user $FTP_USERNAME:$FTP_PASSWORD \
			$FTP_HOST/$FTP_DIR/

		# check exit status. if failed, sleep and retry
		if [ $? -ne 0 ] ; then
			echo "ERROR: curl failed to send '$file_to_send' \
				with exit code $?" >&2
			FAIL=1
		else
			rm file_to_send
			echo "file '$file_to_send' sent"
		fi
	done

	cd ..

	# unmount receiver cifs directory
	umount $mount_point 
	rmdir $mount_point 
done

if [ $FAIL -eq 1 ] ; then
	sleep_and_retry
fi
