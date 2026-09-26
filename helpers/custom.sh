#!/bin/bash
# Custom-compose mode for chaves.omawin: a Windows VM that runs from the user's
# own docker compose file instead of Omarchy's `omarchy-windows-vm` helper.
#
# The mode is on when the config file names a compose file:
#
#   ~/.config/omawin/config      (or $XDG_CONFIG_HOME/omawin/config)
#     COMPOSE_FILE=~/windows-vm/compose.yaml
#
# Everything else is read out of that compose file: the container name
# (`container_name:`), the guest disk directory (the volume mounted on
# /storage), the shared folder (the one on /shared) and the login (USERNAME and
# PASSWORD in the service's `environment:` block). The user is expected to be
# in the docker group, so nothing in this mode is privileged: no pkexec, no
# polkit rule, and the compose is the user's own file to rewrite.
#
# Sourced by the other helpers for its functions, or run directly:
#
#   helpers/custom.sh info   one key=value per line (paths may hold spaces):
#                              mode=custom|omarchy, config, compose, container,
#                              storage, shared, exists=1|0
#   helpers/custom.sh set    KEY=VALUE lines on STDIN, rewritten into the
#                            compose's environment block, atomically, with the
#                            previous file kept as <compose>.omawin.bak.
#                            Only RAM_SIZE, CPU_CORES, DISK_SIZE and PASSWORD.
#                            Values arrive on stdin because a password must
#                            never be an argument (/proc/<pid>/cmdline is
#                            world-readable).
#
# Environment (optional; the tests point these at fixtures):
#   OMAWIN_CONFIG   the config file (default $XDG_CONFIG_HOME/omawin/config)

set -uo pipefail
export LC_ALL=C

omawin_config=${OMAWIN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/omawin/config}

