#!/bin/sh

# $Id: jail.sh 21 2004-02-11 03:06:06Z kirk $

case "$1" in
start)
	/usr/local/sbin/jailadmin start all
	echo -n " Jails"
	;;
stop)
	/usr/local/sbin/jailadmin stop all
	echo -n " Jails"
	;;
*)
	echo "Usage: `basename $0` {start|stop}" >&2
	;;
esac

exit 0
