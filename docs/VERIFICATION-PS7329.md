# Verification report — Fire HD 10 (2021) KFTRWI, Fire OS 7.3.2.9 (PS7329.3842N)

Verification date: 2026-10-12. Single device, operator-owned, serial withheld.
Everything below was executed against the live device and logged.

> **Backing artifacts.** Every claim below is backed by a raw file in
> [`evidence/`](evidence/): `verification-run.log` (the campaign automation's transcript),
> `pstore-audit.txt` (the kernel-fault scan), `getenforce-transitions.txt`
> (Enforcing / Permissive readings), and `deployed-so-sha256.txt` (the staged JNI
> `.so` sha256 from the device side). This file is the prose summary, not the
> source of truth — the source of truth is `evidence/`.

## Device identity (pre-exploit)

```
ro.build.fingerprint = Amazon/trona/trona:9/PS7329.3842N/<device-unique-id-withheld>:user/amz-p,release-keys
ro.build.version.release = 9          (API 28)
ro.build.version.security_patch = 2023-08-01
ro.board.platform = mt8183            kernel: Linux 4.4.146+ aarch64 (built 2024-01-19)
ro.boot.flash.locked = 1              bootloader locked; no fastboot userspace
ro.treble.enabled = true              (irrelevant without unlock)
Mali UAPI = 11.11 (G72, r14p0)
```

`PS7329.3842N` is the final firmware Amazon shipped for this model (no newer OTA
exists; the 2024-01 build postdates the 2023-08 patch level).

## Chain verification, per link

### P1 — CVE-2024-31317 (zygote injection)
- Inject via `settings put global hidden_api_blacklist_exemptions <payload>` then
  delete the key. Carrier spawn confirmed: `IDV2 uid=10100 pid=… context=u:r:amazon_app:s0 elf=ELF64 abi=arm64-v8a jni=/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so`
- Works on PS7329 (upstream only documented PS7331). One-shot per boot; requires the
  WebView zygote alive at injection time (`ZygoteProcess: Can't set API blacklist
  exemptions: no zygote connection` otherwise).

### P2a — CVE-2019-2181 stateful leak
- Success signature: `HWBINDER_STATEFUL result=0x5000000000000000 file=0x4444444444444444 node=0x<tid>`
- Failure modes: `0x5000003d…` (ENODATA — grooming race lost, ~50-70% of boots) and
  `0x40000072…` (EALREADY — primitive spent for this boot).
- Observed: 3 wins out of ~10 fresh boots across verification (after the address fix:
  2-for-2 on first attempts).

### P2b — write to `selinux_enforcing`
- Upstream binaries hardcode the PS7331 address `0xffffff8009971668`. On PS7329 that
  write returns success but does not flip (wrong, mapped .bss slot; zero panics —
  pstore audited, see below).
- Correct PS7329 address **`0xffffff800996d668`**, recovered by disassembling
  `enforcing_setup` (VA `0xffffff80091b9e78`) in the official PS7329 OTA kernel:
  `adrp x9, 0xffffff800996d000 ; str w8, [x9, #1640]`.
- Cross-validation: the same instruction pair in the PS7326 official OTA kernel
  yields `0xffffff8009969668`, whose PA under `(VA & 0xffffffff) + 0x38000000` is
  `0x41969668` — exactly the runtime-verified PA published by
  ericpardee/fire-hd-ownership (content reads `1` while Enforcing on that build).
- With the corrected address: **2-for-2 boots achieved Enforcing → Permissive**
  (`HWBINDER_STATEFUL_WRITE result=0x5100000000000000` → `getenforce=Permissive`).
  This is the read-back oracle: a wrong address cannot produce a system-wide flip.

### P3 — time_update persisted-property injection
- `/system/etc/init/timeupdate.rc`: `service time_update /system/bin/time_update.sh`,
  `user root`, started `on load_persist_props_action` (every boot).
- `/system/bin/time_update.sh` expands `persist.sys.saved_time` **unquoted** into
  `date -u @$store_time` — command injection as uid 0, once per boot.
- Verified: the armed trigger executes the waiter as `u:r:time_update:s0`
  (audit logs: `scontext=u:r:time_update:s0`); the waiter polls `getenforce` and on
  Permissive launches the payload, producing
  `uid=0(root) gid=1000(system) context=u:r:time_update:s0` on `127.0.0.1:4325`.

### Failure modes discovered (and fixed) during verification
1. `setprop` of the trigger through a uid-1000 nc shell evaluates the trigger's
   `$( )` **as uid 1000** before the property is set. Fix: base64-literal method
   (`setprop persist.sys.saved_time "$(printf %s <b64> | toybox base64 -d)"`).
2. The 30s fuse inside the trigger can fire on the *staging* boot when SELinux is
   already Permissive from a previous session, consuming the trigger. Fix: reboot
   immediately once `getprop` confirms the arm.
3. The upstream payload `mkdir`s under `/data/local/tmp` (shell-owned); a root
   waiter that runs in a different context can fail there. Fix: payload uses
   `/data/securedStorageLocation/rootsvc`.

## Post-root results

- `toybox mount -o remount,rw /dev/root /` succeeds (verity is EIO-mode; does not
  block remount under kernel root + Permissive).
- 45 `/system` APK directories deleted (debloat set; every APK backed up first,
  sha256 recorded). Rootfs usage 2.7G/3.4G (80%) → 1.9G/3.4G (**58%**).
- `com.amazon.parentalcontrols` (protected against `pm disable` even at system uid)
  removed at the filesystem level.
- `/system/etc/hosts` Amazon telemetry blocklist installed (persists).
- No OTA exists for this build; file deletions persist across reboots. SELinux
  Permissive and the root listener are in-memory only.

## Safety evidence

- `/sys/fs/pstore/console-ramoops` (264 KB, read as uid 0): **zero** matches for
  `Kernel panic | Oops | Unable to handle kernel | BUG: kernel` across the entire
  the verification, including all wrong-address write boots. The single pattern hit was the
  init INFO line `ramoops: shutdown`.
- **Freshness limitation.** The pstore ring is 264 KB on this kernel; panics
  older than that — i.e. from before the last ~10–50 boots, depending on log
  volume — roll off and are no longer visible. The verification's `pstore-audit.txt`
  only certifies "no kernel panic in the most recent ring"; it cannot certify
  "no panic ever". If you need a fuller audit, drain pstore immediately after
  each attempt and snapshot it (`cat /sys/fs/pstore/console-ramoops >
  evidence/pstore-<timestamp>.txt`).
- Every wrong-address write returned success and left no trace — consistent with the
  write landing in a mapped-but-irrelevant `.bss` slot. (Do not interpret silence as
  safety in general: validate addresses by disassembly, not by probing.)
- Device remained fully functional (launcher, Wi-Fi, adb) after every attempt.

## Kernel-image hygiene (after address recovery)

If you ran the [ADDRESS-TABLE.md](ADDRESS-TABLE.md) pipeline to recover the
address, you now have on disk `ota.bin`, `boot.img`, `vmlinux`, and
`vmlinux.elf` — all of which contain Amazon's signed kernel. Wipe them when
you no longer need them:

```bash
shred -u ota.bin boot.img vmlinux vmlinux.elf
```

`-u` truncates and removes; `shred` overwrites the content with random bytes
before unlinking so the file is not recoverable from the block device. Do NOT
just `rm` — the data persists on the block device until overwritten.

## Reproducibility checklist for other PS7329.3842N units

1. Firmware must be `PS7329.3842N` (Settings → About). Different builds → recover the
   address first (ADDRESS-TABLE.md).
2. Rebuild the JNI lib with `0xffffff800996d668` (README §3) and verify the
   on-device sha256.
3. Use the base64-literal arming method and the immediate-reboot-on-arm (the two bugs
   that look like "the exploit doesn't work" but are arming mistakes).
4. Expect the leak race to need 1-5 fresh boots.
5. Stop immediately on any kernel panic (there is no unbrick path for this device).
