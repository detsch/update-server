# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Realistic-cadence scene: RealisticDeviceUser polls every 300s ±60s and
# scatters boot times across BOOT_JITTER seconds (default 30 here, override
# on the command line). Pair with SETTLE_TIME to capture a clean steady-state
# window after ramp-up noise subsides. Examples:
#
#   # Stress test baseline alongside realistic cadence, stress wins on RPS:
#   make headless-scenario SCENE=realistic-cadence NUM_DEVICES=5000 RUN_TIME=30m
#
#   # With settled stats — report only reflects post-ramp-up steady state:
#   make headless-scenario SCENE=realistic-cadence SETTLE_TIME=120 RUN_TIME=30m
#
#   # Also include admin traffic:
#   make headless-scenario SCENE=realistic-cadence LOCUST_ARGS="RealisticDeviceUser PerfAdminUser"
LOCUST_ARGS := RealisticDeviceUser
BOOT_JITTER ?= 30
