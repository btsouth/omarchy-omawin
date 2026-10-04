#!/bin/bash
# What the VM is using, for the card. Prints ONE line; every key is always
# present, empty when it cannot be read:
#
#   cpu=8123456789 used=24696061952
#
#   cpu   usage_usec from the cpu.stat of the QEMU's container cgroup: CPU
#         time used since the container started, in microseconds. One reading says nothing; the
#         card turns two of them into a percentage.
#   used  what ~/.windows/data.img really occupies on disk, in bytes. The image
#         is sparse: its apparent size is the DISK_SIZE (vm-state.sh's disk=),
#         this is how much of it Windows has written.
#
# No memory reading, on purpose: Windows touches all of its RAM soon after it
# boots, so from out here it always reads as the VM's RAM plus QEMU's own, and
# the cgroup's memory.current adds the page cache of whatever the container
# read or wrote (gigabytes during an install). What Windows itself uses is
# only visible inside Windows.
#
# Usage: usage.sh [PID]. PID is the QEMU vm-state.sh found; without one (the
# VM is off) only `used` is read. Run only while the card is open: it is not
# part of the 5 s sample, whose line stays what it was.
#
# Like vm-state.sh: no docker CLI, no privileges, only world-readable /proc
# and /sys files and one `stat`.
#
# Environment (all optional, the defaults are the real system):
#   PROC_ROOT   procfs root           (default /proc)
#   SYS_ROOT    sysfs root            (default /sys)
#   DATA_IMAGE  the guest disk image  (default ~/.windows/data.img)

set -uo pipefail
export LC_ALL=C

proc_root=${PROC_ROOT:-/proc}
sys_root=${SYS_ROOT:-/sys}
data_image=${DATA_IMAGE:-$HOME/.windows/data.img}

pid=${1-}
[[ -z $pid || $pid =~ ^[0-9]{1,8}$ ]] || {
  echo "usage: usage.sh [PID]" >&2
  exit 2
}

cpu= used=
if [[ -n $pid ]]; then
  # The same cgroup line vm-state.sh reads. Only a docker scope, and no `..`
  # that could walk the path out of the cgroup tree.
  cgpath=
  while IFS= read -r line; do [[ $line == 0::* ]] && cgpath=${line#0::}; done \
    2>/dev/null <"$proc_root/$pid/cgroup"
  if [[ $cgpath == *docker-* && $cgpath != *..* ]]; then
    while read -r key value _; do
      if [[ $key == usage_usec ]]; then cpu=$value; break; fi
    done 2>/dev/null <"$sys_root/fs/cgroup$cgpath/cpu.stat"
  fi
fi
[[ $cpu =~ ^[0-9]{1,19}$ ]] || cpu=

# %b blocks of %B bytes each: what the file occupies, holes not counted.
if blocks=$(/usr/bin/stat -Lc '%b %B' -- "$data_image" 2>/dev/null); then
  read -r count size <<<"$blocks"
  [[ $count =~ ^[0-9]{1,15}$ && $size =~ ^[0-9]{1,6}$ ]] &&
    used=$((10#$count * 10#$size))
fi

printf 'cpu=%s used=%s\n' "$cpu" "$used"
