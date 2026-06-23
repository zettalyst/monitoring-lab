set -eu

printf 'fault-saturation is deprecated because it enables CPU and disk faults together.\n' >&2
printf 'Use scripts/fault-cpu.sh for Incident 4 CPU pressure or scripts/fault-disk.sh for Incident 3 disk pressure.\n' >&2
exit 1
