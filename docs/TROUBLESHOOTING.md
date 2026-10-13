# Troubleshooting — every failure mode encountered on PS7329.3842N

Symptoms are ordered by where they appear in the chain. Each includes the diagnosis
method and the fix.

## 1. `adb devices` shows nothing

- Tablet in MTP mode only → USB debugging is not actually on, or the RSA prompt was
  never accepted. Re-check Developer Options.
- WSL2: WSL adb cannot see USB devices without usbipd; either use `usbipd attach` or
  run the USB-side steps with a Windows adb (`/mnt/c/adb/adb.exe`) and drive the
  device over TCP from WSL (`adb tcpip 5555` once, then `adb connect <ip>:5555`).
- After reboots, TCP adb is off (adbd returns to USB mode). Re-arm from the USB side:
  `<win-adb> tcpip 5555`, then `adb connect <ip>:5555`.

## 2. uid-1000 channel (P1) refuses: `nc: connect: Connection refused`

The injection needs the **WebView zygote** alive at the moment the settings key is
written. `ZygoteProcess: Can't set API blacklist exemptions: no zygote connection`
in logcat means you were too early or the zygote was idle-killed.

Fix: launch any WebView-using activity first (the procedure uses
`monkey -p com.amazon.h2settingsfortablet -c android.intent.category.LAUNCHER 1`),
wait ~3s, then inject. Retry up to 5×; the channel one-shot is per-boot, so a spent
attempt means reboot before retrying.

## 3. The armed trigger is not the trigger: property reads back garbage or a number

**This is the subtlest bug in the whole chain.** If you set the property with a
double-quoted command like:

```sh
adb shell "setprop persist.sys.saved_time \"x[$(sleep 30;/system/bin/sh payload)]000\""
```

…then the **host/nc shell evaluates `$( )` before `setprop` runs**, and the property
receives the *output* of your payload (observed as `x[REROOT paydone uid=1000...]000`).
The waiter then never fires as root.

Fix: the trigger must reach the property **as a literal**. Base64 it and decode
inside the device shell (upstream SnuSnuRoot method):

```sh
TB64=$(printf '%s' "$TRIGGER" | base64 | tr -d '\n')
printf 'setprop persist.sys.saved_time "$(printf %%s %s | toybox base64 -d)"\nexit\n' "$TB64" \
  | adb shell "toybox nc -w 15 127.0.0.1 4321"
```

Verify with `adb shell getprop persist.sys.saved_time` — it must read back the exact
`x[$(sleep 30;...)]000` string.

## 4. The 30-second fuse fires on the staging boot

The P3 trigger embeds `$(sleep 30; /system/bin/sh /data/securedStorageLocation/w/b)`.
Once the property is armed and a `time_update` instance parses it, **b runs 30s
later** — including on the boot where you just armed it (SELinux may already be
Permissive there from a previous session, so b fires immediately and consumes the
trigger, restoring the numeric value).

Fix: the moment `getprop` confirms the trigger is armed, **reboot immediately**.
The fresh boot is where the waiter must run: it parses as root (init `user root`),
waits for Permissive, and only proceeds after your leak+write lands.

## 5. Leak returns `result=0x5000003d…` (or `0x40000072…`) instead of `…00000000`

- `0x50…3d` (ENODATA): the grooming race was lost — the spray didn't reclaim the
  freed node. Expected on ~50-70% of fresh boots. Just reboot and retry.
- `0x40…72` (EALREADY): the stateful primitive is **spent for this boot**. Any later
  attempt on the same boot fails identically. Reboot.
