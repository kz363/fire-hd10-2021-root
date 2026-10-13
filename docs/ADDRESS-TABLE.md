# `selinux_enforcing` address table + recovery pipeline

The SnuSnuRoot P2b write step needs the virtual address of the `selinux_enforcing`
kernel global for **your exact firmware build**. It is build-specific, it lives in
`.bss` (so it is absent from the kernel image file), and Amazon ships
`CONFIG_KALLSYMS_ALL=n` (so kallsyms excludes it too). The address must be recovered
from the **code that writes the variable**.

## Verified table

| Fire OS | Build (incremental) | `selinux_enforcing` VA | Source | Verified |
|---|---|---|---|---|
| 7.3.2.6 | PS7326.3178N | `0xffffff8009969668` | disassembly of `enforcing_setup`; PA `0x41969668` independently runtime-verified (reads `1` while Enforcing) by ericpardee/fire-hd-ownership | ✅ PA-level |
| **7.3.2.9** | **PS7329.3842N** | **`0xffffff800996d668`** | disassembly of `enforcing_setup` (this repo); validated by the runtime oracle (write → `getenforce=Permissive`, 2-for-2 boots) | ✅ full chain |
| 7.3.3.1 | PS7331.4460N | `0xffffff8009971668` | hardcoded in upstream SnuSnuRoot binaries — author-verified upstream (method not documented in their repo) | ✅ upstream |

Per-build evidence subdirectories under `docs/<BuildID>-evidence/` are the
scaling pattern for this table: the table stays a summary index; full
disassemblies, logs, and sha256s live in each build's evidence dir. If the
table exceeds ~10 rows, migrate it to a JSON/YAML manifest generated from the
evidence dirs.

> ⚠️ **Informational only — do NOT extrapolate.** A constant `+0x4000` delta
> happens to align across PS7326 → PS7329 → PS7331 for `selinux_enforcing`, but
> **`.bss` variable layout is not a linear function of build number**: adding new
> kernel config options, rearranging linker sections, or changing struct layout
> upstream of a `.bss` global shifts it arbitrarily. The estimate we tried by
> section-delta arithmetic was off by `0x5cce8`. For any new build, recover
> the address by disassembly of `enforcing_setup` (pipeline below) — never
> extrapolate.

## Recovery pipeline (~10 minutes, no kernel access needed)

