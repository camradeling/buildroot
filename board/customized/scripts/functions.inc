#!/bin/bash
## color
## https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux

# Default
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NORMAL='\033[0m'

# Reset
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White

# Bold
BBlack='\033[1;30m'       # Black
BRed='\033[1;31m'         # Red
BGreen='\033[1;32m'       # Green
BYellow='\033[1;33m'      # Yellow
BBlue='\033[1;34m'        # Blue
BPurple='\033[1;35m'      # Purple
BCyan='\033[1;36m'        # Cyan
BWhite='\033[1;37m'       # White

# Underline
UBlack='\033[4;30m'       # Black
URed='\033[4;31m'         # Red
UGreen='\033[4;32m'       # Green
UYellow='\033[4;33m'      # Yellow
UBlue='\033[4;34m'        # Blue
UPurple='\033[4;35m'      # Purple
UCyan='\033[4;36m'        # Cyan
UWhite='\033[4;37m'       # White

# Background
On_Black='\033[40m'       # Black
On_Red='\033[41m'         # Red
On_Green='\033[42m'       # Green
On_Yellow='\033[43m'      # Yellow
On_Blue='\033[44m'        # Blue
On_Purple='\033[45m'      # Purple
On_Cyan='\033[46m'        # Cyan
On_White='\033[47m'       # White

# High Intensity
IBlack='\033[0;90m'       # Black
IRed='\033[0;91m'         # Red
IGreen='\033[0;92m'       # Green
IYellow='\033[0;93m'      # Yellow
IBlue='\033[0;94m'        # Blue
IPurple='\033[0;95m'      # Purple
ICyan='\033[0;96m'        # Cyan
IWhite='\033[0;97m'       # White

# Bold High Intensity
BIBlack='\033[1;90m'      # Black
BIRed='\033[1;91m'        # Red
BIGreen='\033[1;92m'      # Green
BIYellow='\033[1;93m'     # Yellow
BIBlue='\033[1;94m'       # Blue
BIPurple='\033[1;95m'     # Purple
BICyan='\033[1;96m'       # Cyan
BIWhite='\033[1;97m'      # White

# High Intensity backgrounds
On_IBlack='\033[0;100m'   # Black
On_IRed='\033[0;101m'     # Red
On_IGreen='\033[0;102m'   # Green
On_IYellow='\033[0;103m'  # Yellow
On_IBlue='\033[0;104m'    # Blue
On_IPurple='\033[0;105m'  # Purple
On_ICyan='\033[0;106m'    # Cyan
On_IWhite='\033[0;107m'   # White
#############


function delete_file()
{
        for file in $*
        do
                if [[ -f ${file} &&  ! -L ${file} ]]; then
                        echo "INFO: file: ${BGreen}\"$file\"${NORMAL}removed"
                        rm $file > /dev/null 2>&1
		elif [[ -L ${file} ]]; then
			echo "INFO: link: ${BGreen}\"$file\"${NORMAL} removed"
			rm $file > /dev/null 2>&1
                else
                        echo -e "INFO: file ${BRed} \"${file}\" ${NORMAL} not found"
                fi
        done
}

function delete_file_silent()
{
	rm -rf $1 > /dev/null 2>&1
}

function check_empty()
{
	v=$1
	value=$2
	if [[ -z $value ]]; then
		echo -e "${RED}ERROR! VAR: $v is empty ${NORMAL}"
		exit 1
	fi

}

function set_equals()
{
	VAR=$1
	VALUE=$2
	FILE=$3

	check_empty VAR $VAR
	check_empty VALUE $VALUE
	check_empty FILE $FILE

	echo "$VAR=$VALUE" >> $FILE
	echo -e "INFO: ${BGreen} ${VAR}=$VALUE ${NORMAL} in ${BBlue} $FILE ${NORMAL}"
}

function set_space()
{
	VAR=$1
	VALUE=$2
	FILE=$3

	check_empty VAR $VAR
	check_empty VALUE $VALUE
	check_empty FILE $FILE

	echo "${VAR} ${VALUE}" >> ${FILE}
	echo -e "INFO: ${BGreen} ${VAR} ${VALUE} ${NORMAL} in ${BBlue} $FILE ${NORMAL}"
}

