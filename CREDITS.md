# Credits — standing on shoulders

This repo is a **build-verification field report** on top of work by others. The
hard research was theirs.

## The chain implemented here

- **voidnullvalue — [SnuSnuRoot](https://github.com/voidnullvalue/SnuSnuRoot)**
  The complete root chain for the Fire HD 10 2021 (trona) family: discovered the
  `time_update` persisted-property injection (P3), assembled P1+P2+P3 into a working
  toolchain, and verified it on Fire OS 7.3.3.1 (PS7331.4460N). Everything in
  `root-firehd10.sh` drives their injector, carrier, and waiter design. This repo
  adds a PS7329.3842N verification and the build-specific address; the heavy lifting
  is theirs.

## The individual primitives

- **CVE-2024-31317 (P1)** — Google/Android security research on the Zygote
  `hidden_api_blacklist_exemptions` command injection (Android 9-11).
- **CVE-2019-2181 (P2)** — binder driver UAF; original reporting by Jann Horn /
  Android ASB. The Fire-specific stateful leak/write weaponization in
  `controlled_target.c` is SnuSnuRoot's.
- **P3** — the `time_update` unquoted-`date` injection is SnuSnuRoot's discovery
  (documented in their `root.md`).

## The address-recovery method

- **ericpardee — [fire-hd-ownership](https://github.com/ericpardee/fire-hd-ownership)**
  Runtime-verified `selinux_enforcing` PA `0x41969668` on PS7326 (content reads `1`
  while Enforcing) and the Mali GPU (CVE-2022-38181 / GHSL-2023-005) root research
  for this device family. Their PA is the cross-validation anchor for the
  disassembly-derived VAs in [ADDRESS-TABLE.md](docs/ADDRESS-TABLE.md).
- **Pro-me3us** — the FireOS "system user" ADB research lineage (XDA), which mapped
  much of the Fire tablet attack surface this chain builds on.
- **R0rt1z2** — amonet/bootROM research and the bootloader-unlock wall of shame
  (the reason this chain targets the OS instead of the boot chain).
- **fireos-archive** — the public index of official Fire OS OTA images (Amazon's own
  S3 bucket) used to recover per-build kernel symbols.
- **vmlinux-to-elf** (Marcelo Moreira de Mello / maintained fork) — the tool that
  reconstructs symbol tables from raw arm64 kernel images.

## Related research NOT used by this chain

These are the alternative root lines for the same device family. **None of them
are used here** — the chain in this repo is the voidnullvalue/SnuSnuRoot P1+P2+P3
chain (zygote injection + binder UAF + `time_update` persisted-property
injection). They are credited because the original research underlies the
parallel Mali-root work that has appeared in the Fire tablet community, and
because the absence of a Mali code path here is worth stating explicitly so
nobody confuses the two.

- **Man Yue Mo (GitHub Security Lab)** — the Arm Mali driver vulnerability
  research (GHSL-2022-054, GHSL-2023-005) underlying the Mali GPU root line
  (CVE-2022-38181). The chain in this repo contains **zero Mali code paths**;
  if you are looking for the Mali exploit, follow this citation, not
  SnuSnuRoot.
- **ericpardee / fire-hd-ownership (Mali track)** — the same author as the
  address-recovery citation, but for the Mali GPU root path; that code path is
  independent of the binder UAF and `time_update` chain documented here.

## Family tree of the underlying bugs

```
CVE-2024-31317 (Zygote) ─┐
CVE-2019-2181  (binder) ─┼─→ SnuSnuRoot chain ─→ PS7331 verified (upstream)
time_update injection ───┘                    └─→ PS7329 verified (this repo)
```

To request an attribution correction, open an issue against this repository.
