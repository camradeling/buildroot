#!/bin/bash
## VARIABLES AND FUNCTIONS ##
source ${PWD}/board/customized/scripts/functions.inc

TARGET_DIR=${1}
VERSION_TAG=$(git describe --tags --dirty=-dirty)
#echo "export VERSION_TAG=${VERSION_TAG}" > ${TARGET_DIR}/etc/profile.d/version_tag.sh
sed -i -E "s/export VERSION_TAG=.*/export VERSION_TAG=dummy/g" ${TARGET_DIR}/${SYSTEM_VARS_FILE}
print_green "INFO: version tag=${VERSION_TAG} exported"