function set_value()
{
	VALUE=$1
	FILE=$2

	check_empty VALUE $VALUE
	check_empty FILE $FILE

	echo "$VALUE" >> $FILE
	echo -e "INFO:${BGreen} $VALUE ${NORMAL} in ${BBlue} $FILE ${NORMAL}"
}

function create_link()
{
	LINK=$2
	FILE=$1

	check_empty LINK $LINK
	check_empty FILE $FILE

	ln -s $FILE $LINK > /dev/null 2>&1
	echo -e "INFO: Create link ${BGreen} $LINK ${NORMAL} to file ${BBlue} $FILE ${NORMAL}"
}

function create_rule_rootdevice()
{
        product=$1
        serial=$2
        id_vendor=$3
        id_product=$4
        b_device_class=$5
        FILE=$6
	if [[ -z $product ]]; then
		return 0
	fi

	check_empty product $product
	check_empty serial $serial
	check_empty id_vendor $id_vendor
	check_empty id_product $id_product
	check_empty b_device_class $b_device_class
	check_empty FILE $FILE
	set_value "SUBSYSTEMS==\"usb\", ACTION==\"add\", ATTR{product}==\"${product}\", ATTR{serial}==\"${serial}\", ATTR{idVendor}==\"${id_vendor}\", ATTR{idProduct}==\"${id_product}\", ATTR{bDeviceClass}==\"${b_device_class}\", ATTR{authorized}=\"1\", GOTO=\"usb_end\"" $FILE
}

function create_rule_usbhub()
{
	dev_path=$1
        FILE=$2
	if [[ -z $dev_path ]]; then
		return 0
	fi

	check_empty device_path $dev_path
	check_empty FILE $FILE

	set_value "SUBSYSTEM==\"usb\", ACTION==\"add\", ENV{DRIVER}==\"hub\", ENV{DEVTYPE}==\"usb_interface\", ENV{DEVPATH}==\"${dev_path}\",  ATTR{authorized}=\"1\", GOTO=\"usb_end\"" $FILE
}

function create_permitted_device()
{
	dev_vid=$1
	dev_pid=$2
	FILE=$3

	if [[ -z $dev_vid ]]; then
		return 0
	fi

	check_empty DEV_VID $dev_vid
	check_empty DEV_PID $dev_pid
	check_empty FILE $FILE

	set_value "SUBSYSTEMS==\"usb\", ATTRS{idVendor}==\"${dev_vid}\", ATTRS{idProduct}==\"${dev_pid}\", ACTION==\"add\", ATTR{authorized}=\"1\", GOTO=\"usb_end\"" $FILE
}

function set_chmod()
{
	lvl=$1
	FILE=$2

	check_empty config_file $FILE

	chmod $lvl $FILE
	echo -e "INFO: set chmod ${BGreen} $lvl ${NORMAL} to file: ${BBLue} $FILE ${NORMAL}"
}


function print_red()
{
	text=$*
	echo -e "${BRed}${text}${NORMAL}"
}

function print_green()
{
	text=$*
	echo -e "${BGreen}${text}${NORMAL}"
}

function print_blue()
{
	text=$*
	echo -e "${BBlue}${text}${NORMAL}"
}

## For the middle case the other three do not cover: the build is going ahead, but
## something in it is likely wrong and nobody will connect the symptom back to it
## later. print_red is already used for plain INFO lines in these scripts, so red
## cannot mean "look at this" any more - hence a colour of its own.
function print_yellow()
{
	text=$*
	echo -e "${BYellow}${text}${NORMAL}"
}

function copy_file()
{
	src=$1
	dst=$2
	check_empty SRC $src
	check_empty DST $dst

	cp $src $dst
	if [[ $? == 0 ]]; then
		echo -e "INFO: copy ${BGreen} $src ${NORMAL} to ${BGreen} $dst ${NORMAL} sucessful"
	else
		print_red "ERROR! not copy file $src to $dst"
#		exit 1
	fi 
}

function create_dir()
{
	DIR=$1
	if ! [[ -d $DIR ]]; then
		mkdir -p $DIR
		echo -e "INFO: directory ${BGreen} ${DIR} $NORMAL created"
	fi
}
