# script

> Part of [rebrand-grapheneos](https://github.com/rebrand-grapheneos). See the [main documentation](https://github.com/rebrand-grapheneos/local_manifests) for the complete guide.

Build and release automation scripts for the customized OS. This is a git2 overlay on top of the upstream [GrapheneOS/script](https://github.com/GrapheneOS/script) repository (tag `2025110800`).

## What's Changed

Two files are modified from upstream:

### generate-keys

Generates per-device signing keys for all supported devices.

**Modifications:**
- Added device list: `tokay cheetah felix tegu comet komodo caiman akita husky shiba tangorpro lynx panther bluejay raven oriole`

**Usage:**

```bash
# Run from workspace root (requires AOSP build tools in the tree)
script/generate-keys
```

Each device gets a directory under `keys/<device>/` with:

| Key File | Purpose |
|---|---|
| `releasekey.pk8` / `.x509.pem` | General APK signing |
| `platform.pk8` / `.x509.pem` | Platform-level apps |
| `shared.pk8` / `.x509.pem` | Shared UID apps |
| `media.pk8` / `.x509.pem` | Media framework apps |
| `networkstack.pk8` / `.x509.pem` | Network stack module |
| `bluetooth.pk8` / `.x509.pem` | Bluetooth module |
| `sdk_sandbox.pk8` / `.x509.pem` | SDK sandbox |
| `gmscompat_lib.pk8` / `.x509.pem` | GMS compatibility library |
| `avb.pem` | Android Verified Boot key (RSA 4096, scrypt-encrypted) |
| `avb_pkmd.bin` | AVB public key metadata |

**CN (Common Name):** Set to `GrapheneOS` by default. Change the `CN=GrapheneOS` line in `generate-keys` to your project name.

**Key security:**
- AVB keys use RSA 4096-bit with scrypt encryption
- Use `script/decrypt-keys <dir>` and `script/encrypt-keys <dir>` for key management
- The release script decrypts keys to tmpfs (`/dev/shm/`) during signing for security

### generate-release.sh

Signs and packages OTA updates, factory images, and install bundles.

**Modifications:**
- Added `--skip_compatibility_check` flag to `ota_from_target_files` (line 171)

**Why `--skip_compatibility_check`?**

When building a rebranded OS, the build fingerprint differs from the original GrapheneOS fingerprint. Without this flag, `ota_from_target_files` rejects the OTA generation due to a fingerprint mismatch. The flag bypasses this validation.

**Usage:**

```bash
script/generate-release.sh <device> <build_number>

# Example
script/generate-release.sh cheetah 2025110800
```

**What it does:**

1. Decrypts signing keys to tmpfs (`/dev/shm/`)
2. Unpacks `otatools.zip` from the build output
3. Signs all APKs and APEX packages (169+ packages) with custom keys
4. Generates signed OTA update zip
5. Creates factory images (`img` zip)
6. Creates install bundle with signature
7. Cleans up decrypted keys

**Output:**

```
releases/<build_number>/release-<device>-<build_number>/
├── <device>-ota_update-<build_number>.zip
├── <device>-img-<build_number>.zip
├── <device>-install-<build_number>.zip
└── <device>-install-<build_number>.zip.sig
```

## All Scripts Reference

| Script | Description |
|---|---|
| `generate-keys` | Generate per-device signing keys |
| `generate-release.sh` | Sign and package a single device release |
| `generate-releases.sh` | Generate releases for multiple devices |
| `generate-deltas.sh` | Generate delta OTA updates |
| `generate-delta.sh` | Generate a single delta OTA |
| `generate-metadata` | Extract metadata from OTA zip |
| `finalize.sh` | Stage build artifacts for signing |
| `encrypt-keys` | Encrypt signing keys |
| `decrypt-keys` | Decrypt signing keys |
| `common.sh` | Shared configuration and functions |
| `build-releases` | Distributed build orchestration |
| `fork` | Repository forking helper |

## git2 Usage

```bash
# Sync project changes to .git2/
cd script
.git2/git2.sh push

# Commit and push
cd .git2
git add -A
git commit -m "update: add new device support"
git push
```

## Upstream Reference

- Repository: [GrapheneOS/script](https://github.com/GrapheneOS/script)
- Tag: `2025110800`
- Commit: `2b1e08dd71fc34023b9999c24988027aa98ba7f6`