# ~/x, $HOME/x and ${HOME}/x to absolute; anything relative is taken relative
# to $2 (the compose file's directory, the way compose resolves volumes).
omawin_expand() {
  local path=$1 base=${2:-$HOME}
  # shellcheck disable=SC2088 # matching a literal ~ from the config, on purpose
  case $path in
    "~") path=$HOME ;;
    "~/"*) path=$HOME/${path#"~/"} ;;
    "\$HOME"*) path=$HOME${path#"\$HOME"} ;;
    "\${HOME}"*) path=$HOME${path#"\${HOME}"} ;;
  esac
  [[ $path == /* ]] || path=$base/${path#./}
  printf '%s' "$path"
}

# Strips one level of YAML quoting and compose's $$ escape off a scalar. A
# quoted scalar ends at its closing quote, so a ` # comment` after it is
# ignored; so is one after an unquoted scalar.
omawin_unquote() {
  local value=$1 out= i c
  value=${value#"${value%%[![:space:]]*}"}
  case ${value:0:1} in
    \")
      for ((i = 1; i < ${#value}; i++)); do
        c=${value:i:1}
        if [[ $c == "\\" ]]; then
          i=$((i + 1))
          c=${value:i:1}
        elif [[ $c == \" ]]; then
          break
        fi
        out+=$c
      done
      ;;
    \')
      for ((i = 1; i < ${#value}; i++)); do
        c=${value:i:1}
        if [[ $c == \' ]]; then
          [[ ${value:i+1:1} == \' ]] || break
          i=$((i + 1))
        fi
        out+=$c
      done
      ;;
    *)
      out=${value%%[[:space:]]#*}
      out=${out%"${out##*[![:space:]]}"}
      ;;
  esac
  printf '%s' "${out//\$\$/\$}"
}

# The inverse, for writing: always double-quoted, with \ " and $ escaped.
omawin_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\$\$}
  printf '"%s"' "$value"
}

# One variable of the compose's environment block, map form (`KEY: value`) or
# list form (`- KEY=value`), unquoted. Status 1 when it is not there.
omawin_env() {
  local key=$1 raw item
  [[ $key =~ ^[A-Z_][A-Z0-9_]*$ && -r ${OMAWIN_COMPOSE-} ]] || return 1
  # awk finds the line; M<value> for map form, L<whole item> for list form,
  # where the quotes (if any) wrap KEY=value as one scalar.
  raw=$(/usr/bin/awk -v want="$key" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*(#|$)/ { next }
    {
      if (inenv && indent($0) <= envind) inenv = 0
      if (!inenv && $0 ~ /^[[:space:]]*environment:[[:space:]]*$/) { inenv = 1; envind = indent($0); next }
      if (!inenv) next
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^- /) {
        sub(/^- +/, "", line)
        bare = line
        sub(/^["\047]/, "", bare)
        if (index(bare, want "=") == 1) { print "L" line; found = 1; exit }
      } else if (index(line, want ":") == 1) {
        print "M" substr(line, length(want) + 2); found = 1; exit
      }
    }
    END { exit found ? 0 : 1 }' "$OMAWIN_COMPOSE" 2>/dev/null) || return 1
  if [[ $raw == L* ]]; then
    item=$(omawin_unquote "${raw#L}")
    printf '%s' "${item#"$key="}"
  else
    omawin_unquote "${raw#M}"
  fi
}

# The host side of the volume mounted on $1 (/storage, /shared), absolute.
omawin_volume() {
  local dest=$1 line src
  [[ -r ${OMAWIN_COMPOSE-} ]] || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ $line == -* ]] || continue
    line=${line#-}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    line=${line#[\"\']}
    line=${line%[\"\']}
    [[ $line =~ ^(.+):${dest}(:[a-z,]+)?$ ]] || continue
    src=${BASH_REMATCH[1]}
    omawin_expand "$src" "${OMAWIN_COMPOSE%/*}"
    return 0
  done <"$OMAWIN_COMPOSE"
  return 1
}

# Reads the config and the compose once. Sets:
#   OMAWIN_MODE       custom | omarchy
#   OMAWIN_COMPOSE    the compose file (custom mode; may not exist)
#   OMAWIN_CONTAINER  its container_name, default omarchy-windows
#   OMAWIN_STORAGE    the /storage source, default ~/.windows
#   OMAWIN_SHARED     the /shared source, default ~/Windows
omawin_load() {
  OMAWIN_MODE=omarchy OMAWIN_COMPOSE= OMAWIN_CONTAINER=omarchy-windows
  OMAWIN_STORAGE=$HOME/.windows OMAWIN_SHARED=$HOME/Windows
  local key value line name
  if [[ -r $omawin_config ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
      key=${line%%=*}
      value=$(omawin_unquote "${line#*=}")
      [[ $key == COMPOSE_FILE && -n $value ]] || continue
      OMAWIN_MODE=custom
      OMAWIN_COMPOSE=$(omawin_expand "$value")
    done <"$omawin_config"
  fi
  [[ $OMAWIN_MODE == custom && -r $OMAWIN_COMPOSE ]] || return 0
  name=$(/usr/bin/sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' -- "$OMAWIN_COMPOSE" | /usr/bin/head -n 1)
  name=$(omawin_unquote "$name")
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] && OMAWIN_CONTAINER=$name
  value=$(omawin_volume /storage) && OMAWIN_STORAGE=$value
  value=$(omawin_volume /shared) && OMAWIN_SHARED=$value
  return 0
}

omawin_custom() { [[ $OMAWIN_MODE == custom ]]; }

# Rewrites environment variables of the compose in place. Takes KEY=VALUE
# names as arguments; each value is read from OMAWIN_V_<KEY>, so a caller can
# hand over a password without it ever being an argv string:
#
#   OMAWIN_V_PASSWORD=$pw omawin_set PASSWORD
#
# Map form only (`KEY: value`); the key has to be there already. The file is
# rewritten atomically next to itself with its own mode, and the old one is
# kept as <compose>.omawin.bak.
omawin_set() {
  local compose=$OMAWIN_COMPOSE dir tmp next key
  [[ -f $compose && -w $compose ]] || { echo "cannot write $compose" >&2; return 1; }
  dir=${compose%/*}
  tmp=$(/usr/bin/mktemp "$dir/.omawin.XXXXXX") || return 1
  /usr/bin/cp -p -- "$compose" "$tmp" || { rm -f -- "$tmp"; return 1; }
  for key in "$@"; do
    [[ $key =~ ^[A-Z_][A-Z0-9_]*$ ]] || { rm -f -- "$tmp"; echo "not a variable name: $key" >&2; return 1; }
    local var=OMAWIN_V_$key
    next=$(/usr/bin/mktemp "$dir/.omawin.XXXXXX") || { rm -f -- "$tmp"; return 1; }
    if ! OMAWIN_NEW=$(omawin_quote "${!var-}") /usr/bin/awk -v want="$key" '
      function indent(s) { match(s, /^ */); return RLENGTH }
      {
        if ($0 !~ /^[[:space:]]*(#|$)/) {
          if (inenv && indent($0) <= envind) inenv = 0
          if (!inenv && $0 ~ /^[[:space:]]*environment:[[:space:]]*$/) { inenv = 1; envind = indent($0); print; next }
          if (inenv && !done) {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (index(line, want ":") == 1) {
              match($0, /^[[:space:]]*/)
              print substr($0, 1, RLENGTH) want ": " ENVIRON["OMAWIN_NEW"]
              done = 1
              next
            }
          }
        }
        print
      }
      END { exit done ? 0 : 3 }' "$tmp" >"$next"; then
      rm -f -- "$tmp" "$next"
      echo "$key is not set in the environment block of $compose" >&2
      return 1
    fi
    /usr/bin/cat -- "$next" >"$tmp" && rm -f -- "$next"
  done
  if ! /usr/bin/cp -p -- "$compose" "$compose.omawin.bak" || ! /usr/bin/mv -fT -- "$tmp" "$compose"; then
    rm -f -- "$tmp"
    echo "could not replace $compose" >&2
    return 1
  fi
}

omawin_info() {
  local exists=0 cores= ram= disk=
  if [[ -n $OMAWIN_COMPOSE && -r $OMAWIN_COMPOSE ]]; then
    exists=1
    # The shape the next start will use, straight from the compose.
    cores=$(omawin_env CPU_CORES) || cores=
    ram=$(omawin_env RAM_SIZE) || ram=
    disk=$(omawin_env DISK_SIZE) || disk=
    [[ $cores =~ ^[0-9]{1,4}$ ]] || cores=
    [[ $ram =~ ^[0-9]{1,3}G$ ]] || ram=
    [[ $disk =~ ^[0-9]{1,4}G$ ]] || disk=
  fi
  printf 'mode=%s\nconfig=%s\ncompose=%s\ncontainer=%s\nstorage=%s\nshared=%s\nexists=%s\ncores=%s\nram=%s\ndisk=%s\n' \
    "$OMAWIN_MODE" "$omawin_config" "$OMAWIN_COMPOSE" "$OMAWIN_CONTAINER" \
    "$OMAWIN_STORAGE" "$OMAWIN_SHARED" "$exists" "$cores" "$ram" "$disk"
}

# stdin: KEY=VALUE lines, split on the first = so a password may hold one.
omawin_set_stdin() {
  local line key keys=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    key=${line%%=*}
    case $key in
      RAM_SIZE | CPU_CORES | DISK_SIZE | PASSWORD) ;;
      *) echo "not a key omawin writes: $key" >&2; return 2 ;;
    esac
    printf -v "OMAWIN_V_$key" '%s' "${line#*=}"
    keys+=("$key")
  done
  ((${#keys[@]})) || { echo "nothing to write" >&2; return 2; }
  omawin_set "${keys[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  omawin_load
  case ${1-} in
    info) omawin_info ;;
    set)
      omawin_custom || { echo "not in custom-compose mode: no COMPOSE_FILE in $omawin_config" >&2; exit 2; }
      omawin_set_stdin || exit $?
      echo ok
      ;;
    *) echo "usage: custom.sh info | custom.sh set <KEY=VALUE lines on stdin>" >&2; exit 2 ;;
  esac
fi
