#!/bin/bash
# Starts Samba once BIND answers, so that Samba's first DNS update at start
# does not fail. A program of supervisord.

for _ in $(seq 30); do
  if nc -z 127.0.0.1 53; then
    break
  fi
  sleep 1
done

exec /usr/sbin/samba --foreground --no-process-group --debug-stdout