- Success looks like: `result=0x5000000000000000 file=0x4444444444444444 node=0x…`
  (`0x4444…` is the REPLACE_MARKER — the leak's fingerprint). The trailing `node`
  value is a thread id, not a kernel pointer; ignore it.

Empirically on PS7329: ~30-50% of fresh boots win the race. With 5 attempts the
procedure succeeds with high probability.

## 6. Write returns success (`0x51…`) but `getenforce` stays `Enforcing`

Your `selinux_enforcing` address is wrong for this build. This is the failure mode
that cost us the most time — the write silently NULLs some other mapped `.bss`
qword and neither panics nor flips.

- Do NOT guess by section-delta arithmetic between builds (section-delta arithmetic between builds was attempted; it was off by
  0x5cce8). Recover the address properly: [ADDRESS-TABLE.md](ADDRESS-TABLE.md).
- Confirm the deployed `.so` actually carries your address: compare on-device
  `toybox sha256sum` of
  `/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so`
  against your local patched build. Installing over the old file needs the
  uid-1000 channel (the asset dir is system-owned).

## 7. `getenforce=Permissive` but the uid-0 listener never comes up

The P3 waiter fires **only when a `time_update` instance parses the armed property**.
Instances run: (a) at every boot via init (`user root` — this is the one you want),
and (b) on demand via `setprop ctl.start time_update` — but a ctl.start from a
uid-1000 context runs the script **as uid 1000**, not root (verified on this build).

So: arm the trigger, **reboot**, and let the boot-time parse (as root) launch the
waiter. If you armed mid-boot, the waiter will only fire on the next boot — arm
again on a fresh boot via the uid-1000 channel and reboot.

Also check the payload itself: `/data/local/tmp` is `shell(2000)`-owned, so a
payload running as another uid may fail `mkdir` there. This payload uses
`/data/securedStorageLocation/rootsvc` instead.

## 8. `pm` commands fail with `NullPointerException at AppOpsService.checkPackage`

Calling `pm` from the uid-1000/carrier contexts trips a package-uid lookup that
returns null for your caller identity — intermittent (some calls succeed). Run `pm`
from a normal `adb shell` instead, or perform file-level debloat under root.

## 9. `mount -o remount,rw /system` refuses (even as root)

- The root filesystem mounts as `/dev/root`; remount `/dev/root`, not `/system`:
  `toybox mount -o remount,rw /dev/root /`
- toybox mount validates against fstab paths — passing `/dev/block/dm-0` or
  `/dev/block/platform/.../by-name/system` fails with "'/' not in /proc/mounts";
  `/dev/root` is the string it accepts.
- Requires SELinux Permissive first (the whole point of P2b).
- This build's verity is in **EIO mode** — it logs errors but does not block the
  remount under kernel root.

## 10. After deleting /system APK dirs: `ls` says "Structure needs cleaning"

Deleting directories on a mounted ext4 leaves the parent directory's inode in a
state `ls` complains about until the journal replays. It is cosmetic: `sync`, note
that some dirs may remain as empty husks until the next reboot, and verify APKs are
gone (`ls <dir>` → 0 files). The Android package manager will simply skip dirs
whose APK is missing at next boot.

## 11. `adb shell pm uninstall -k --user 0 <pkg>` → `DELETE_FAILED_INTERNAL_ERROR`

FireOS refuses user-0 uninstall of `/system` APKs at the shell uid — this is
package-manager policy, not SELinux. Deleting the APK directories under root is the
reliable route (see the debloat subsection of the walkthrough above).

## 12. Device stuck / panicking

- A kernel write to a genuinely unmapped address panics; the device reboots
  automatically. If it bootloops, the P3 waiter only *waits* (it never reboots on
  its own), so the loop is not self-perpetuating — let it settle, then
  `adb wait-for-device` from USB.
- Recovery of a soft state is always possible via USB adb (the RSA key persists).
- There is **no hard-brick recovery** for this device; every step in the chain only
  touches RAM except the `/system` file deletions, which are backed up first.

## 13. `.so` fails to load / `dlopen` errors

- Symptom: the carrier process spawns, logcat shows `dlopen: library "..." not
  found` or `dlopen failed: wrong ELF class` or `cannot locate symbol`, and the
  P2a/P2b leak/write never happens. The build artifact exists in the staged
  asset dir but the dynamic linker rejects it.
- Cause: the `.so` was built with the **host glibc toolchain** (`aarch64-linux-
  gnu-gcc`) and links against glibc. Android 9 (bionic libc) — the runtime on
  this Fire HD 10 (2021) — does not provide glibc; bionic has a different
  symbol set and ABI for a few pthread / string routines, so the loader refuses.
- Diagnosis:
  ```bash
  adb shell logcat -d | grep -i 'linker\|dlopen'
  # look for "library not found", "wrong ELF class", "cannot locate symbol"
  adb shell 'toybox sha256sum /data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so'
  # also check your host build's interpreter:
  aarch64-linux-gnu-readelf -d build/libhwbinder_target_ps7329.so | grep -i interp
  # glibc builds show "/lib/ld-linux-aarch64.so.1" — bionic does not provide that.
  ```
- Fix:
  - **Recommended:** rebuild with NDK clang targeting Android API 28 — the same
    flags upstream SnuSnuRoot's `build.sh` uses
    (`aarch64-linux-android28-clang -shared -fPIC -O2 -DCONTROLLED_TARGET_LIBRARY
    -Wl,-soname,libhwbinder_target.so -o build/libhwbinder_target_ps7329.so
    controlled_target.c jni_wrapper.c -pthread`). Produces a bionic-compatible
    `.so`.
  - **Alternative:** rebuild with `aarch64-linux-musl-gcc -static` for a fully
    standalone carrier; the static libc avoids the missing-glibc problem at the
    cost of a larger `.so`. (The carrier spawns `app_process`, which then
    `dlopen`s the JNI lib; the JNI lib itself must be bionic-loadable.)
  - Re-stage the corrected `.so` via the uid-1000 channel (step 2) and re-verify
    on-device sha256.

## 14. Text file corrupted after transfer through the nc channel

- Symptom: a small text file (e.g. `/system/etc/hosts`) contains binary garbage
  after a `cat <file> > /system/etc/hosts` transfer through the uid-1000/root
  nc shell. The file is the right size but is full of NUL bytes, escape codes,
  or terminal-control sequences. This happened to the authors with
  `/system/etc/hosts` (566 bytes of garbage in place of a clean blocklist).
- Cause: when a host pushes content through `adb shell ... | nc ...` or a
  reverse-nc pipe, the shell can mangle binary-ish content (embedded NULs,
  escape sequences interpreted by the TTY, line-ending translations) on the way
  to the device-side file. The uid-1000 channel and the root nc channel both
  use a pseudo-TTY on the device, which can corrupt bytes that look like
  control characters.
- Fix: never push binary or text-with-special-bytes content through an nc /
  shell pipe. Use `adb push` to a shell-writable staging dir (`/data/local/tmp`
  is fine), verify the size matches the host, then copy on-device with a
  simple `cat` (no TTY), and verify with `head`/`toybox sha256sum`:
  ```bash
  # host side
  adb push ./hosts /data/local/tmp/hosts
  HOST_SIZE=$(wc -c < ./hosts)
  echo "host size: $HOST_SIZE"
  # device side, as root (e.g. from the 4325 listener)
  DEV_SIZE=$(toybox wc -c < /data/local/tmp/hosts | awk '{print $1}')
  echo "device size: $DEV_SIZE"
  [ "$HOST_SIZE" = "$DEV_SIZE" ] || { echo "SIZE MISMATCH — re-push"; exit 1; }
  toybox sha256sum /data/local/tmp/hosts    # must match the host sha256
  cat /data/local/tmp/hosts > /system/etc/hosts
  head -3 /system/etc/hosts                # eyeball the first lines
  ```
- This is unrelated to the address correctness or the SELinux state; it is a
  pure file-transfer issue. It is silent (no error, no logcat warning) — only
  caught by `wc -c` or `head`.


## 15. `persist.sys.saved_time` not numeric at campaign start

A previous armed trigger was consumed but the waiter never restored the numeric
value (or you armed manually and aborted). A non-numeric leftover is harmless to
the chain but confuses the arming check.

Fix: set it to a plausible past timestamp and reboot once:
`adb shell "setprop persist.sys.saved_time 1700000000000"` — the boot-time
time_update parse will normalize it.

## 16. Carrier PONG timeout / carrier handshake failures

`spawn_carrier` polls `PING→PONG` on 127.0.0.1:43271 up to 20×. Timeout causes:

- Staged assets missing: `adb shell ls /data/securedStorageLocation/codex.amazon.jni.v51/`
  must list `agent.jar`, `libcodex_jni.so`, `libhwbinder_target.arm64-v8a.so`,
  `carrier_launcher.sh`. If anything is missing, re-run the upstream
  `stage_initial_root_assets.sh install`.
- WebView zygote race: the carrier is an app_process spawn; retry after waking a
  WebView-using activity (the script does this automatically before injecting).

## 17. Multiple adb devices / wrong device targeted

`adb` commands without `-s` fail or hit the wrong device when several are attached.
Always export `TAB` (the script dies without it) and verify:

```bash
adb -s "$TAB" shell getprop serialno
```

If the tablet's DHCP lease changed, re-read the IP (Settings → Wi-Fi) and re-run
`adb connect <new-ip>:5555`.

## 18. "Silence + no flip + clean pstore" ambiguity

If the write returns success, `getenforce` stays `Enforcing`, and the pstore audit
is clean, you cannot yet distinguish "wrong-but-mapped .bss slot" from "the slot
was already zero". The only conclusive oracle is the SELinux flip itself
(`getenforce=Permissive`). Re-derive the address (ADDRESS-TABLE.md) rather than
probing neighbors.
