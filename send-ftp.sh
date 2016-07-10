#!/bin/bash

function round_down_unxtime_hrly
{
	echo $(($1 - $1 % 3600))
}

function sleep_and_retry 
{
	# echo both to stdout and stderr
	echo "Gone to sleep $TIMOUT_ON_FAIL" >&2
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
	HOUR=`date +%k -u -d @$FILE_UNIXTIME`
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
	SECONDS_OF_DAY=`printf %05d $SECONDS_OF_DAY`

	JPS_FILE_NAME=""$RECEIVER_PREFIX"_$YY$MM"$DD"_"$SECONDS_OF_DAY".jps"

	JPS_FILE_PATH="$MOUNT_POINT/raw_hourly/$YYYY/$MM/$DD/$JPS_FILE_NAME"

	echo $JPS_FILE_PATH
}

SELF_PATH=`dirname $0`

cd "$SELF_PATH"

FTP_CONF_FILE="ftp.conf"
CIFS_CONF_FILE="cifs.conf"

RECEIVERS_CONF_DIR="receivers.conf.d"

ERR_LOG="send-ftp.err.log"
OUT_LOG="send-ftp.out.log"

LAST_TIME_OK_FILE=".last_time_ok"

# duplicate STDOUT to $OUT_LOG file
exec > >(tee -a $OUT_LOG)

# duplicate STDERR to $ERR_LOG file
exec 2> >(tee -a $ERR_LOG)

TMP_REPO_DIR=".tmp_repo"

mkdir -p $TMP_REPO_DIR 

# read general config
source "send-ftp.conf"

# read ftp and cifs config
# XXX potential security holes
source $FTP_CONF_FILE
source $CIFS_CONF_FILE

export LC_TIME="en_US.UTF-8"

VERSION="git`git rev-parse --short HEAD`"

# echo both to stdout and stderr
echo -e "\n$(date --utc): $0-$VERSION started" >&2

FAIL=0

for receiver_conf_file in $(ls "$RECEIVERS_CONF_DIR") ; do

	# read receiver config
	# XXX potential security hole
	source "$RECEIVERS_CONF_DIR/$receiver_conf_file"

	# mount receiver cifs directory
	mount_point="/mnt/$receiver_conf_file-cifs"
	mkdir -p "$mount_point"

	if [ $? -ne 0 ] ; then
		FAIL=1
		continue
	fi

	mount -t cifs "$RECEIVER_CIFS_DIR" "$mount_point" \
		-o "username="$CIFS_USERNAME"" -o "password="$CIFS_PASSWORD"" \
		-o "domain="$CIFS_DOMAIN""
		# FIXME may need additional options
	
	if [ $? -ne 0 ] ; then
		FAIL=1
		rmdir "$mount_point"
		continue
	fi

	# TODO implement separate such file for each receiver
	# read last time succeeded file, if such file exists
	if [ -r $LAST_TIME_OK_FILE ] ; then
		LAST_TIME_OK=`cat $LAST_TIME_OK_FILE`
	else
		# else take the hour before the last
		LAST_TIME_OK=$(round_down_unxtime_hrly $(date +%s -u -d '2 hours ago'))
	fi

	file2send_unixtime=$(($LAST_TIME_OK + 3600))

	UNXTIME_HRLY_ROUNDED=$(round_down_unxtime_hrly $(date +%s -u))

	while [ $file2send_unixtime -lt $UNXTIME_HRLY_ROUNDED ] ; do

		JPS_FILE_PATH=`build_jps_file_path $mount_point $file2send_unixtime \
			$RECEIVER_PREFIX`

		JPS_DIRNAME=`dirname "$JPS_FILE_PATH"`
		SRC_FILENAME=`ls "$JPS_DIRNAME" | tail -n 1`
		SRC_PREFIX=`echo $SRC_FILENAME | awk -F'_' '{print $1}'`

		JPS_FILE_PATH=`build_jps_file_path $mount_point $file2send_unixtime \
			$SRC_PREFIX`

		jps2rin --rn --fd --lz --dt=30000 --AT="ANTENNA_TYPE" \
			--RT="RECEIVER_TYPE" "$JPS_FILE_PATH" \
			-o="$TMP_REPO_DIR" > /dev/null

		if [ $? -ne 0 ] ; then
			FAIL=1
			umount $mount_point
			rmdir $mount_point
			continue
		fi

		RNX_FILENAME_BASE_SRC_PREFIX=`build_rnx_filename_base $SRC_PREFIX \
			$file2send_unixtime`

		RNX_FILENAME_BASE_DST_PREFIX=`build_rnx_filename_base $RECEIVER_PREFIX \
			$file2send_unixtime`

		cd "$TMP_REPO_DIR"		

		if [ "$RNX_FILENAME_BASE_SRC_PREFIX" != \
			"$RNX_FILENAME_BASE_DST_PREFIX" ] 
		then
			# change prefixes
			mv -f "$RNX_FILENAME_BASE_SRC_PREFIX"o \
				"$RNX_FILENAME_BASE_DST_PREFIX"o

			mv -f "$RNX_FILENAME_BASE_SRC_PREFIX"N \
				"$RNX_FILENAME_BASE_DST_PREFIX"N

			mv -f "$RNX_FILENAME_BASE_SRC_PREFIX"G \
				"$RNX_FILENAME_BASE_DST_PREFIX"G
		fi

		sed -i "s/ANTENNA_TYPE/$ANTENNA_TYPE/g" \
			"$RNX_FILENAME_BASE_DST_PREFIX"*

		sed -i "s/RECEIVER_TYPE/$RECEIVER_TYPE/g" \
			"$RNX_FILENAME_BASE_DST_PREFIX"*

		cd ..

		RNX_FILENAME_BASE="$RNX_FILENAME_BASE_DST_PREFIX"

		# compress .o file, get .d file
		rnx2crx "$TMP_REPO_DIR/"$RNX_FILENAME_BASE"o"

		# remove .o file
		rm "$TMP_REPO_DIR/"$RNX_FILENAME_BASE"o"

		# compress files
		gzip --suffix .Z "$TMP_REPO_DIR"/$RNX_FILENAME_BASE*

		cd "$TMP_REPO_DIR"

		# change suffixes
		mv ""$RNX_FILENAME_BASE"N.Z" ""$RNX_FILENAME_BASE"n.Z"
		mv ""$RNX_FILENAME_BASE"G.Z" ""$RNX_FILENAME_BASE"g.Z"

		for file_to_send in $(ls) ; do

			curl --silent --show-error --upload-file "$file_to_send" \
				--user $FTP_USERNAME:"$FTP_PASSWORD" \
				ftp://$FTP_HOST/"$FTP_DIR"/

			# check exit status. if failed, sleep and retry
			if [ $? -ne 0 ] ; then
				FAIL=1
			else
				rm "$file_to_send"
				echo "file '$file_to_send' sent"
			fi
		done

		cd ..

		file2send_unixtime=$((file2send_unixtime + 3600))
	done

	# unmount receiver cifs directory
	umount $mount_point 
	rmdir $mount_point 
done

if [ $FAIL -eq 1 ] ; then
	sleep_and_retry
else
	sleep 0
fi
