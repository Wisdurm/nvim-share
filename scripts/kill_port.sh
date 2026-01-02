#!/bin/bash

if [ -z "$1" ]; then
	echo "usage: $0 <port>" 1>&2
	exit 1
fi

PORT=$1

lsof -t -i tcp:$PORT -s tcp:listen 2>/dev/null | xargs -r kill
