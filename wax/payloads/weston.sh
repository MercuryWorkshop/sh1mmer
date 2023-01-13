#!/bin/bash
export PATH="$PATH:/usr/local/bin"
export LD_LIBRARY_PATH="/lib64:/usr/lib64:/usr/local/lib64"
pkill frecon &
sleep 0.5 &
XDG_RUNTIME_DIR=/run MESA_LOADER_DRIVER_OVERRIDE=i965 /usr/local/bin/weston -B drm-backend.so &
disown
