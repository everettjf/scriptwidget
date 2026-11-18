#!/bin/sh
# Runs inside a terminal window that the tests put below the widgets: turns on
# mouse reporting and writes what the terminal receives to the file named, so
# a click that reaches this window leaves a line like "<0;12;7M" there.
printf '\033[?1000h\033[?1006h'
stty raw -echo
exec cat > "$1"
