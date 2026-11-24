#!/bin/bash
set_watch() {
	FILENAME=${1}
	while inotifywait -r -e modify,create,delete,move /etc/${FILENAME}; do
        	rsync -al /etc/${FILENAME} /media/data/custometc/ --delete
	done
}
cleanup(){
	kill -15 ${!PIDMAP[@]}
	exit
}
trap "cleanup" INT TERM SEGV KILL
declare -A PIDMAP
FILES=$(IFS=$'\r\n' && cat /etc/syncfiles)
for file in ${FILES}
do
	set_watch ${file} & 
	PIDMAP["$!"]="${file}"
	echo "${BASHPID}: watch on ${file} spawned"
done
#echo "printing PIDMAP:"
#for i in "${!PIDMAP[@]}"
#do
#	echo "${i} = ${PIDMAP[$i]}"
#done
while true
do
	for i in "${!PIDMAP[@]}"
	do
		kill -0 ${i}
		if [[ $? -ne 0 ]]; then
			del=${PIDMAP[${i}]}
			file=${PIDMAP[${i}]}
			unset PIDMAP[${i}]
			echo "respawning watch on ${file}"
			set_watch ${file} &
        		PIDMAP["$!"]="${file}"
        		echo "${BASHPID}: watch on ${file} spawned"
		fi
	done
	sleep 1
done
exit 0
