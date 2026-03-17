#!/usr/bin/env python
#
# sysext_handler.py -- systemd-sysext install/uninstall for AMA on Flatcar
#
# All sysext logic lives here: detection, install, uninstall, version queries.
# agent.py calls init() once at startup to wire in logging and command helpers.
#
# NOTE: metrics_ext_handler.py has its own _is_sysext_distro() copy because
# that file is shared with LAD, which does not ship sysext_handler.
#
# Copyright 2021 Microsoft Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import print_function
import os
import re
import platform
import traceback
from shutil import copyfile, rmtree


# ---------------------------------------------------------------------------
# Callbacks from agent.py (set via init(), avoids circular import)
# ---------------------------------------------------------------------------

def _noop_log(msg):
    print(msg)

def _noop_run_command(cmd, check_error=True, log_cmd=True, log_output=True):
    raise RuntimeError("sysext_handler.init() was not called before run_command")

def _noop_remove_localsyslog_configs():
    pass

def _noop_get_uninstall_context():
    return 'complete'

def _noop_cleanup_uninstall_context():
    pass


_log_info = _noop_log
_log_error = _noop_log
_run_command = _noop_run_command
_remove_localsyslog_configs = _noop_remove_localsyslog_configs
_get_uninstall_context = _noop_get_uninstall_context
_cleanup_uninstall_context = _noop_cleanup_uninstall_context


def init(log_info, log_error, run_command,
         remove_localsyslog_configs,
         get_uninstall_context,
         cleanup_uninstall_context):
    """
    Wire up callbacks from agent.py. Must be called once before
    install/uninstall. Read-only queries (is_sysext_distro, etc.) work without it.
    """
    global _log_info, _log_error, _run_command
    global _remove_localsyslog_configs
    global _get_uninstall_context, _cleanup_uninstall_context

    _log_info = log_info
    _log_error = log_error
    _run_command = run_command
    _remove_localsyslog_configs = remove_localsyslog_configs
    _get_uninstall_context = get_uninstall_context
    _cleanup_uninstall_context = cleanup_uninstall_context


# ---------------------------------------------------------------------------
# Sysext distro detection
# ---------------------------------------------------------------------------

# Cached so we don't re-read /etc/os-release on every call
# (metrics_watcher polls every 30s).
_sysext_distro_cached = None

def is_sysext_distro():
    """
    Return True if running on a distro that uses sysext (Flatcar, osguard).
    """
    global _sysext_distro_cached
    if _sysext_distro_cached is not None:
        return _sysext_distro_cached

    result = False
    try:
        os_release = {}
        with open('/etc/os-release', 'r') as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    key, value = line.split('=', 1)
                    os_release[key] = value.strip('"\'')

        if 'flatcar' in os_release.get('ID', '').lower():
            result = True
        elif 'osguard' in os_release.get('VARIANT_ID', '').lower():
            result = True

    except Exception as e:
        try:
            _log_info("Error checking for sysext distro: {0}".format(e))
        except Exception:
            pass

    _sysext_distro_cached = result
    return result


# ---------------------------------------------------------------------------
# Version and state helpers
# ---------------------------------------------------------------------------

def get_sysext_info():
    """
    Return (arch, version) for the sysext image filename.
    arch uses systemd format ('x86-64' not 'x86_64').
    version is read from agent.version in the extension directory.
    """
    arch_map = {
        'x86_64': 'x86-64',
        'amd64': 'x86-64',
        'aarch64': 'arm64',
        'arm64': 'arm64'
    }
    arch = arch_map.get(platform.machine(), platform.machine())

    version = None
    version_file = os.path.join(os.getcwd(), 'agent.version')
    try:
        with open(version_file, 'r') as f:
            for line in f:
                if line.startswith('AGENT_VERSION='):
                    version = line.split('=')[1].strip().strip('"\'')
                    break
    except Exception as e:
        _log_error("Failed to read agent version: {0}".format(e))

    return arch, version


def is_sysext_merged(sysext_name="azuremonitoragent"):
    """Return True if the sysext overlay is active."""
    symlink_path = "/etc/extensions/{0}.raw".format(sysext_name)
    if not os.path.islink(symlink_path):
        return False

    test_file = "/opt/microsoft/azuremonitoragent/bin/mdsd"
    return os.path.exists(test_file)


# Regex for filename: azuremonitoragent-v1.39.0-x86-64.raw
# Can't use rsplit("-",1) because arch can contain hyphens (x86-64).
_SYSEXT_FILENAME_RE = re.compile(
    r'^azuremonitoragent-v(?P<version>[\d.]+)-(?P<arch>.+)\.raw$'
)


