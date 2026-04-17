#!/bin/bash
SLOT=$(/root/get_active.sh)
ROOTPART=$(lsblk -o NAME,MOUNTPOINT | grep lower | awk '{print $1}')
ROOTPART=/dev/${ROOTPART:2:$((${#ROOTPART}-2))}

if [[ "${SLOT}" == "1" && "${ROOTPART}" == *"p2" ]]; then
    echo "slot1"
elif [[ "${SLOT}" == "2" && "${ROOTPART}" == *"p3" ]]; then
    echo "slot2"
else
    echo "error"
fi
