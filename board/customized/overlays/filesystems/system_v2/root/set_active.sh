#!/bin/bash
SLOT=${1}
if [[ "${SLOT}" != "1" && "${SLOT}" != "2" ]]; then
    echo "Usage: set_active.sh <1|2>"
    exit 1
fi
echo -n "${SLOT}" > /media/boot/active
sync
