#!/bin/bash
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

set -e

if [ "$1" != "stop" ]; then
# Configure kernel parameters:
if [ -r /etc/default/sysctl ]; then
  # Source user defined options:
  . /etc/default/sysctl
else
  SYSCTL_OPTIONS="-e --system"
fi
if [ -x /sbin/sysctl -a -r /etc/sysctl.conf -a -z "$container" ]; then
  echo "Configuring kernel parameters:  /sbin/sysctl $SYSCTL_OPTIONS"
  /sbin/sysctl $SYSCTL_OPTIONS
elif [ -x /sbin/sysctl -a -z "$container" ]; then
  echo "Configuring kernel parameters:  /sbin/sysctl $SYSCTL_OPTIONS"
  # Don't say "Applying /etc/sysctl.conf" or complain if the file doesn't exist
  /sbin/sysctl $SYSCTL_OPTIONS 2> /dev/null | grep -v "Applying /etc/sysctl.conf"
fi
unset SYSCTL_OPTIONS
fi;
