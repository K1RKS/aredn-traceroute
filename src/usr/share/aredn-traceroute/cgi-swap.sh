#!/bin/sh
# Shared paths / helpers for aredn-traceroute CGI + Tools UI swap (sourced by install scripts).
OURS=/usr/share/aredn-traceroute/cgi-bin-traceroute
DEFAULT=/usr/share/aredn-traceroute/traceroute.firmware.default
CGI=/www/cgi-bin/traceroute
BACKUP=/etc/aredn-traceroute/traceroute.firmware

UI_OURS=/usr/share/aredn-traceroute/traceroute.ut
UI_DEFAULT=/usr/share/aredn-traceroute/traceroute.ut.firmware.default
UI=/app/main/tools/e/traceroute.ut
UI_BACKUP=/etc/aredn-traceroute/traceroute.ut.firmware

ATR_UHTTPD_DELAY_PID=/var/run/aredn-traceroute-uhttpd-delay.pid
ATR_UHTTPD_INTENT=/tmp/aredn-traceroute-uhttpd-needed
ATR_UHTTPD_HELPER=/usr/share/aredn-traceroute/uhttpd-delay-run.sh

is_ours_cgi() {
    [ -f "$1" ] && grep -q 'aredn_traceroute' "$1" 2>/dev/null
}

is_ours_ui() {
    [ -f "$1" ] && grep -q 'aredn-traceroute-ui' "$1" 2>/dev/null
}

backup_stock_cgi() {
    mkdir -p /etc/aredn-traceroute
    if [ -f "$CGI" ] && [ ! -f "$BACKUP" ] && ! is_ours_cgi "$CGI"; then
        cp -a "$CGI" "$BACKUP"
    fi
}

install_ours_cgi() {
    if [ -f "$OURS" ]; then
        cp -a "$OURS" "$CGI"
        chmod 755 "$CGI"
    fi
}

restore_stock_cgi() {
    if [ -f "$BACKUP" ]; then
        cp -a "$BACKUP" "$CGI"
        chmod 755 "$CGI"
        return 0
    fi
    if [ -f "$DEFAULT" ]; then
        cp -a "$DEFAULT" "$CGI"
        chmod 755 "$CGI"
        return 0
    fi
    return 1
}

backup_stock_ui() {
    mkdir -p /etc/aredn-traceroute
    if [ -f "$UI" ] && [ ! -f "$UI_BACKUP" ] && ! is_ours_ui "$UI"; then
        cp -a "$UI" "$UI_BACKUP"
    fi
}

install_ours_ui() {
    if [ -f "$UI_OURS" ] && [ -d "$(dirname "$UI")" ]; then
        cp -a "$UI_OURS" "$UI"
        chmod 644 "$UI"
    fi
}

restore_stock_ui() {
    if [ -f "$UI_BACKUP" ]; then
        cp -a "$UI_BACKUP" "$UI"
        chmod 644 "$UI"
        return 0
    fi
    if [ -f "$UI_DEFAULT" ] && [ -d "$(dirname "$UI")" ]; then
        cp -a "$UI_DEFAULT" "$UI"
        chmod 644 "$UI"
        return 0
    fi
    return 1
}

cancel_delayed_uhttpd() {
    if [ -f "$ATR_UHTTPD_DELAY_PID" ]; then
        opid=$(cat "$ATR_UHTTPD_DELAY_PID" 2>/dev/null)
        [ -n "$opid" ] && kill "$opid" 2>/dev/null || true
        rm -f "$ATR_UHTTPD_DELAY_PID"
    fi
}

schedule_uhttpd_after_uninstall() {
    delay="${1:-10}"
    touch "$ATR_UHTTPD_INTENT"
    cancel_delayed_uhttpd
    [ -x "$ATR_UHTTPD_HELPER" ] || return 0
    setsid "$ATR_UHTTPD_HELPER" uninstall "$delay" </dev/null >/dev/null 2>&1 &
}

schedule_uhttpd_after_install() {
    delay="${1:-5}"
    rm -f "$ATR_UHTTPD_INTENT"
    cancel_delayed_uhttpd
    [ -x "$ATR_UHTTPD_HELPER" ] || return 0
    setsid "$ATR_UHTTPD_HELPER" install "$delay" </dev/null >/dev/null 2>&1 &
}
