#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
if [[ -z ${BOARD_VERSION} ]]; then
	print_green "INFO: variable BOARD_VERSION is not set"
        sed -i -E "s/export BOARD_VERSION=.*/export BOARD_VERSION=dummy/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
else
        print_green "INFO: variable BOARD_VERSION=${BOARD_VERSION}"
        sed -i -E "s/export BOARD_VERSION=.*/export BOARD_VERSION=${BOARD_VERSION}/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
fi
