#!/bin/bash
PERSIST_DIR=/media/data/ssh

if [ -d "${PERSIST_DIR}" ]; then
    cp ${PERSIST_DIR}/ssh_host_*_key* /etc/ssh/
else
    ssh-keygen -A
    mkdir -p ${PERSIST_DIR}
    cp /etc/ssh/ssh_host_*_key* ${PERSIST_DIR}/
fi
