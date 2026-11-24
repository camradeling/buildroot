#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
AUTH_KEY_FILE=${TARGET_DIR}/root/.ssh/authorized_keys
mkdir -p "${TARGET_DIR}/root/.ssh" &&
rm ${AUTH_KEY_FILE}
touch ${AUTH_KEY_FILE}

#IFS=' ' 
read -r -a array <<< "${SSH_KEY_FILES_LIST}"

for filename in "${array[@]}"
do
	## a key file the template's placeholder still points at would otherwise
	## build an image nobody can log in to
	if [[ ! -r "${filename}" ]]; then
		print_red "ERROR: SSH_KEY_FILES_LIST: ${filename} not found or not readable"
		exit 1
	fi
	print_green "adding ssh key file from ${filename}"
	KEYVAL=$(cat ${filename} | sed -E "s:(ssh-rsa) (.*) (.*):\1 \2:g")
	echo ${KEYVAL} >> ${AUTH_KEY_FILE}
done

chmod 700 "${TARGET_DIR}/root/.ssh"
chmod 600 "${AUTH_KEY_FILE}"