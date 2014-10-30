#!/bin/sh -
#
# This file should be edited and installed in /etc/init.d/.
#
# $Id: init_script.sh 2292 2009-03-10 22:55:10Z bawden $
#
# chkconfig: 345 70 30
#
### BEGIN INIT INFO
# Provides:          rdfherd_server
# Required-Start:    $local_fs $syslog $network $named $remote_fs
# Required-Stop:     $local_fs $syslog $network $named $remote_fs
# Default-Start:     3 4 5
# Default-Stop:      0 1 2 6
# Short-Description: RDFHerd Server
# Description:       Start an RDFHerd server instance running
### END INIT INFO

# LSB utilities:
. /lib/lsb/init-functions

# Set this to your server's directory:
SERVER_DIR=/server/directory

# Set this to the user that the server should be running as -- this should
# match the require_user setting in the server's Config.pl file:
SERVER_USER=virtuoso

# If you installed RDFHerd with a non-standard prefix, you might have to
# modify this -- this is where Perl executables are stored on every Linux
# distribution I know of, but yours might differ...
RDFHERD_BIN=/usr/bin/rdfherd

# Uncomment this if you want to create a traditional PID file for some reason:
#PID_FILE="--pidfile /var/run/rdfherd_server.pid"

SERVICE="$SERVER_DIR"

rdfherd_cmd()
{
    test -f "$RDFHERD_BIN" || return 5
    test -x "$RDFHERD_BIN" || return 4
    su -s /bin/sh -c '"$@"' "$SERVER_USER" -- xx "$RDFHERD_BIN" "$SERVER_DIR" "$@"
    return $?
}

case "$1" in
    start)
	rdfherd_cmd start $PID_FILE
	val=$?
	if [ $val -eq 0 ] ; then
	    log_success_msg "Started $SERVICE"
	else
	    log_failure_msg "Failed to start $SERVICE (error $val)"
	fi
	exit $val
	;;
    stop)
	rdfherd_cmd stop
	val=$?
	if [ $val -eq 0 ] ; then
	    log_success_msg "Stopped $SERVICE"
	else
	    log_warning_msg "Failed to stop $SERVICE (error $val)"
	fi
	exit $val
	;;
    restart)
	rdfherd_cmd restart $PID_FILE
	val=$?
	if [ $val -eq 0 ] ; then
	    log_success_msg "Restarted $SERVICE"
	else
	    log_warning_msg "Failed to restart $SERVICE (error $val)"
	fi
	exit $val
	;;
    force-reload)
	rdfherd_cmd force_reload $PID_FILE
	val=$?
	if [ $val -eq 0 ] ; then
	    log_success_msg "Reloaded $SERVICE"
	else
	    log_warning_msg "Failed to reload $SERVICE (error $val)"
	fi
	exit $val
	;;
    status)
	rdfherd_cmd status
	exit $?
	;;
    *)
	echo "Usage: $0 {start|stop|status|restart|force-reload}"
	exit 3
	;;
esac
