#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

SCRIPT_DIR="${TARGET_DIR}/../../board/customized/scripts/createfs-scripts"
SCRIPTS=`ls ${SCRIPT_DIR} | grep .*.sh`

for script in ${SCRIPTS}
do
	print_blue "INFO_FILE: ${script}"
	${SCRIPT_DIR}/${script} "$@"
	rc=$?
	print_blue "######################################################################"
	# Не даем сборке завершиться успешно с некорректно настроенным образом
	if [[ ${rc} != 0 ]]; then
		print_red "ERROR: ${script} failed with exit code ${rc}, aborting build"
		exit ${rc}
	fi
done
