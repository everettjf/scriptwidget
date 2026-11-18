#!/bin/sh
# send.sh <control fifo> <word>...  Writes one command line to the helper.
fifo=$1; shift
[ -p "$fifo" ] && printf '%s\n' "$*" > "$fifo"
