#!/bin/bash
# Event listener of supervisord: when BIND or Samba gave up starting
# (FATAL), it stops supervisord and with it the container. Docker then
# restarts the container ("restart: unless-stopped"), and the cause is at the
# end of the log instead of a container that runs on without its services.
# stdout is the protocol with supervisord; messages go to stderr.

while true; do
  echo READY
  read -r header
  length=$(sed -nE 's/.*len:([0-9]+).*/\1/p' <<< "$header")
  read -r -N "$length" payload
  program=$(sed -nE 's/.*processname:([^ ]+).*/\1/p' <<< "$payload")
  case "$program" in
    bind|samba)
      echo "samba-ad: ERROR: $program could not be started, see the messages above." >&2
      echo "       Stopping the container; Docker starts it again." >&2
      echo "       See https://stefgo.github.io/samba-ad/troubleshooting/" >&2
      kill -TERM "$(cat /run/supervisord.pid)"
      ;;
  esac
  printf 'RESULT 2\nOK'
done
