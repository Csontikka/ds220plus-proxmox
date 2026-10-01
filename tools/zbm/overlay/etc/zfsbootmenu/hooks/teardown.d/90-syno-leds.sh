#!/bin/sh
# Right before kexec into the real system: C steady (still the boot loader's part),
# power LED blinks, status blinks green, until synofand in the booted system takes
# over (it switches C off).
/usr/local/sbin/syno-microp 5 9 @
exit 0
