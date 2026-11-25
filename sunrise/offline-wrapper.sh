#!/bin/sh
# Run the Sunrise client without --developer-single-player.
#
# Why this exists
# ---------------
# `--developer-single-player` is not an offline mode, it is a lock on the whole
# account layer. With that flag the client forces its session to None, and then
# five separate places refuse traffic: `--server` fails at startup, opening a
# world to the LAN fails, listening on the LAN fails, joining any remote server
# fails, and there is no account to make a LAN key pair with. The message is
# "Offline developer session: single-player only." Single-player works because
# nothing else is left.
#
# Without the flag there is no session either -- but the client takes the
# `Ok(None)` branch, which refuses nothing. It builds a LAN key pair, hosts in
# offline mode, and joins servers under the offline UUID of `--name`. That is how
# the Horizon launcher side-steps the very same flag.
#
# This runs as a `wrapper` hook from the launcher's own profile settings, so no
# binary is rebuilt and nothing is patched. It drops that one argument and runs
# the rest unchanged.
#
# Note that `PLAY-OFFLINE.sh` does not need this at all: it starts the client
# itself and never passes the flag. Keep this file for the case where you launch
# the bundled build from the launcher's own Play button instead.
#
# Safe when the flag is absent: the only thing it ever removes is
# `--developer-single-player`; everything else is passed through verbatim.
set -eu

if [ "$#" -eq 0 ]; then
  echo "offline-wrapper: no command to run" >&2
  exit 2
fi

# Rebuild the argument list without the flag. Each kept argument is escaped for
# re-parsing, then `eval set --` installs the list: the portable way to filter
# argv in POSIX sh, and quoted so arguments with spaces or quotes survive.
args=
dropped=0
for arg in "$@"; do
  if [ "$arg" = "--developer-single-player" ]; then
    dropped=$((dropped + 1))
    continue
  fi
  escaped=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
  args="$args '$escaped'"
done

if [ "$dropped" -gt 0 ]; then
  echo "offline-wrapper: dropped --developer-single-player ($dropped), keeping the offline identity and multiplayer/LAN" >&2
fi

eval "set -- $args"

if [ "$#" -eq 0 ]; then
  echo "offline-wrapper: every argument was --developer-single-player, nothing left to run" >&2
  exit 2
fi

exec "$@"
