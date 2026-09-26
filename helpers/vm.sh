#!/bin/bash
# The short VM actions of chaves.omawin, in whichever mode is configured:
#
#   helpers/vm.sh stop      shut Windows down (ACPI, up to the compose's
#                           stop_grace_period) and remove the container
#   helpers/vm.sh pause     freeze the container (docker pause)
#   helpers/vm.sh unpause   thaw it
#   helpers/vm.sh restart   ACPI shutdown, then a fresh QEMU process: what a
#                           Windows warm reboot should be but, under nested
#                           Hyper-V on QEMU/TianoCore, sometimes is not
#
# Omarchy mode runs exactly the command lines the widget always ran:
# `omarchy-windows-vm stop` and `pkexec /usr/bin/docker pause|unpause
# omarchy-windows`, character for character what polkit/49-omawin.rules.in
# allows. Restart adds `pkexec /usr/bin/docker restart --timeout 120
# omarchy-windows`, which the rule does not cover and therefore always asks.
#
# Custom-compose mode (helpers/custom.sh) talks to docker directly: the user is
# in the docker group, and the compose and the container name are the user's.
#
# stdout/stderr are the command's own; the exit status is its status. The
# widget quotes the last stderr line on the card when it is not 0.

set -uo pipefail
export LC_ALL=C

# shellcheck source=helpers/custom.sh
source "${BASH_SOURCE[0]%/*}/custom.sh"
omawin_load

action=${1-}
case $action in
  stop | pause | unpause | restart) ;;
  *) echo "usage: vm.sh stop | pause | unpause | restart" >&2; exit 2 ;;
esac

if ! omawin_custom; then
  case $action in
    stop) exec /usr/bin/omarchy-windows-vm stop ;;
    restart) exec /usr/bin/pkexec /usr/bin/docker restart --timeout 120 omarchy-windows ;;
    *) exec /usr/bin/pkexec /usr/bin/docker "$action" omarchy-windows ;;
  esac
fi

[[ -r $OMAWIN_COMPOSE ]] || { echo "compose file not found: $OMAWIN_COMPOSE" >&2; exit 1; }
case $action in
  stop) exec /usr/bin/docker compose -f "$OMAWIN_COMPOSE" down ;;
  restart) exec /usr/bin/docker restart --timeout 120 "$OMAWIN_CONTAINER" ;;
  *) exec /usr/bin/docker "$action" "$OMAWIN_CONTAINER" ;;
esac
