#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 HASP QEMU prototype contributors
"""Check or configure Sentinel's firmware-update guard inside the Linux guest.

Uses the installed runtime's own loopback Admin API, without a proprietary SDK.
`configure` must run before USB attachment. It persists the documented setting,
restarts hasplmd, and verifies the active setting again. It does not attach USB.

Usage: python3 guest_sentinel_admin.py {check,configure}
Every invocation emits one JSON object; success exits 0, failure exits nonzero.
"""

import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


BASE_URL = "http://127.0.0.1:1947/_int_/"
USB_DEVICES = Path("/sys/bus/usb/devices")
REQUEST_TIMEOUT = 3.0
READY_TIMEOUT = 40.0
RESTART_TIMEOUT = 15.0
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
GET_CONFIG = b'<admin><config><element name="*" /></config></admin>'
# Thales Admin API: Changing_ACC_Configuration_Settings.htm.
SET_GUARD = b"<config><no_auto_fwup>1</no_auto_fwup><writeconfig/></config>"


class GuardError(Exception):
    """A safe, stable status message; never includes server or license data."""


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GuardError("http_redirect_refused")


# Do not route loopback administration through environment HTTP proxies.
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())


def request_xml(path, data=None, timeout=REQUEST_TIMEOUT):
    request = urllib.request.Request(
        BASE_URL + path,
        data=data,
        headers={"Content-Type": "text/plain", "Accept": "application/xml"},
        method="POST" if data is not None else "GET",
    )
    try:
        with HTTP.open(request, timeout=timeout) as response:
            if response.status != 200:
                raise GuardError("http_unexpected_status")
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError:
        raise GuardError("http_unexpected_status") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise GuardError("http_unavailable") from None
    if len(body) > MAX_RESPONSE_BYTES:
        raise GuardError("response_too_large")
    try:
        return ET.fromstring(body)
    except ET.ParseError:
        raise GuardError("invalid_xml") from None


def require_admin_success(root):
    codes = root.findall("admin_status/code")
    if root.tag != "admin_response" or len(codes) != 1:
        raise GuardError("admin_status_missing_or_ambiguous")
    if codes[0].text != "0":
        raise GuardError("admin_api_status_nonzero")


def read_config(timeout=REQUEST_TIMEOUT):
    root = request_xml("adminapi/get", GET_CONFIG, timeout)
    require_admin_success(root)
    values = root.findall("config/no_auto_fwup")
    if len(values) != 1 or values[0].text not in ("0", "1"):
        raise GuardError("firmware_guard_missing_or_invalid")
    return values[0].text


def read_runtime_version(timeout=REQUEST_TIMEOUT):
    root = request_xml("diagnostics.xml", timeout=timeout)
    if root.tag != "ACCDiagnostics":
        raise GuardError("runtime_version_unavailable")
    versions = [
        driver.findtext("Version")
        for driver in root.findall("RuntimeInfo/Driver")
        if driver.findtext("Name") == "Run-time Installer"
    ]
    if len(versions) != 1 or not versions[0]:
        raise GuardError("runtime_version_unavailable")
    version = versions[0]
    # Only a numeric version is reported; diagnostics can contain license IDs.
    if len(version) > 64 or any(c not in "0123456789." for c in version):
        raise GuardError("runtime_version_invalid")
    return version


def require_no_sentinel_usb():
    """Fail closed if USB inventory cannot be inspected or vendor 0529 exists."""
    try:
        if not USB_DEVICES.is_dir():
            raise GuardError("usb_inventory_unavailable")
        devices = list(USB_DEVICES.iterdir())
        for device in devices:
            vendor_path = device / "idVendor"
            try:
                vendor = vendor_path.read_text(encoding="ascii").strip().lower()
            except FileNotFoundError:
                # Interface entries have no idVendor; disappearing devices also
                # cannot be configured by the daemon after they disconnect.
                continue
            if vendor == "0529":
                raise GuardError("sentinel_usb_present_configuration_refused")
    except (OSError, UnicodeError):
        raise GuardError("usb_inventory_unreadable") from None


def require_guard(value):
    if value != "1":
        raise GuardError("firmware_updates_not_disabled")


def wait_for_config():
    deadline = time.monotonic() + READY_TIMEOUT
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GuardError("runtime_readiness_timeout")
        try:
            return read_config(timeout=min(REQUEST_TIMEOUT, remaining))
        except GuardError as error:
            # A valid but unsafe response is a failure, not a readiness delay.
            if str(error) != "http_unavailable":
                raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GuardError("runtime_readiness_timeout")
        time.sleep(min(0.25, remaining))


def wait_for_version():
    # The diagnostics endpoint may become ready after the configuration API,
    # and takes longer to generate its response under software emulation.
    deadline = time.monotonic() + READY_TIMEOUT
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GuardError("runtime_readiness_timeout")
        try:
            return read_runtime_version(timeout=min(15.0, remaining))
        except GuardError as error:
            if str(error) != "http_unavailable":
                raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GuardError("runtime_readiness_timeout")
        time.sleep(min(0.25, remaining))


def configure(result):
    require_no_sentinel_usb()
    # Package installation can return before hasplmd has opened its API.
    # Wait for a valid configuration response, not a blind sleep or a retry
    # of an unsafe/malformed response. USB remains detached throughout.
    wait_for_config()
    require_no_sentinel_usb()
    require_admin_success(request_xml("adminapi/set", SET_GUARD))
    result["no_auto_fwup"] = read_config()
    require_guard(result["no_auto_fwup"])
    require_no_sentinel_usb()
    try:
        completed = subprocess.run(
            ["sudo", "-n", "/usr/local/sbin/keybridge-services", "restart-runtime"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=RESTART_TIMEOUT,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise GuardError("runtime_restart_timeout") from None
    except OSError:
        raise GuardError("runtime_restart_unavailable") from None
    if completed.returncode != 0:
        raise GuardError("runtime_restart_failed")
    # Clear the pre-restart observation so failures cannot imply a fresh check.
    result["no_auto_fwup"] = None
    result["no_auto_fwup"] = wait_for_config()
    require_guard(result["no_auto_fwup"])
    require_no_sentinel_usb()
    result["runtime_version"] = wait_for_version()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    result = {"runtime_version": None, "no_auto_fwup": None, "status": "error"}
    exit_code = 1
    try:
        if len(argv) != 1 or argv[0] not in ("check", "check-config", "configure"):
            raise GuardError("usage_check_or_configure_required")
        if sys.platform != "linux":
            raise GuardError("linux_guest_required")
        if argv[0] == "configure":
            configure(result)
        else:
            result["no_auto_fwup"] = wait_for_config()
            require_guard(result["no_auto_fwup"])
            if argv[0] != "check-config":
                result["runtime_version"] = wait_for_version()
        result["status"] = "ok"
        exit_code = 0
    except GuardError as error:
        result["status"] = str(error)
    except KeyboardInterrupt:
        result["status"] = "interrupted"
        exit_code = 130
    except Exception:
        # Keep traces, XML contents, paths, and possible IDs out of the output.
        result["status"] = "unexpected_internal_error"
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
