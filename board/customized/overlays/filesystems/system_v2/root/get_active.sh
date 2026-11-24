#!/bin/bash
SLOT=$(cat /media/boot/active 2>/dev/null)
if [[ "${SLOT}" != "1" && "${SLOT}" != "2" ]]; then
    echo "WARNING: active marker missing or invalid, defaulting to slot1" >&2
    echo "1"
else
    echo "${SLOT}"
fi