Official Fire OS OTA images are served openly from Amazon's S3. Build IDs and URLs:
[fireos-archive/fireos-archive](https://github.com/fireos-archive/fireos-archive)
(`data/Fire_HD_10_Gen_11/Fire_HD_10_Gen_11_<ver>.json`).

**OTA format assumption.** Fire OS 7.3.x full-OTAs for `trona` are **AOSP-style
zip with `boot.img` at root** (verified for PS7329.3842N via fireos-archive). The
pipeline below assumes that format. For **`payload.bin`-style OTAs** (A/B
incremental OTAs and some newer formats), use `payload-dumper` against
`payload.bin` first to extract `boot.img`, then resume at step 3.

```bash
# 1. Download the OTA for your build (URL from the JSON above)
curl -L -o ota.bin "<the url>"

# 2. It's a zip: extract the boot image
python3 -c "import zipfile; zipfile.ZipFile('ota.bin').extract('boot.img')"

# 3. The kernel is gzip'd at offset 0x800 (AOSP mkbootimg convention: one page
#    header + kernel at page 2); decompress to the raw arm64 Image
python3 - <<'EOF'
import zlib
data = open('boot.img','rb').read()
d = zlib.decompressobj(16+zlib.MAX_WBITS)
out = d.decompress(data[0x800:])
rest = d.unused_data
while rest[:3] == b'\x1f\x8b\x08':
    d = zlib.decompressobj(16+zlib.MAX_WBITS)
    out += d.decompress(rest); rest = d.unused_data
open('vmlinux','wb').write(out)
print(len(out), out[56:60])   # must print ... b'ARMd'
EOF

# 4. Reconstruct an ELF with a symbol table (kallsyms text symbols are enough —
#    we only need the ADDRESS of the function enforcing_setup)
pip install vmlinux-to-elf          # needs gcc + libc6-dev for the minilzo wheel
vmlinux-to-elf vmlinux vmlinux.elf
readelf -s vmlinux.elf | grep -w enforcing_setup
#    e.g. PS7329: ffffff80091b9e78

# 4b. Fallback if `enforcing_setup` is not in the symbol table: CONFIG_KALLSYMS
#    may have been trimmed or the function renamed. Try, in order:
#    a) `readelf -s vmlinux.elf | grep -i enforcing` — catches renamed variants
#       (e.g. `selinux_enforcing_init`, `enforcing_setup_legacy`).
#    b) `objdump -d vmlinux.elf | grep -B2 'adrp.*selinux'` — search for stores
#       in selinux-related functions that show the canonical
#       `adrp+str w8,[x9,#<small-offset>]` pair (small offset <4096, the page
#       frame size). Look near any function whose name contains `selinux`,
#       `enforce`, or `policy`; the global write is almost always 4-byte
#       (`str w8, [...]`) into a page-aligned base.
#    c) Once you find the file, get the disassembly:
objdump -d --start-address=0xffffff80091b9e78 --stop-address=0xffffff80091ba020 vmlinux.elf
#    look for the pair:
#      adrp  x9, <page>
#      str   w8, [x9, #<off>]
#    selinux_enforcing = <page> + <off>
#    PS7329: adrp x9, 0xffffff800996d000 ; str w8,[x9,#1640] → 0xffffff800996d668
```

> 🔒 **Securely wipe the unmodified Amazon-signed kernel when you are done.**
> `boot.img`, `vmlinux`, and `vmlinux.elf` contain Amazon's signed kernel;
> keep them only as long as you need them for the address recovery.
> ```bash
> shred -u ota.bin boot.img vmlinux vmlinux.elf
> ```
> (See [VERIFICATION-PS7329.md](VERIFICATION-PS7329.md) for the broader hygiene
> guidance.)

## Cross-validation (do not skip)

The `adrp+str` reading is only trustworthy once cross-checked against an
**independent runtime-verified physical address**. ericpardee/fire-hd-ownership
runtime-verified on PS7326 that **PA `0x41969668` reads `1` while SELinux is
Enforcing**. On arm64 with this kernel's mapping,
`PA = (VA & 0xffffffff) + 0x38000000` (empirically fit to that measured pair —
this is NOT the standard arm64 linear-map formula; do not re-derive it
architecturally). Check: `(0xffffff8009969668 & 0xffffffff) + 0x38000000
= 0x41969668` ✓ exact match. For any new build, confirm the low-32 bits shift
consistently and, once rooted, read the address back (value must be `1` while
Enforcing) before relying on it.

> **Naming the constant.** The `+0x38000000` term above is the **PHYS_OFFSET**
> (DRAM base) for **this MT8183 kernel on the current measured PA/VA pair**. It
> was **empirically fit** to one measured point (the ericpardee cross-validation
> PA on PS7326) — it is NOT derived from the arm64 memory map or from the
> device-tree `memory` reg property. It **must be re-derived per build** (the
> DRAM base can shift between bootloader revisions); the empirical way to do
> that, once you have a rooted device, is `cat /proc/iomem | grep 'System RAM'`
> and read the start address. Treat the `0x38000000` here as a cross-check
> anchor for PS7329, not a portable formula.

## Red flags that your address is WRONG

- Write returns the success status (`0x51…`) but `getenforce` stays `Enforcing`.
- **No kernel panic** either (pstore `/sys/fs/pstore/console-ramoops` stays clean).
  A NULL write to a mapped-but-wrong `.bss` slot is usually silent; a write to an
  unmapped address panics. Silence + no flip = wrong (but mapped) address.
- **Corollary (important).** Silence + no flip + clean pstore on a
  *freshly-harvested* pstore **cannot yet distinguish a wrong-mapped slot from
  an already-zero slot**. A `.bss` global whose initial value is already `0`
  (i.e. a slot that *would* take a `selinux_enforcing` write silently) is
  observationally identical to a wrong-mapped slot — both look like
  "successful write, no flip, no panic". The **only conclusive oracle** is the
  SELinux flip itself (`getenforce=Permissive` after the write). Do not use
  silence as a positive signal; treat silence as "need to check `getenforce`",
  and `getenforce=Permissive` as the *only* positive signal that the address
  is correct for this build.
- Fix: re-run the pipeline for your exact build; never extrapolate from a neighbor build.
