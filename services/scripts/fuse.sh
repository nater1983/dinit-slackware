#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

set -e

if [ "$1" != "stop" ]; then
# Gracefully exit if the package has been removed.
which fusermount3 &>/dev/null || exit 5
which fusermount &>/dev/null || exit 5
	if ! grep -qw fuse /proc/filesystems; then
		echo -n "Loading fuse module"
		if ! modprobe fuse >/dev/null 2>&1; then
			echo " failed!"
			exit 1
		else
			echo "."
		fi
	else
		echo "Fuse filesystem already available."
	fi
	if grep -qw fusectl /proc/filesystems && \
	   ! grep -qw $MOUNTPOINT /proc/mounts; then
		echo -n "Mounting fuse control filesystem"
		if ! mount -t fusectl fusectl $MOUNTPOINT >/dev/null 2>&1; then
			echo " failed!"
			exit 1
		else
			echo "."
		fi
	else
		echo "Fuse control filesystem already available."
	fi
 fi;
