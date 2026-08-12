# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

import os
import queue
import random
import time

import locust
from locust import HttpUser, constant, events

DEFAULT_DEVICE_DIR = "/data/fake-devices"
DEFAULT_CERTS_DIR = "/data/certs"
DEFAULT_NUM_DEVICES = 5000
DEFAULT_DEVICE_TAG = "main"
DEFAULT_BOOT_JITTER = 0
DEFAULT_SETTLE_TIME = 0

_device_queue: "queue.Queue[int]" = queue.Queue()


class DeviceConfig:
    """Resolved from CLI args/env vars in the init event, before any User spawns."""

    device_dir = DEFAULT_DEVICE_DIR
    certs_dir = DEFAULT_CERTS_DIR
    num_devices = DEFAULT_NUM_DEVICES
    device_tag = DEFAULT_DEVICE_TAG
    boot_jitter_secs = DEFAULT_BOOT_JITTER
    settle_time_secs = DEFAULT_SETTLE_TIME
    app_blob_hash = ""


@events.init_command_line_parser.add_listener
def _add_device_args(parser, **_kwargs):
    parser.add_argument(
        "--num-devices",
        env_var="NUM_DEVICES",
        default=str(DEFAULT_NUM_DEVICES),
        type=int,
        help="Number of fake devices available.",
    )
    parser.add_argument(
        "--device-dir",
        env_var="DEVICE_DIR",
        default=DEFAULT_DEVICE_DIR,
        help="Base directory containing device-<n>/ sub-directories.",
    )
    parser.add_argument(
        "--certs-dir",
        env_var="CERTS_DIR",
        default=DEFAULT_CERTS_DIR,
        help="Directory containing root.crt.",
    )
    parser.add_argument(
        "--device-tag",
        env_var="DEVICE_TAG",
        default=DEFAULT_DEVICE_TAG,
        help="Value sent in the x-ats-tags header.",
    )
    parser.add_argument(
        "--boot-jitter",
        env_var="BOOT_JITTER",
        default=str(DEFAULT_BOOT_JITTER),
        type=int,
        help=(
            "Max seconds to scatter device boot times (uniform [0, N]). "
            "0 = all devices boot simultaneously (default, stress-test behaviour). "
            "Set e.g. 30 for realistic-cadence runs so 5000 devices don't all "
            "fire their boot PUTs in the same two-second ramp-up window."
        ),
    )
    parser.add_argument(
        "--settle-time",
        env_var="SETTLE_TIME",
        default=str(DEFAULT_SETTLE_TIME),
        type=int,
        help=(
            "Seconds after Locust starts before resetting all stats counters. "
            "0 = disabled (default). Set to cover ramp-up + a buffer so the "
            "final report reflects only the steady-state window, not the "
            "registration burst. Example: 2000 devices at 80/s takes ~25s to "
            "ramp; SETTLE_TIME=60 gives 35s of clean steady-state before the "
            "reset fires."
        ),
    )


@events.init.add_listener
def _resolve_device_config(environment, **_kwargs):
    # Must run at the init event, not at import time: Locust only finishes
    # parsing argv (and merging in env_var= defaults) right before firing
    # init, so anything read at module import sees stale/default values.
    opts = environment.parsed_options
    DeviceConfig.device_dir = opts.device_dir
    DeviceConfig.certs_dir = opts.certs_dir
    DeviceConfig.num_devices = opts.num_devices
    DeviceConfig.device_tag = opts.device_tag
    DeviceConfig.boot_jitter_secs = opts.boot_jitter
    DeviceConfig.settle_time_secs = opts.settle_time

    # App blob hash seeded by gen-certs --seed-update; optional — AppPullFlow
    # skips gracefully if the file doesn't exist (e.g. SEED_UPDATE=0 runs).
    hash_file = os.path.join(os.path.dirname(opts.certs_dir), "app-blob-hash.txt")
    if os.path.exists(hash_file):
        with open(hash_file) as f:
            DeviceConfig.app_blob_hash = f.read().strip()

    for i in range(1, DeviceConfig.num_devices + 1):
        _device_queue.put(i)


@events.init.add_listener
def _schedule_stats_reset(environment, **_kwargs):
    """After settle_time_secs, reset all Locust counters for a clean steady-state window.

    Fires once via gevent.spawn_later so it never blocks the event loop. The
    HTML report and CSVs written at run-end then reflect only the post-reset
    window — ramp-up noise and the first-contact registration burst are gone.
    """
    settle = getattr(environment.parsed_options, "settle_time", 0)
    if settle <= 0:
        return

    import gevent

    def _do_reset():
        print(
            f"\n[perf-test] settle window ({settle}s) elapsed — resetting stats; "
            "report will reflect steady-state traffic only.\n",
            flush=True,
        )
        environment.runner.stats.reset_all()

    gevent.spawn_later(settle, _do_reset)


class DeviceUser(HttpUser):
    abstract = True
    wait_time = constant(0)

    def on_start(self) -> None:
        try:
            idx = _device_queue.get_nowait()
        except queue.Empty:
            self.stop()
            return

        client_pem = f"{DeviceConfig.device_dir}/device-{idx}/client.pem"
        root = f"{DeviceConfig.certs_dir}/root.crt"
        for path in (client_pem, root):
            if not os.path.exists(path):
                raise FileNotFoundError(path)

        # Combined cert+key file — requests/urllib3 accepts a single PEM path
        self.client.cert = client_pem
        self.client.verify = root
        self._idx = idx
        self._boot()

    def _boot(self) -> None:
        """Fire boot-phase system_info PUTs exactly once, as a real device does at startup.

        Staggered by boot_jitter_secs when set: devices scatter their first
        contact across the jitter window instead of all hitting the SQLite
        writer in the same two-second ramp-up burst. Jitter defaults to 0 for
        stress-test runs (constant(0) PerfUser); set it for realistic-cadence
        runs where you want independent phase offsets to emerge naturally.
        """
        if DeviceConfig.boot_jitter_secs > 0:
            time.sleep(random.uniform(0, DeviceConfig.boot_jitter_secs))

        # Hardware fingerprint — any valid JSON accepted; server stores it verbatim.
        self.client.put(
            "/system_info",
            json={"hardware-id": "perf-qemu-amd64", "uuid": f"perf-device-{self._idx}"},
            headers=self._headers(),
            name="/system_info (boot)",
        )
        # aktualizr-lite's running sota.toml — raw TOML, no server-side validation.
        self.client.put(
            "/system_info/config",
            data="[uptane]\npolling_sec = 300\n",
            headers={"Content-Type": "application/toml", **self._headers()},
            name="/system_info/config (boot)",
        )
        # Network interface snapshot — server validates against NetworkInfo struct.
        lo = self._idx
        self.client.put(
            "/system_info/network",
            json={
                "hostname": f"perf-device-{self._idx}",
                "local_ipv4": f"10.{(lo >> 16) & 0xff}.{(lo >> 8) & 0xff}.{lo & 0xff}",
                "mac": f"de:ad:{(lo >> 8) & 0xff:02x}:{lo & 0xff:02x}:00:01",
            },
            headers=self._headers(),
            name="/system_info/network (boot)",
        )

    def _headers(self, target: str | None = None, ostreehash: str | None = None) -> dict:
        return {
            "x-ats-tags": DeviceConfig.device_tag,
            "x-ats-target": target or "perf-target-1",
            "x-ats-ostreehash": ostreehash or "0" * 64,
        }

    def _fail(self, resp, msg: str) -> None:
        resp.failure(f"device-{self._idx} {msg}")
