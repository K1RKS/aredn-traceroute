#!/bin/sh
# Detached helper: sleep then restart uhttpd so Tools pageCache reloads.
# Invoked via setsid from lifecycle hooks (plain `&` is still waited on by apk).
# Args: <install|uninstall> <delay_seconds>

mode="${1:-install}"
delay="${2:-5}"
pidfile=/var/run/aredn-traceroute-uhttpd-delay.pid
intent=/tmp/aredn-traceroute-uhttpd-needed
logfile=/tmp/aredn-traceroute-uhttpd.log

echo $$ > "$pidfile"
sleep "$delay"
rm -f "$pidfile"

if [ "$mode" = "uninstall" ]; then
	# Reinstall/upgrade clears intent — skip this uninstall-scheduled restart.
	[ -f "$intent" ] || exit 0
	rm -f "$intent"
	tag="uninstall"
else
	tag="install"
fi

if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd restart >>"$logfile" 2>&1 || true
fi
date >>"$logfile"
echo "aredn-traceroute uhttpd refresh done ($tag)" >>"$logfile"
exit 0
