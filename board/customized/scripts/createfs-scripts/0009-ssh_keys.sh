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
	print_green "adding ssh key file from ${filename}"
	KEYVAL=$(cat ${filename} | sed -E "s:(ssh-rsa) (.*) (.*):\1 \2:g")
	echo ${KEYVAL} >> ${AUTH_KEY_FILE}
done

chmod 700 "${TARGET_DIR}/root/.ssh"
chmod 600 "${AUTH_KEY_FILE}"