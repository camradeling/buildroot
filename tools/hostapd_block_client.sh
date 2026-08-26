#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <block|unblock> <MAC>"
    echo "  block   — deauthenticate client and add to deny list"
    echo "  unblock — remove client from deny list"
    exit 1
}

[ $# -eq 2 ] || usage

ACTION="$1"
MAC="$2"
HOST="${TESTBOT_HOST:-zero3_new}"

case "${ACTION}" in
    block)
        ssh ${HOST} "hostapd_cli deauthenticate ${MAC} && hostapd_cli deny_acl ADD_MAC ${MAC}"
        echo "Blocked ${MAC}"
        ;;
    unblock)
        ssh ${HOST} "hostapd_cli deny_acl DEL_MAC ${MAC}"
        echo "Unblocked ${MAC}"
        ;;
    *)
        usage
        ;;
esac
