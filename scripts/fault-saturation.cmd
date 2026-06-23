@echo off
setlocal
echo fault-saturation is deprecated because it enables CPU and disk faults together. 1>&2
echo Use scripts\fault-cpu.cmd for Incident 4 CPU pressure or scripts\fault-disk.cmd for Incident 3 disk pressure. 1>&2
exit /b 1