def get_installed_sysext_version():
    """
    Read the installed version from the sysext symlink target filename.
    Returns (is_installed, version_string).
    """
    symlink_path = "/etc/extensions/azuremonitoragent.raw"

    if not os.path.islink(symlink_path):
        return False, None

    try:
        target = os.readlink(symlink_path)
        basename = os.path.basename(target)
        m = _SYSEXT_FILENAME_RE.match(basename)
        if m:
            return True, m.group('version')
    except Exception as e:
        _log_info("Error reading sysext symlink: {0}".format(e))

    if is_sysext_merged():
        return True, "unknown"

    return False, None


# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

def install_via_sysext():
    """
    Install AMA via systemd-sysext.

    Steps: create users, copy the .raw image, merge the overlay, install
    service files, create directories, write VM-specific config files.

    Returns (exit_code, message).
    """
    sysext_name = "azuremonitoragent"
    arch, version = get_sysext_info()

    if not version:
        return 1, "Failed to determine AMA version"

    versioned_name = "{0}-v{1}-{2}.raw".format(sysext_name, version, arch)
    sysext_source = os.path.join(os.getcwd(), "sysext", versioned_name)

    if not os.path.exists(sysext_source):
        return 1, "Sysext image not found: {0}".format(sysext_source)

    opt_path = "/opt/aks/{0}".format(sysext_name)
    symlink_path = "/etc/extensions/{0}.raw".format(sysext_name)
    dest_path = os.path.join(opt_path, versioned_name)

    _log_info("Installing AMA via sysext: {0}".format(versioned_name))

    _installed_units = []

    try:
        # 1. Create syslog user/group (must exist before any chown)
        _log_info("Ensuring syslog user/group exist")
        _run_command("getent group syslog >/dev/null 2>&1 || groupadd --system syslog",
                     check_error=False)
        _run_command("getent passwd syslog >/dev/null 2>&1 || "
                     "useradd -M --shell /usr/sbin/nologin --gid syslog --system syslog",
                     check_error=False)

        # Add syslog to himds group if it exists (needed for Arc MSI tokens)
        _run_command("getent group himds >/dev/null 2>&1 && "
                     "usermod -a -G himds syslog || true",
                     check_error=False)

        # 2. Create storage directory
        os.makedirs(opt_path, exist_ok=True)

        # 3. Copy sysext image
        _log_info("Copying sysext image to {0}".format(opt_path))
        if os.path.exists(dest_path):
            os.remove(dest_path)
        copyfile(sysext_source, dest_path)

        # 4. Remove old images left over from prior upgrades
        for old_file in os.listdir(opt_path):
            old_path = os.path.join(opt_path, old_file)
            if old_file.endswith('.raw') and old_path != dest_path:
                try:
                    os.remove(old_path)
                    _log_info("Removed old sysext image: {0}".format(old_file))
                except Exception as e:
                    _log_info("Could not remove old sysext image {0}: {1}".format(
                        old_file, e))

        # 5. Create/update symlink in /etc/extensions/
        os.makedirs("/etc/extensions", exist_ok=True)
        if os.path.islink(symlink_path) or os.path.exists(symlink_path):
            os.remove(symlink_path)
        os.symlink(dest_path, symlink_path)
        _log_info("Created symlink: {0} -> {1}".format(symlink_path, dest_path))

        # 6. Reload sysext (mounts the overlay + triggers daemon-reload).
        # Note: sysusers.d and tmpfiles.d are NOT auto-triggered.
        _log_info("Reloading systemd-sysext")
        exit_code, output = _run_command("systemctl reload systemd-sysext")
        if exit_code != 0:
            os.remove(symlink_path)
            os.remove(dest_path)
            return exit_code, "systemd-sysext reload failed: {0}".format(output)

        # 7. Verify the overlay is actually active
        if not is_sysext_merged(sysext_name):
            os.remove(symlink_path)
            os.remove(dest_path)
            return 1, "Sysext merge verification failed"

        _log_info("Sysext merged successfully")

        # 8. Copy service files from opt/.../share/ to /etc/systemd/system/
        # (writable on Flatcar). Otelcollector units are in
        # /usr/lib/systemd/system/ from the overlay and don't need copying.
        share_dir = "/opt/microsoft/azuremonitoragent/share"
        systemd_dir = "/etc/systemd/system"
        if os.path.isdir(share_dir):
            for entry in sorted(os.listdir(share_dir)):
                if entry.endswith(".service") or entry.endswith(".path"):
                    src = os.path.join(share_dir, entry)
                    dst = os.path.join(systemd_dir, entry)
                    if os.path.isfile(src):
                        copyfile(src, dst)
                        _installed_units.append(entry)
                        _log_info("Installed {0} -> {1}".format(
                            entry, systemd_dir))

        if _installed_units:
            _run_command("systemctl daemon-reload", check_error=False)
            _log_info("Installed {0} systemd unit(s)".format(
                len(_installed_units)))

        # 9. Run sysusers.d (redundant with step 1 but matches tmpfiles expectations)
        _run_command(
            "systemd-sysusers /usr/lib/sysusers.d/azuremonitoragent.conf "
            "2>/dev/null || true",
            check_error=False)

        # 10. Run tmpfiles.d
        # DALEC's 10-azuremonitoragent.conf copies /etc config templates.
        # Our azuremonitoragent.conf creates /var/opt, /run dirs, etc.
        _run_command(
            "test -f /usr/lib/tmpfiles.d/10-azuremonitoragent.conf && "
            "systemd-tmpfiles --create "
            "/usr/lib/tmpfiles.d/10-azuremonitoragent.conf || true",
            check_error=False)
        _run_command(
            "systemd-tmpfiles --create "
            "/usr/lib/tmpfiles.d/azuremonitoragent.conf",
            check_error=False)

        # 11. Fallback: create directories if tmpfiles missed them
        critical_dirs = [
            "/etc/opt/microsoft/azuremonitoragent/config-cache",
            "/etc/opt/microsoft/azuremonitoragent/amacoreagent",
            "/etc/opt/microsoft/azuremonitoragent/oms",
            "/etc/opt/microsoft/azuremonitoragent/syslog",
            "/etc/opt/microsoft/azuremonitoragent/tenants",
            "/var/opt/microsoft/azuremonitoragent/log",
            "/var/opt/microsoft/azuremonitoragent/events",
        ]
        for d in critical_dirs:
            if not os.path.exists(d):
                os.makedirs(d, exist_ok=True)
                _run_command("chown syslog:syslog {0}".format(d),
                             check_error=False)

        # 12. Create empty env file (enable() expects it to exist)
        env_file = "/etc/default/azuremonitoragent"
        if not os.path.isfile(env_file):
            with open(env_file, "w") as f:
                f.write("")
            _log_info("Created empty environment file: {0}".format(env_file))

        # 13. Write DMI info (VM-specific, not part of the sysext image)
        _write_dmi_info()

        # 14. Write install info (unique install UUID for telemetry)
        _write_install_info()

        return 0, "Azure Monitor Agent installed via sysext"

    except Exception as e:
        # Clean up on failure
        try:
            for unit in _installed_units:
                unit_path = os.path.join("/etc/systemd/system", unit)
                if os.path.exists(unit_path):
                    os.remove(unit_path)
            if os.path.islink(symlink_path):
                os.remove(symlink_path)
            _run_command("systemctl reload systemd-sysext", check_error=False)
            if os.path.exists(dest_path):
                os.remove(dest_path)
        except Exception:
            pass
        return 1, "Sysext installation failed: {0}\n{1}".format(
            e, traceback.format_exc())


# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

def uninstall_via_sysext():
    """
    Uninstall AMA sysext.

    On 'update' context: keeps config/data dirs for the new version.
    On 'complete' uninstall: removes everything.

    Returns (exit_code, message).
    """
    sysext_name = "azuremonitoragent"
    symlink_path = "/etc/extensions/{0}.raw".format(sysext_name)
    opt_path = "/opt/aks/{0}".format(sysext_name)

    _log_info("Uninstalling AMA sysext")

    try:
        # 0. Check if this is part of an update or a full uninstall
        uninstall_context = _get_uninstall_context()
        _log_info("Sysext uninstall context: {0}".format(uninstall_context))

        # 1. Stop all services
        services = [
            "azuremonitoragent", "azuremonitoragentmgr",
            "azuremonitor-agentlauncher", "azuremonitor-coreagent",
            "azuremonitor-astextension", "metrics-extension",
            "metrics-sourcer",
            "azureotelcollector", "azureotelcollector-watcher.path",
        ]
        for svc in services:
            _run_command(
                "systemctl stop {0} 2>/dev/null || true".format(svc),
                check_error=False)
            _run_command(
                "systemctl disable {0} 2>/dev/null || true".format(svc),
                check_error=False)

        # 2. Remove syslog configs
        _remove_localsyslog_configs()

        # 3. Remove sysext symlink
        if os.path.islink(symlink_path):
            os.remove(symlink_path)
            _log_info("Removed symlink: {0}".format(symlink_path))

        # 4. Reload sysext to unmount the overlay
        _run_command("systemctl reload systemd-sysext")

        # 5. Remove sysext image storage
        if os.path.exists(opt_path):
            rmtree(opt_path)
            _log_info("Removed sysext storage: {0}".format(opt_path))

        # 6. Reload systemd
        _run_command("systemctl daemon-reload")

        # 7. Clean up runtime files (always, regardless of context)
        cleanup_paths = [
            "/etc/default/azuremonitoragent",
            "/etc/logrotate.d/azuremonitoragent",
            "/etc/logrotate.d/azuremonitoragent.disabled",
            "/etc/logrotate.d/azuremonitoragentextension",
            "/run/azuremonitoragent",
            "/run/azuremetricsext",
        ]

        # Collect unit files we copied during install
        systemd_dir = "/etc/systemd/system"
        if os.path.isdir(systemd_dir):
            for entry in sorted(os.listdir(systemd_dir)):
                if entry.startswith(("azuremonitoragent", "azuremonitor-",
                                     "azureotelcollector")):
                    if entry.endswith((".service", ".path")):
                        cleanup_paths.append(
                            os.path.join(systemd_dir, entry))

        # Runtime-created units (not from opt/.../share/)
        for runtime_unit in ["metrics-extension.service",
                             "metrics-sourcer.service"]:
            runtime_path = os.path.join(systemd_dir, runtime_unit)
            if runtime_path not in cleanup_paths:
                cleanup_paths.append(runtime_path)

        # On full uninstall, also remove config and data dirs.
        # During updates these must survive for the new version.
        if uninstall_context == "complete":
            _log_info("Full uninstall -- removing config and data directories")
            cleanup_paths.extend([
                "/etc/opt/microsoft/azuremonitoragent",
                "/var/opt/microsoft/azuremonitoragent",
            ])
        else:
            _log_info("Update -- preserving config and data directories")

        for path in cleanup_paths:
            if os.path.exists(path):
                if os.path.isdir(path):
                    rmtree(path)
                else:
                    os.remove(path)
                _log_info("Removed: {0}".format(path))

        # 8. Clean up uninstall context marker
        _cleanup_uninstall_context()

        return 0, "Azure Monitor Agent sysext uninstalled"

    except Exception as e:
        return 1, "Sysext uninstallation failed: {0}\n{1}".format(
            e, traceback.format_exc())


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _write_dmi_info():
    """Write VM UUID and OMS cloud ID -- same as what the deb postinst does."""
    dmi_file = "/etc/opt/microsoft/azuremonitoragent/dmiinfo.txt"
    uuid = ""
    omscloud_id = ""

    try:
        with open("/sys/devices/virtual/dmi/id/product_uuid", "r") as f:
            uuid = f.read().strip().lower()
    except Exception:
        pass

    try:
        with open("/sys/devices/virtual/dmi/id/chassis_asset_tag", "r") as f:
            asset_tag = f.read().strip()
            if asset_tag.startswith("77"):
                omscloud_id = asset_tag
    except Exception:
        pass

    try:
        with open(dmi_file, "w") as f:
            f.write("{0}\n{1}\n".format(uuid, omscloud_id))
        _run_command("chown syslog:syslog {0}".format(dmi_file),
                     check_error=False)
        _run_command("chmod 640 {0}".format(dmi_file),
                     check_error=False)
    except Exception as e:
        _log_info("Failed to write DMI info: {0}".format(e))


def _write_install_info():
    """Write a unique install UUID (same as deb postinst, using /proc)."""
    info_file = "/etc/opt/microsoft/azuremonitoragent/installinfo.txt"
    try:
        install_id = ""
        if os.path.exists("/proc/sys/kernel/random/uuid"):
            with open("/proc/sys/kernel/random/uuid", "r") as f:
                install_id = f.read().strip()
        with open(info_file, "w") as f:
            f.write("{0}\n".format(install_id))
        _run_command("chown syslog:syslog {0}".format(info_file),
                     check_error=False)
        _run_command("chmod 640 {0}".format(info_file),
                     check_error=False)
    except Exception as e:
        _log_info("Failed to write install info: {0}".format(e))
