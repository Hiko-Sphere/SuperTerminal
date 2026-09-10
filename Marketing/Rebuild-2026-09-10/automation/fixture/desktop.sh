#!/bin/bash
# A genuine X desktop, served over RFB by x11vnc.
#
# x11vnc rather than Xvnc on purpose. Both are real VNC servers, but x11vnc is built on
# LibVNCServer — which is the server implementation the app's own VNC suite is tested
# against, so the capture exercises a path that is known to work rather than discovering a
# negotiation difference in the middle of a screenshot run. (TigerVNC's Xvnc accepts the
# app's connection and then exchanges no framebuffer updates with it; that is worth a bug
# report, but it is not something a marketing capture should be blocked on.)
#
# Bound to the loopback address inside the container: the app reaches it through a
# direct-tcpip channel on the SSH connection, which is exactly the "nothing exposed to the
# internet" route the screenshot claims.
set -e
export DISPLAY=:1
Xvfb :1 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &
for _ in $(seq 1 50); do [ -e /tmp/.X11-unix/X1 ] && break; sleep 0.2; done
xsetroot -solid '#1f242b'
fluxbox >/tmp/fluxbox.log 2>&1 &
sleep 1
# A terminal with something live in it, so the desktop is a desktop rather than a wallpaper.
# Sized to fill most of the 1280x800 display: a desktop that is mostly empty grey reads
# as a broken screenshot rather than as a machine somebody is working on.
xterm -geometry 148x34+16+16 -fa 'DejaVu Sans Mono' -fs 11 \
      -bg '#11151a' -fg '#c8d2dc' -title 'deploy@edge-01' -e htop >/dev/null 2>&1 &
sleep 1
x11vnc -display :1 -rfbport 5901 -localhost -nopw -forever -shared -quiet \
       -desktop edge-01 >/tmp/x11vnc.log 2>&1 &
