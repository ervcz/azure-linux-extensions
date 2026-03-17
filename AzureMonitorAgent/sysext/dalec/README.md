# AMA Sysext Build (DALEC)

Builds Azure Monitor Agent sysext images for Flatcar using
[DALEC](https://github.com/project-dalec/dalec).

## Usage

```bash
./build.sh x86_64 1.41.0 \
    /path/to/azuremonitoragent_1.41.0_x86_64.deb \
    /path/to/extension-dir
```

The extension directory must contain:

```
amaCoreAgentBin/amacoreagent_{x86_64,aarch64}
amaCoreAgentBin/liblz4x64.so                        (x86_64 only)
agentLauncherBin/agentlauncher_{x86_64,aarch64}
MetricsExtensionBin/metricsextension_{x86_64,aarch64}
AstExtensionBin/*                                    (x86_64 only)
azureotelcollector/azureotelcollector_*_{amd64,arm64}.deb   (optional)
```

Output: `azuremonitoragent-v<VERSION>-<ARCH>.raw` (EROFS sysext image).

## How it works

```
azuremonitoragent .deb  --\
                           +--->  DALEC  --->  .raw sysext image
extras .deb (built by  ---/
  build.sh from loose
  extension binaries)
```

1. `build.sh` packs the loose extension binaries (amacoreagent,
   agentlauncher, MetricsExtension, etc.) plus the sysusers.d and
   tmpfiles.d configs into a small extras `.deb`.

2. Both `.deb` files go to DALEC via the `trixie-pkg` build context.
   DALEC extracts them and produces an EROFS sysext image.

DALEC handles `/etc` -> `/usr/share` relocation, `extension-release`
metadata, and the EROFS filesystem.

## Packages

**azuremonitoragent** -- the signed `.deb` from the CRT pipeline, passed
unchanged. Contains mdsd, fluent-bit, telegraf, shared libs, init script,
and service file copies in `opt/.../share/`.

**azuremonitoragent-extras** -- built by `build.sh`. Wraps the loose
extension binaries (amacoreagent, agentlauncher, MetricsExtension,
AstExtension, liblz4) plus sysusers.d and tmpfiles.d configs.

**azureotelcollector** (optional) -- skipped in local builds because its
postinst tries to start systemd services inside the build container.

## Service files

The AMA `.deb` ships service files in two places:
- `/etc/systemd/system/` -- excluded by DALEC (not valid in sysexts)
- `/opt/microsoft/azuremonitoragent/share/` -- kept as-is

At install time, `sysext_handler.install_via_sysext()` copies them from
`share/` to `/etc/systemd/system/` (writable on Flatcar).

## Design notes

**`dependencies.sysext` is empty on purpose.** Our packages come via the
`trixie-pkg` build context, not from external repos. Listing them under
`sysext:` would make DALEC try to download them from Debian repos.

**`/etc` content is relocated automatically.** DALEC moves `/etc` files
to `/usr/share/azuremonitoragent/etc/` with `C+` tmpfiles entries.
This does not matter in practice -- `enable()` rewrites all config files
before starting services.

## Requirements

- Docker with BuildKit
- `dpkg-deb`

## Pipeline integration

After `packaging.sh` creates the extension zip, the pipeline calls
`build.sh` for each architecture. The `.raw` images and SHA256 checksums
are added to the zip via `zip -u`. The sysext build is optional -- if
Docker or dpkg-deb are missing, it is skipped with a warning.

## Files

| File | What it does |
|------|-------------|
| `build.sh` | Build extras `.deb`, run DALEC |
| `azuremonitoragent.yml` | DALEC spec |
| `../azuremonitoragent.tmpfiles` | Runtime directories and env file |
| `../azuremonitoragent.sysusers` | syslog user/group |