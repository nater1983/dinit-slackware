#!/bin/bash
PATH=/usr/bin:/usr/sbin:/bin:/sbin

if [ "$1" = start ]; then
# Start the local setup procedure.
  if [ -x /etc/rc.d/rc.local ]; then
    /etc/rc.d/rc.local
  fi
fi
