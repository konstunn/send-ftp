#!/bin/bash

function round_down_unxtime_hrly
{
	echo $(($1 - $1 % 3600))
}

# $1 - attempts
function sleep_and_retry 
{
	echo "$1 retry attempts remain."
	# echo both to stdout and stderr
	if [ $1 -eq 0 ] ; then
		echo Exit
		exit 0
	else
		echo "Gone to sleep for $TIMEOUT_ON_FAIL"
		sleep $TIMEOUT_ON_FAIL
		if tty -s; then
			exec &> /dev/tty
		else
			exec &> /dev/null
		fi
		exec $0 --attempts $(($1 - 1))
	fi
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

# $1 - RNX_FILENAME_BASE_SRC_PREFIX, $2 - RNX_FILENAME_BASE_DST_PREFIX
function check_change_rnx_prefixes
{
	RNX_FILENAME_BASE_SRC_PREFIX="$1"

	RNX_FILENAME_BASE_DST_PREFIX="$2"

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

# $1 - rnx filename base
function change_rnx_suffixes
{
	mv ""$1"N.Z" ""$1"n.Z"
	mv ""$1"G.Z" ""$1"g.Z"
}

# $1 - rinex filename base source prefix,
# $2 - antenna type
# $3 - receiver type
function edit_rnx_at_rt
{
	sed -i "s/ANTENNA_TYPE/$2/g" \
		"$1"*

	EXITSTATUS=$?

	if [ $EXITSTATUS -ne 0 ] ; then 
		return $EXITSTATUS
	fi

	sed -i "s/RECEIVER_TYPE/$3/g" \
		"$1"*

	return $?
}

function is_unsigned_int
{
	if [[ "$1" =~ ^[0-9]+$ ]] ; then
		return 0
	else 
		return 1
	fi
}

# $1 - last_sent_file
function get_last_sent
{
	# read last time succeeded file, if such file exists
	if [ -r $last_sent_file ] ; then
		LAST_SENT=`cat $last_sent_file`
	else
		# else take the hour before the last
		echo -n ".*last_sent file not found: " >&2
		LAST_SENT=$(round_down_unxtime_hrly $(date +%s -u -d '2 hours ago'))
		echo "assuming last sent 2 hours ago" >&2
	fi
	echo $LAST_SENT
}

# $1 - jps file path
function get_src_prefix
{
	JPS_DIRNAME=`dirname "$1"`
	SRC_FILENAME=`ls "$JPS_DIRNAME" | tail -n 1`
	SRC_PREFIX=`echo $SRC_FILENAME | awk -F'_' '{print $1}'`
	echo $SRC_PREFIX
}

# $1 - unxtime var name
function unxtime_in_hrs_before_now
{
	eval $1=$((${!1} + 3600))
	UNXTIME_HRLY_ROUNDED=$(round_down_unxtime_hrly $(date +%s -u))
	test ${!1} -lt $UNXTIME_HRLY_ROUNDED
	return $?
}

SELF_PATH=`dirname $0`

cd "$SELF_PATH"

FTP_CONF_FILE="ftp.conf"
CIFS_CONF_FILE="cifs.conf"
GEN_CONF_FILE="send-ftp.conf"

RECEIVERS_CONF_DIR="receivers.conf.d"

OUT_LOG="send-ftp.log"

if ! [ -t 1 ] ; then
	# duplicate STDOUT and STDERR to $OUT_LOG file
	exec &> >(tee -a $OUT_LOG)
fi

TMP_REPO_DIR=".tmp_repo"
mkdir -p $TMP_REPO_DIR 

FORCE=0

source "$GEN_CONF_FILE"
source $FTP_CONF_FILE
source $CIFS_CONF_FILE

GITSTATLN=`git status --porcelain | wc -l`
VERSION="git-`git rev-parse --short HEAD`"

if [ $GITSTATLN -ne 0 ] ; then
	VERSION=""$VERSION"+"
fi

export LC_TIME="en_US.UTF-8"

echo -e "\n$(date --utc): $0 ($VERSION) started"

# show jps2rin version
echo -n "Installed "
jps2rin | head -n 1

# parse command line arguments
LONG_OPTS="attempts:,retry:,force"

ARGS=`getopt -o "" --long $LONG_OPTS -n $(basename $0) -- "$@"`

if [ $? -ne 0 ] ; then 
	echo "Exit"
	exit 1
fi

eval set -- "$ARGS"

while true ; do
	case "$1" in 
		--attempts | --retry)
			ATTEMPTS=$2 ; shift 2 ;;
		--force)
			FORCE=1 ; shift ;;
		--)				
			shift ; break ;;
	esac
