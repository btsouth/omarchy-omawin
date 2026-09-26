#!/bin/bash
# Start (if needed) and connect to a custom-compose Windows VM, for
# chaves.omawin. The custom-mode counterpart of `omarchy-windows-vm launch -k`,
# run the same way: inside the transient user unit `omawin-launch` (see
# helpers/launch.sh), blocking for the whole RDP session.
#
#   1. `docker compose up -d` unless the container is already running
#   2. wait for dockur's "windows started successfully" in the logs of the
#      current run (2 min, like Omarchy's up_wait)
#   3. xfreerdp3 with Omarchy's own arguments, fed on stdin so the password is
#      never in a command line
#
# The VM keeps running when the RDP window closes (Omarchy's --keep-alive).
# The login is the compose's own USERNAME and PASSWORD.

set -uo pipefail
export LC_ALL=C

# shellcheck source=helpers/custom.sh
source "${BASH_SOURCE[0]%/*}/custom.sh"
omawin_load

fail() {
  echo "Failed to start Windows VM"
  echo "$*"
  exit 1
}

omawin_custom || fail "not in custom-compose mode: no COMPOSE_FILE in $omawin_config"
[[ -r $OMAWIN_COMPOSE ]] || fail "compose file not found: $OMAWIN_COMPOSE"

container=$OMAWIN_CONTAINER
status=$(/usr/bin/docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
if [[ $status == paused ]]; then
  /usr/bin/docker unpause "$container" || fail "could not unpause $container"
elif [[ $status != running ]]; then
  echo "Starting Windows VM..."
  /usr/bin/docker compose -f "$OMAWIN_COMPOSE" up -d 2>&1 || fail "docker compose up failed"
fi

# docker logs persists across restarts, so anchor the scan to the current start.
count=0
while true; do
  started_at=$(/usr/bin/docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null)
  if [[ -n $started_at ]] &&
    /usr/bin/docker logs --since "$started_at" "$container" 2>&1 | /usr/bin/grep -qi "windows started successfully"; then
    break
  fi
  ((++count > 60)) && fail "Timeout: Windows VM did not report ready within 2 minutes"
  sleep 2
done

user=$(omawin_env USERNAME) || user=
password=$(omawin_env PASSWORD) || password=
[[ -n $user ]] || user="docker"
[[ -n $password ]] || password="admin"

# FreeRDP 3 tries Kerberos first, and krb5's sample config sends every attempt
# looking for MIT's KDC (~23 s each offline). A realm-less config makes it fall
# straight through to NTLM, as Omarchy's launcher does.
krb5=${XDG_CONFIG_HOME:-$HOME/.config}/omawin/krb5.conf
if [[ ! -f $krb5 ]]; then
  /usr/bin/mkdir -p -- "${krb5%/*}"
  printf '[libdefaults]\n  dns_lookup_kdc = false\n  dns_lookup_realm = false\n' >"$krb5"
fi
export KRB5_CONFIG=$krb5

scale=$(/usr/bin/hyprctl monitors -j 2>/dev/null |
  /usr/bin/jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null |
  /usr/bin/awk '{print int($1 * 100)}')
rdp_scale=
if [[ $scale =~ ^[0-9]+$ ]]; then
  if ((scale >= 170)); then rdp_scale=/scale:180; elif ((scale >= 130)); then rdp_scale=/scale:140; fi
fi

# shellcheck disable=SC2054 # the commas belong to /floatbar's own syntax
args=(
  "/u:$user"
  "/p:$password"
  /v:127.0.0.1:3389
  -grab-keyboard
  /sound
  /microphone
  /clipboard
  /cert:ignore
  "/title:Windows VM - Omarchy"
  /dynamic-resolution
  /gfx:AVC444
  /floatbar:sticky:off,default:visible,show:fullscreen
)
[[ -n $rdp_scale ]] && args+=("$rdp_scale")

# /args-from must be the only argument; FreeRDP rejects it combined with others.
printf '%s\n' "${args[@]}" | /usr/bin/xfreerdp3 /args-from:stdin
echo "RDP session closed. Windows VM is still running."
exit 0