done

if [[ "$ATTEMPTS" == "" ]] ; then
	if [[ "$RETRY_NUM_ON_FAIL" == "" ]] ; then
			ATTEMPTS=0
	else
		if ! is_unsigned_int $RETRY_NUM_ON_FAIL ; then
			echo "Error: RETRY_NUM_ON_FAIL defined in '$GEN_CONF_FILE' \
				is not an unsigned number"
			echo "Exit"
			exit 1
		fi
		ATTEMPTS=$RETRY_NUM_ON_FAIL
	fi
fi

if ! is_unsigned_int $ATTEMPTS ; then
	echo "Invalid argument value for option --attempts (--retry)"
	echo "Exit"
	exit 1
fi

GLOBAL_FAIL=0

RECEIVERS_CONF_FILES=`ls "$RECEIVERS_CONF_DIR"`

if [[ "$RECEIVERS_CONF_FILES" == "" ]] ; then
	echo "$RECEIVERS_CONF_DIR directory is empty"
fi

echo "Destination FTP-server hostname: $FTP_HOST"

for receiver_conf_file in $(ls "$RECEIVERS_CONF_DIR") ; do

	RECEIVER_FAIL=0

	# precaution
	unset RECEIVER_CIFS_DIR
	unset RECEIVER_PREFIX
	unset ANTENNA_TYPE
	unset RECEIVER_TYPE

	# read receiver config
	source "$RECEIVERS_CONF_DIR/$receiver_conf_file"

	echo "Processing '$receiver_conf_file' ('$RECEIVER_PREFIX')"

	# mount receiver cifs directory
	mount_point="/mnt/$receiver_conf_file-cifs"
	if [ -d "$mount_point" ] ; then
		umount "$mount_point"
	else
		mkdir "$mount_point"
		if [ $? -ne 0 ] ; then
			# TODO registrate that event in a database
			GLOBAL_FAIL=1
			continue
		fi
	fi

	mount -t cifs "$RECEIVER_CIFS_DIR" "$mount_point" \
		-o "username="$CIFS_USERNAME"" -o "password="$CIFS_PASSWORD"" \
		-o "domain="$CIFS_DOMAIN""
	
	if [ $? -ne 0 ] ; then
		# TODO registrate that event in a database
		GLOBAL_FAIL=1
		rmdir "$mount_point"
		continue
	fi

	last_sent_file="."$receiver_conf_file"_last_sent"

	LAST_SENT=`get_last_sent $last_sent_file`

	UNXTIME_HRLY_ROUNDED=$(round_down_unxtime_hrly $(date +%s -u))

	SENT_LAST_HOUR=0
	if [ $(($UNXTIME_HRLY_ROUNDED - $LAST_SENT)) -eq 3600 ] ; then
		SENT_LAST_HOUR=1
	fi

	file2send_unixtime=$(($LAST_SENT + 3600))

	if [ $SENT_LAST_HOUR -eq 1 ] ; then
		if [ $FORCE -eq 1 ] ; then
			file2send_unixtime=$LAST_SENT
			echo "$receiver_conf_file ($RECEIVER_PREFIX):" \
				"last sent last hour - force process"
		else
			echo "$receiver_conf_file ($RECEIVER_PREFIX):" \
				"last sent last hour - nothing to do"
		fi
	else
		# TODO customize date format
		echo "$receiver_conf_file ($RECEIVER_PREFIX):" \
			"last sent `date --utc -d @$LAST_SENT`"
	fi

	# this is because of unxtime_in_hrs_before_now features
	file2send_unixtime=$(($file2send_unixtime - 3600))

	while unxtime_in_hrs_before_now file2send_unixtime ; do

		echo "Processing date `date -u -d @$file2send_unixtime`"

		JPS_FILE_PATH=`build_jps_file_path $mount_point $file2send_unixtime \
			$RECEIVER_PREFIX`

		SRC_PREFIX=`get_src_prefix $JPS_FILE_PATH`

		JPS_FILE_PATH=`build_jps_file_path $mount_point $file2send_unixtime \
			$SRC_PREFIX`

		if ! [ -e "$JPS_FILE_PATH" ] ; then
			# TODO register that event in a database
			echo "Error: $JPS_FILE_PATH not found. Skip to next hour."
			continue
		fi

		echo -n "jps2rin: "

		jps2rin --rn --fd --lz --dt=30000 --AT="ANTENNA_TYPE" \
			--RT="RECEIVER_TYPE" "$JPS_FILE_PATH" \
			-o="$TMP_REPO_DIR" > /dev/null

		RNX_FILENAME_BASE_SRC_PREFIX=`build_rnx_filename_base $SRC_PREFIX \
			$file2send_unixtime`

		mv $RNX_FILENAME_BASE_SRC_PREFIX* $TMP_REPO_DIR/. &> /dev/null

		cd "$TMP_REPO_DIR"		

		FILES=`ls | grep $RNX_FILENAME_BASE_SRC_PREFIX | wc -l`
		if [ $FILES -eq 0 ] ; then
			# TODO register that event in a database
			echo "Error: no rinex files. Skip to next hour."
			continue
		fi

		edit_rnx_at_rt $RNX_FILENAME_BASE_SRC_PREFIX "$ANTENNA_TYPE" \
			"$RECEIVER_TYPE"

		RNX_FILENAME_BASE_DST_PREFIX=`build_rnx_filename_base $RECEIVER_PREFIX \
			$file2send_unixtime`

		check_change_rnx_prefixes $RNX_FILENAME_BASE_SRC_PREFIX \
			$RNX_FILENAME_BASE_DST_PREFIX

		cd ..

		RNX_FILENAME_BASE="$RNX_FILENAME_BASE_DST_PREFIX"

		if [ -e "$TMP_REPO_DIR"/"$RNX_FILENAME_BASE"o ] ; then
			# compress .o file, get .d file
			rnx2crx "$TMP_REPO_DIR/"$RNX_FILENAME_BASE"o"

			# remove .o file
			rm "$TMP_REPO_DIR/"$RNX_FILENAME_BASE"o"
		else
			# TODO register that event in a database
			echo "Error: no "$RNX_FILENAME_BASE"o file."
		fi

		# compress files
		gzip --suffix .Z "$TMP_REPO_DIR"/$RNX_FILENAME_BASE*

		cd "$TMP_REPO_DIR"

		change_rnx_suffixes $RNX_FILENAME_BASE

		for file_to_send in $(ls) ; do

			curl --silent --show-error --upload-file "$file_to_send" \
				--user $FTP_USERNAME:"$FTP_PASSWORD" \
				ftp://$FTP_HOST/"$FTP_DIR"/

			# if fails, set fail flags
			if [ $? -ne 0 ] ; then
				# TODO: register that event in a database
				RECEIVER_FAIL=1
				GLOBAL_FAIL=1
			else
				# TODO: register that event in a database
				echo "file '$file_to_send' sent"
			fi
			rm "$file_to_send"
		done

		cd ..

		if [ $RECEIVER_FAIL -eq 0 ] ; then
			# TODO: register that event in a database
			echo $file2send_unixtime > $last_sent_file
		else 
			# do processing sequentially
			break # so break and process next receiver
		fi
	done

	# unmount receiver cifs directory
	umount $mount_point 
	rmdir $mount_point 
done

if [ $GLOBAL_FAIL -eq 1 ] ; then
	sleep_and_retry $ATTEMPTS
fi
