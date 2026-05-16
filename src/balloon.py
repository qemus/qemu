#!/usr/bin/env python3

from __future__ import annotations

import argparse
import asyncio
import collections
import ctypes
import logging
import os
import re
import signal
import sys
import time
from typing import Any, Deque, Dict, Optional, Tuple, cast

from qemu.qmp import QMPClient

log = logging.getLogger(__name__)


CONTAINER_MEM_MARGIN = 128 * (1024 ** 2)  # 128 MB

SMAPS_BLOCK_SIZE_TOLERANCE = 2 * (1024 ** 2) # 2MB: accounts for page alignment/hugepages


# ==========================================================
# Helper Functions
# ==========================================================

def _qmp_int(val: int) -> int:
    """Convert QMP uint64 value to signed int64 (QMP returns 18446744073709551615 for -1)."""
    return ctypes.c_int64(val).value

def get_host_ram_info() -> Optional[tuple[int, int, int]]:
    """Returns (total_bytes, available_bytes, used_bytes) of host physical RAM, or None on error."""
    try:
        meminfo: Dict[str, int] = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                key, val = line.split(':', 1)
                meminfo[key.strip()] = int(val.split()[0]) * 1024  # kB -> bytes
        return meminfo['MemTotal'], meminfo['MemAvailable'], meminfo['MemTotal'] - meminfo['MemAvailable']
    except Exception as e:
        log.error("Error reading /proc/meminfo: %s", e)
        return None

def get_container_mem_info() -> Optional[tuple[int, int, int]]:
    """Returns (limit, allocated, cache) bytes for the container, or None if no limit."""
    try:
        # cgroup v2
        if all(map(os.path.exists, ["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.stat"])):
            with open("/sys/fs/cgroup/memory.max") as f:
                limit_str = f.read().strip()
                if limit_str in ('max', ''):
                    return None
                limit = int(limit_str)
            
            with open("/sys/fs/cgroup/memory.current") as f:
                allocated = int(f.read().strip())
            
            stat: Dict[str, int] = {}
            with open("/sys/fs/cgroup/memory.stat") as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) == 2:
                        stat[parts[0]] = int(parts[1])
            cache = stat.get("file", 0) + stat.get("slab_reclaimable", 0)
            return limit, allocated, cache
            
        # cgroup v1
        elif all(map(os.path.exists, ["/sys/fs/cgroup/memory/memory.limit_in_bytes", "/sys/fs/cgroup/memory/memory.usage_in_bytes", "/sys/fs/cgroup/memory/memory.stat"])):
            with open("/sys/fs/cgroup/memory/memory.limit_in_bytes") as f:
                limit = int(f.read().strip())
            if limit >= (1 << 62):  # unlimited sentinel
                return None
            with open("/sys/fs/cgroup/memory/memory.usage_in_bytes") as f:
                allocated = int(f.read().strip())
            stat = {}
            with open("/sys/fs/cgroup/memory/memory.stat") as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) == 2:
                        stat[parts[0]] = int(parts[1])
            cache = stat.get("cache", 0)
            return limit, allocated, cache

    except Exception as e:
        log.warning("Failed to read container memory info: %s", e)

    return None

def get_host_psi_avg10() -> Optional[float]:
    """Reads /proc/pressure/memory and returns the 'some avg10' float value."""
    try:
        with open('/proc/pressure/memory', 'r') as f:
            for line in f:
                if line.startswith('some'):
                    match = re.search(r'avg10=(\d+\.\d+)', line)
                    if match:
                        return float(match.group(1))
    except FileNotFoundError:
        log.warning("/proc/pressure/memory not found. PSI unavailable (kernel may lack CONFIG_PSI).")
        return None
    except PermissionError:
        log.warning("/proc/pressure/memory: permission denied. Run with elevated privileges or adjust container capabilities.")
        return None
    except Exception as e:
        log.error("Error reading PSI data: %s", e)
        return None
    return None

def byte_size_or_fraction(string: str) -> float | int:
    match = re.match(r'^(\d+(?:\.\d+)?)\s*([a-zA-Z%]*)$', string.strip())
    if not match:
        raise argparse.ArgumentTypeError(f"Invalid size format: '{string}'")

    value_str, suffix = match.groups()
    value = float(value_str)
    suffix = suffix.upper()
    if suffix == '%':
        if value > 100:
            raise argparse.ArgumentTypeError(f"Percentage cannot exceed 100%%: '{string}'")
        return value / 100

    multipliers = {
        'B': 1, 'KB': 1024, 'K': 1024,
        'MB': 1024**2, 'M': 1024**2,
        'GB': 1024**3, 'G': 1024**3,
        'TB': 1024**4, 'T': 1024**4,
        '': 1,
    }

    if suffix not in multipliers:
        raise argparse.ArgumentTypeError(f"Unknown suffix: '{suffix}'")

    bytes_value = int(value * multipliers[suffix])
    if bytes_value <= 1:
        raise argparse.ArgumentTypeError(f"Size must be greater than 1 byte: '{string}'")

    return bytes_value

SMAPS_BLOCK_HEADER_PATTERN = re.compile(r'^([0-9a-f]+-[0-9a-f]+)')

async def _get_host_qemu_guest_mem_rss(qmp: QMPClient, qemu_pid: int) -> Optional[int]:
    """Returns bytes of guest RAM currently in rss, by parsing /proc/<pid>/smaps looking for
    mappings matching qemu memory backend device blocks by sizes."""
    guest_mem_rss = 0
    try:
        qemu_mem_devices = await qmp_get_memory_dev(qmp)

        if qemu_mem_devices is None:
            log.debug("No memory devices found")
            return None

        unmatched_targets = [
            size_bytes
            for node in qemu_mem_devices
            if (size_bytes := node.get("size", 0)) > 0
        ]

        if not unmatched_targets:
            log.debug("No valid memory targets found from memory devices")
            return None

        def check_block(block_size: int) -> int:
            # Check if this block matches one of our expected remaining QMP memory backends.
            # Use a 2MB tolerance to account for page alignment/hugepages.
            matched_target = next(
                (
                    target 
                    for target in unmatched_targets 
                    if abs(block_size - target) <= SMAPS_BLOCK_SIZE_TOLERANCE
                ), 
                None
            )
            
            if matched_target is not None:
                unmatched_targets.remove(matched_target)
                return True
            
            return False

        current_block: Dict[str, int] = {}
        
        with open(f"/proc/{qemu_pid}/smaps", "r") as f:
            for line in f:
                if SMAPS_BLOCK_HEADER_PATTERN.match(line):
                    # New block, handle previous block (if matching a target) and reset the block data.
                    if "Size" in current_block and check_block(current_block["Size"]):
                        guest_mem_rss += current_block.get("Rss", 0)

                    current_block.clear()
                elif len(line_parts := line.split()) == 3:
                    current_block[line_parts[0][:-1]] = int(line_parts[1]) * 1024
            
            # Handle last block
            if "Size" in current_block and check_block(current_block["Size"]):
                guest_mem_rss += current_block.get("Rss", 0)

        # Do note return a value if we have unmatched memory targets (as calculated data would be partial).
        if unmatched_targets:
            log.debug("Unmatched memory targets: %s", unmatched_targets)
            return None
        
    except Exception as e:
        log.warning("Failed to read smaps for pid %d: %s", qemu_pid, e, exc_info=True)
        return None
    
    return guest_mem_rss

# ==========================================================
# QMP helpers using qemu.qmp
# ==========================================================

async def qmp_wait_connected(sock_path: str, interval: int = 5) -> QMPClient:
    """Create and connect a QMPClient, retrying until successful."""
    while True:
        qmp = QMPClient("balloon-monitor")
        try:
            await qmp.connect(sock_path)
            log.debug("QMP connection established.")
            return qmp
        except Exception as e:
            log.debug("QMP connect failed: %s. Retrying in %ds...", e, interval)
            try:
                await qmp.disconnect()
            except (ConnectionError, BrokenPipeError, OSError) as e:
                log.debug("QMP disconnect during retry failed: %s", e)
            await asyncio.sleep(interval)

async def qmp_get_max_mem(qmp: QMPClient) -> int:
    resp = cast(Dict[str, Any], await qmp.execute("query-memory-size-summary"))
    log.debug("get_qemu_max_mem: %s", resp)
    base = _qmp_int(resp["base-memory"])
    plugged = _qmp_int(resp.get("plugged-memory", 0))
    return base + plugged

async def qmp_get_actual_balloon(qmp: QMPClient) -> int:
    resp = cast(Dict[str, Any], await qmp.execute("query-balloon"))
    log.debug("get_qemu_current_balloon_mem: %s", resp)
    return _qmp_int(resp["actual"])

async def qmp_get_guest_ram_stats(qmp: QMPClient) -> Optional[Tuple[int, int, Optional[int]]]:
    """Returns (available_ram - excluding cache -, total_ram, last_update_timestamp), or None if stats are not available.
    last_update_timestamp is the Unix timestamp (seconds) when the guest last updated its stats."""
    resp = cast(Dict[str, Any], await qmp.execute("qom-get", {"path": "/machine/peripheral/balloon0", "property": "guest-stats"}))
    log.debug("get_guest_stats: %s", resp)
    last_update: Optional[int] = resp.get("last-update")
    stats = resp.get("stats", {})
    tot_mem = _qmp_int(stats.get("stat-total-memory", -1))
    if tot_mem >= 0:
        avail_mem = _qmp_int(stats.get("stat-available-memory", -1))
        if avail_mem >= 0:
            return avail_mem, tot_mem, last_update
        free_mem = _qmp_int(stats.get("stat-free-memory", -1))
        cache_mem = _qmp_int(stats.get("stat-disk-caches", -1))
        if free_mem >= 0 and cache_mem >= 0:
            return free_mem - cache_mem, tot_mem, last_update
    return None

async def qmp_get_memory_dev(qmp: QMPClient) -> Optional[list[Dict[str, Any]]]:
    resp = cast(list[Dict[str, Any]], await qmp.execute("query-memdev"))
    log.debug("qmp_get_memory_dev: %s", resp)
    return resp

async def qmp_send_balloon(qmp: QMPClient, target: int) -> bool:
    try:
        await qmp.execute("balloon", {"value": target})
        return True
    except Exception as e:
        log.error("QMP balloon command failed: %s", e)
        return False

# ==========================================================
# Balloon Monitor Class
# ==========================================================

class BalloonMonitor:
    """Encapsulates QEMU memory balloon management with PI control and PSI-based emergency shrinking."""

    def __init__(self, args: argparse.Namespace) -> None:
        self._loop: asyncio.AbstractEventLoop
        self._stop = asyncio.Event()
        self.args = args
        self.qmp: Optional[QMPClient] = None
        self.max_mem: int = -1
        self.min_mem: int = -1
        self.hysteresis: int = -1
        self.host_total: int = -1
        self.initial_guest_stat_mem_total:int = -1
        self.desired_free_ratio = 1.0 - (args.ram_threshold / 100.0)  # e.g. 80% usage -> 0.2 free
        self.hard_free_ratio = 1.0 - (args.ram_threshold_hard / 100.0)
        self.last_target_balloon = 0
        self.error_integral = 0.0
        self._balloon_history: Deque[Tuple[float, int]] = collections.deque(maxlen=128)
        self.event_task: Optional[asyncio.Task[None]] = None
        self._cgroup_event = asyncio.Event()
        self._inotify_fd: int = -1
        self._inotify_wd: int = -1
        with args.qemu_pid_file as f:
            self.qemu_pid = int(f.read().strip())

    def _setup_cgroup_watch(self) -> None:
        path = next((p for p in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes") if os.path.exists(p)), None)
        if path is None:
            return
        
        libc = ctypes.CDLL(None, use_errno=True)
        ifd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if ifd < 0:
            log.warning("inotify_init1 failed: errno=%d", ctypes.get_errno())
            return
        wd = libc.inotify_add_watch(ifd, path.encode(), 0x00000002)
        if wd < 0:
            log.warning("inotify_add_watch failed: errno=%d", ctypes.get_errno())
            os.close(ifd)
            return
        
        self._inotify_fd = ifd
        self._inotify_wd = wd
        self._loop.add_reader(ifd, self._on_cgroup_change)

        log.debug("Watching %s for changes via inotify", path)

    def _on_cgroup_change(self) -> None:
        try:
            os.read(self._inotify_fd, 4096)  # drain events
        except OSError:
            pass
        log.debug("cgroup memory limit changed, triggering main loop and resetting integral calculation")
        self.error_integral = 0.0
        self._cgroup_event.set()

    def _teardown_cgroup_watch(self) -> None:
        if self._inotify_fd >= 0:
            self._loop.remove_reader(self._inotify_fd)
            os.close(self._inotify_fd)
            self._inotify_fd = -1

    def _handle_sigint(self) -> None:
        log.debug("Received SIGINT, terminating.")
        self._stop.set()
        self._loop.remove_signal_handler(signal.SIGINT)

    def _get_qmp(self) -> QMPClient:
        if self.qmp is None:
            raise ConnectionError("QMP not connected")
        return self.qmp

    def _record_balloon(self, value: int) -> None:
        self._balloon_history.append((time.time(), value))

    def _get_balloon_at(self, ts: Optional[float]) -> int:
        """Return the last balloon value recorded at or before ts, -1 if not found, 
        the most recent if ts is None or max_mem if no balloon sample has been recorded."""
        if not self._balloon_history:
            return self.max_mem
        if ts is None:
            return self._balloon_history[-1][1]
        return next(
            (
                b[1] 
                for b in reversed(self._balloon_history) 
                if b[0] <= ts
            ), 
            -1
        )

    async def _qmp_connect(self) -> None:
        self.qmp = await qmp_wait_connected(self.args.qmp_sock, self.args.interval)
        self.event_task = asyncio.create_task(self._qmp_event_listener())
        self._record_balloon(await qmp_get_actual_balloon(self.qmp))

    async def _qmp_event_listener(self) -> None:
        try:
            async for event in self._get_qmp().events:
                if event["event"] in ("POWERDOWN", "SHUTDOWN"):
                    log.debug("Received %s event, terminating.", event["event"])
                    self._stop.set()
                    return
                if event["event"] == "BALLOON_CHANGE" and "data" in event:
                    actual: Optional[int] = cast(Dict[str, Any], event.get("data", {})).get("actual")
                    if actual is not None:
                        actual_balloon=_qmp_int(actual)
                        self._record_balloon(actual_balloon)
                        log.debug("BALLOON_CHANGE event: actual=%dMB", actual_balloon // (1024**2))
        except Exception as e:
            log.debug("QMP event listener stopped: %s", e)

    async def _qmp_reconnect(self) -> None:
        if self.qmp:
            try:
                await self.qmp.disconnect()
            except Exception as e:
                log.debug("QMP disconnect failed: %s", e)
        self.qmp = None
        if self.event_task:
            self.event_task.cancel()
        await self._qmp_connect()

    def _compute_target_max(self, avg10: float) -> int:
        """Returns a progressive balloon ceiling based on PSI avg10 pressure."""
        if avg10 < self.args.psi_pressure:
            return self.max_mem
        ratio = min(1.0, (avg10 - self.args.psi_pressure) / (self.args.psi_pressure_max - self.args.psi_pressure))
        psi_max_mem = int(self.max_mem - ratio * (self.max_mem - self.min_mem))
        log.debug("PSI avg10=%.2f%% ceiling=%dMB (ratio=%.2f)", avg10, psi_max_mem // (1024 ** 2), ratio)
        return psi_max_mem
    
    async def _compute_container_cap(self, qmp: QMPClient) -> Optional[int]:
        """ Calculates the guest RAM cap for container memory limits (if any)"""
        if (c_info := get_container_mem_info()) is not None:
            c_limit, c_allocated, c_cache = c_info
            c_used = c_allocated - c_cache

            guest_mem_rss = await _get_host_qemu_guest_mem_rss(qmp, self.qemu_pid)

            # Calculate the container overhead if we have an actual rss guest memory, otherwise assume 0 (and leave just 
            # the container margin)
            c_overhead = (c_used - guest_mem_rss) if guest_mem_rss is not None else 0

            # Calculate the effective container memory cap, leaving some margin for the container overhead
            # Clamp to 0 on edge cases where overhead and margin already exceed the limit
            c_cap = max(0, c_limit - c_overhead - CONTAINER_MEM_MARGIN)
            
            log.debug(
                "Container cap: %dMB <- c_limit=%dMB c_used=%dMB c_cache=%dMB guest_rss=%dMB c_overhead=%dMB",
                c_cap // (1024**2),
                c_limit // (1024**2),
                c_used // (1024**2),
                c_cache // (1024**2),
                guest_mem_rss // (1024**2)  if guest_mem_rss is not None else None,
                c_overhead // (1024**2),
            )
            
            return c_cap
        
        return None


    async def _compute_guest_ram_usage(self, qmp: QMPClient) -> Optional[int]:
        """Returns the estimated guest RAM usage in bytes, excluding caches."""
        
        guest_ram_usage = None

        # Try to calculate actual guest memory usage from guest stats (to exclude cache)
        guest_stats = await qmp_get_guest_ram_stats(qmp)
        if guest_stats is not None:
            guest_stats_mem_avail, guest_stats_mem_total, guest_stats_time = guest_stats
            guest_stats_mem_used = guest_stats_mem_total - guest_stats_mem_avail

            # Check working mode of balloon driver:
            #  * When the guest reports a system memory matching the initial (not ballooned) memory, the balloon
            #    driver (in older Linux Kernels and current Windows) is working by reserving memory into the guest,
            #    with balloon size that is reported as used guest memory and needs to be removed.
            #  * When the reported system memory does not match the provisioned one, the balloon driver is
            #    working by reducing the available system memory, so the balloon size is not reported as used memory,
            #    and the total memory reported by guest stats is reduced by the balloon size.
            #
            # NB: guest could also report a system memory matching the initial memory when there is no ballooning enforced.
            if guest_stats_mem_total == self.initial_guest_stat_mem_total:
                # Get the balloon value that was in effect when the guest sampled its stats, so the balloon-effect
                # correction is temporally consistent.
                balloon_at_stat_time = self._get_balloon_at(float(guest_stats_time) if guest_stats_time is not None else None)
                if balloon_at_stat_time > 0:
                    if balloon_at_stat_time != self.max_mem:
                        guest_ram_usage = guest_stats_mem_used - (self.max_mem - balloon_at_stat_time)
                        log.debug(
                            "Guest RAM usage: %dMB/%dMB (balloon working mode: reserve-memory; balloon at guest-stat time: %dMB)",
                            guest_ram_usage // (1024 ** 2),
                            guest_stats_mem_total // (1024 ** 2),
                            balloon_at_stat_time // (1024 ** 2),
                        )
                    else:
                        guest_ram_usage = guest_stats_mem_used
                        log.debug(
                            "Guest RAM usage: %dMB/%dMB (no active ballooning)",
                            guest_ram_usage // (1024 ** 2),
                            guest_stats_mem_total // (1024 ** 2),
                        )

                else:
                    # No balloon info found. As fallback use the lowest between the actual RSS memory used (which includes 
                    # cache but excludes balloon) and the guest RAM usage (which excludes cache but includes balloon).
                    guest_mem_rss = await _get_host_qemu_guest_mem_rss(qmp, self.qemu_pid)
                    guest_ram_usage = min(guest_mem_rss, guest_stats_mem_used) if guest_mem_rss is not None else guest_stats_mem_used
                    log.debug(
                        "Guest RAM usage: %dMB (balloon working mode: reserve-memory; fallback; rss: %dMB/%dMB, stats: %dMB/%dMB)",
                        guest_ram_usage // (1024 ** 2),
                        guest_mem_rss // (1024 ** 2) if guest_mem_rss is not None else None,
                        self.max_mem // (1024 ** 2),
                        guest_stats_mem_used // (1024 ** 2),
                        guest_stats_mem_total // (1024 ** 2),
                    )
            else:
                # Guest stats already account balloon size by reducing total system memory
                guest_ram_usage = guest_stats_mem_used
                log.debug(
                    "Guest RAM usage: %dMB/%dMB (balloon working mode: remove-memory)",
                    guest_ram_usage // (1024 ** 2),
                    guest_stats_mem_total // (1024 ** 2),
                )
        
        else:
            # No guest stat available. Use the RSS memory used by guest memory slots (which includes cache but excludes balloon)
            if (guest_ram_usage := await _get_host_qemu_guest_mem_rss(qmp, self.qemu_pid)) is not None:
                log.debug(
                    "Guest RAM usage: %dMB/%dMB (from RSS; no guest stats available)",
                    guest_ram_usage // (1024 ** 2),
                    self.max_mem // (1024 ** 2),
                )
        
        if guest_ram_usage is None:
            log.debug("Guest RAM usage: not available")

        return guest_ram_usage

    async def _handle_pi_control(self, qmp: QMPClient, host_available: int, target_max: int) -> None:
        """PI-controlled adaptive ballooning."""

        host_free_ratio = host_available / self.host_total
        
        # Allow shrinking below guest RAM usage (inducing guest memory pressure) when host usage
        # exceeds the hard threshold.
        if host_free_ratio < self.hard_free_ratio:
            log.debug("Host memory above hard threshold (%.2f%%): allowing sub-usage shrink.", self.args.ram_threshold_hard)
            target_min = self.min_mem
        else:
            guest_ram_usage = await self._compute_guest_ram_usage(qmp)
            target_min = max(self.min_mem, guest_ram_usage) if guest_ram_usage is not None else self.min_mem

        # Get the current balloon value, falling back to max_mem if unknown.
        actual_balloon = self._get_balloon_at(None)
        if actual_balloon <= 0:
            actual_balloon = self.max_mem
        
        # Calculate prospective PI output with the potential new integral
        error = self.desired_free_ratio - host_free_ratio
        potential_integral = max(-1.0, min(1.0, self.error_integral + error * self.args.interval))
        adjustment = (self.args.kp * error + self.args.ki * potential_integral) * self.max_mem
        pi_target = int(actual_balloon - adjustment)

        target_balloon = min(target_max, max(target_min, pi_target))

        # Only update the integral if the output is not saturated at a boundary in the direction of the error.
        # If saturated, clamp the integral to the back-calculated value that would produce pi_target == boundary,
        # so recovery from saturation starts from a meaningful state rather than zero.
        saturated_low  = target_balloon == target_min and error > 0
        saturated_high = target_balloon == target_max and error < 0
        if saturated_low or saturated_high:
            boundary = target_min if saturated_low else target_max
            if self.args.ki != 0:
                self.error_integral = max(-1.0, min(1.0,
                    (actual_balloon - boundary) / (self.args.ki * self.max_mem) - self.args.kp * error / self.args.ki
                ))
            else:
                self.error_integral = 0.0
        else:
            self.error_integral = potential_integral

        log.debug(
            "PI: error=%.4f integral=%.4f (committed=%.4f s_low=%s s_high=%s) adj=%+dMB target=%dMB (current=%dMB, min=%dMB/%dMB, max=%dMB/%dMB)",
            error,
            potential_integral,
            self.error_integral,
            saturated_low,
            saturated_high,
            -int(adjustment // (1024 ** 2)),
            target_balloon // (1024 ** 2),
            self.last_target_balloon // (1024 ** 2),
            target_min // (1024 ** 2),
            self.min_mem // (1024 ** 2),
            target_max // (1024 ** 2),
            self.max_mem // (1024 ** 2),
        )
        
        # Apply resize if change exceeds hysteresis, or if we are hitting the boundaries (min/max)
        if target_balloon != self.last_target_balloon and (abs(target_balloon - self.last_target_balloon) >= self.hysteresis or target_balloon == target_max or target_balloon == target_min):
            if await qmp_send_balloon(qmp, target_balloon):
                self.last_target_balloon = target_balloon
                log.debug("PI resize to %dMB succeeded.", target_balloon // (1024 ** 2))
            else:
                log.error("Failed to send balloon command.")

    async def _update_balloon(self) -> None:
        host_info = get_host_ram_info()
        if not host_info:
            log.error("Cannot read host memory info. Waiting...")
            return
        
        qmp = self._get_qmp()
        
        # Ensure that the initial stat total memory has been initialized, needed to detect
        # ballooning driver behavior when calculating guest memory usage.
        if self.initial_guest_stat_mem_total == -1:
            if (guest_stats := await qmp_get_guest_ram_stats(qmp)) is None:
                log.debug("Cannot read initial total memory from guest stats. Waiting...")
                return
            self.initial_guest_stat_mem_total = guest_stats[1]

        avg10 = get_host_psi_avg10()
        
        target_max = self._compute_target_max(avg10) if avg10 is not None else self.max_mem

        if (c_cap := await self._compute_container_cap(qmp)) is not None:
            # The target is the lowest between the PSI one and the container cap.
            target_max = min(target_max, c_cap)

        _, host_available, _ = host_info
        await self._handle_pi_control(qmp, host_available, target_max)

    async def start(self) -> None:
        log.debug("Starting QEMU Memory Balloon Monitor")
        log.debug("QMP socket: %s", self.args.qmp_sock)
        log.debug("QMP pid: %s", self.qemu_pid)
        log.debug("PSI Pressure threshold: >=%.2f%% (max: %.2f%%)", self.args.psi_pressure, self.args.psi_pressure_max)
        log.debug("Host RAM threshold: %.2f%% (hard: %.2f%%)", self.args.ram_threshold, self.args.ram_threshold_hard)
        log.debug("Adaptive PI Kp: %.4f", self.args.kp)
        log.debug("Adaptive PI Ki: %.4f", self.args.ki)
        log.debug("Polling every %ds", self.args.interval)

        host_info = get_host_ram_info()
        if not host_info:
            log.critical("Cannot read host memory info")
            sys.exit(1)
        self.host_total = host_info[0]
        if self.host_total <= 0:
            log.critical("Invalid host total memory: %d", self.host_total)
            sys.exit(1)

        self.hysteresis = int(self.args.hysteresis * self.host_total) if self.args.hysteresis < 1 else int(self.args.hysteresis)

        log.debug("Hysteresis: %dMB", self.hysteresis // (1024 ** 2))

        self._loop = asyncio.get_running_loop()
        self._loop.add_signal_handler(signal.SIGINT, self._handle_sigint)

        await self._qmp_connect()
        self.max_mem = await qmp_get_max_mem(self._get_qmp())
        self.min_mem = int(self.max_mem * self.args.min_mem) if self.args.min_mem <= 1 else int(self.args.min_mem)
        self.last_target_balloon = self.max_mem

        if self.min_mem > self.max_mem:
            log.critical("Invalid minimum memory byte size: %s (greater than maximum memory %s)", self.args.min_mem, self.max_mem)
            sys.exit(1)

        log.debug("Guest Max Mem: %dMB", self.max_mem // (1024 ** 2))
        log.debug("Guest Min Mem: %dMB", self.min_mem // (1024 ** 2))

        self._setup_cgroup_watch()

        try:
            while not self._stop.is_set():
                try:
                    await self._update_balloon()
                except Exception as e:
                    if isinstance(e, (ConnectionError, BrokenPipeError, OSError)):
                        log.warning("QMP connection lost: %s. Reconnecting...", e)
                        await self._qmp_reconnect()
                    else:
                        log.error("Unexpected error in main loop: %s", e, exc_info=e)
                self._cgroup_event.clear()
                try:
                    await asyncio.wait_for(
                        asyncio.wait({asyncio.ensure_future(self._stop.wait()), asyncio.ensure_future(self._cgroup_event.wait())}, return_when=asyncio.FIRST_COMPLETED),
                        timeout=self.args.interval,
                    )
                except asyncio.TimeoutError:
                    pass
        except Exception as e:
            log.error("Error while waiting: %s", e, exc_info=e)
        finally:
            self._teardown_cgroup_watch()
            self._loop.remove_signal_handler(signal.SIGINT)
            if self.event_task:
                self.event_task.cancel()
            if self.qmp:
                await self.qmp.disconnect()

# ==========================================================
# Main Execution
# ==========================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Monitor host PSI and memory and containre memory to dynamically adjust QEMU VM memory via ballooning."
    )

    parser.add_argument("--qmp-sock", type=str, required=True,
                        help="Path to QEMU QMP Unix socket")
    parser.add_argument("--qemu-pid-file", type=argparse.FileType('r'), required=True,
                        help="Path to QEMU PID file")
    parser.add_argument("--min-mem", type=byte_size_or_fraction, default="33%",
                        help="Minimum VM memory as a percentage of max (e.g. 33%%) or absolute "
                             "size (e.g. 2048M, 2G). Must be greater than 1 byte and smaller than maximum size. (default: 33%%)")
    parser.add_argument("--psi-pressure", type=float, default=10.00,
                        help="PSI avg10 threshold (%%) at which balloon shrinking begins (default: 10.0)")
    parser.add_argument("--psi-pressure-max", type=float, default=50.00,
                        help="PSI avg10 value (%%) at which balloon is fully shrunk to minimum (default: 50.0)")
    parser.add_argument("--ram-threshold", type=float, default=80.0,
                        help="Host RAM usage percentage to target for adaptive VM memory sizing (default: 80.0)")
    parser.add_argument("--ram-threshold-hard", type=float, default=90.0,
                        help="Host RAM usage percentage above which the balloon is allowed to shrink "
                             "below guest RAM usage, inducing guest memory pressure (default: 90.0)")
    parser.add_argument("--hysteresis", type=byte_size_or_fraction, default="128M",
                        help="Minimum balloon size change required before applying a resize, as host memory %% (e.g. 2%%) or absolute size (e.g. 256M, 1G) (default: 128M)")
    parser.add_argument("--kp", type=float, default=0.5,
                        help="PI proportional gain (Kp). Controls how aggressively the VM memory "
                             "reacts to the current gap between target and actual host free memory. "
                             "Higher values respond faster but may oscillate. (default: 0.5)")
    parser.add_argument("--ki", type=float, default=0.05,
                        help="PI integral gain (Ki). Corrects persistent steady-state error by "
                             "accumulating past deviations over time. Higher values eliminate offset "
                             "faster but risk overshoot. (default: 0.05)")
    parser.add_argument("--interval", type=int, default=5,
                        help="Polling interval in seconds (default: 5)")
    parser.add_argument("--debug", nargs="?", const="all", default=None, metavar="TARGETS",
                        help="Enable debug logging. Without a value, enables debug on all loggers. "
                             "Accepts comma-separated targets: controller, qmp, all")

    args = parser.parse_args()

    if not (0 < args.ram_threshold <= 100):
        parser.error("--ram-threshold must be between 0 and 100")
    if not (0 < args.ram_threshold_hard <= 100):
        parser.error("--ram-threshold-hard must be between 0 and 100")
    if args.ram_threshold_hard <= args.ram_threshold:
        parser.error("--ram-threshold-hard must be greater than --ram-threshold")
    if args.psi_pressure_max <= args.psi_pressure:
        parser.error("--psi-pressure-max must be greater than --psi-pressure")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    if args.debug is not None:
        targets = {t.strip() for t in args.debug.split(",")}
        if "all" in targets:
            logging.getLogger().setLevel(logging.DEBUG)
        else:
            if "controller" in targets:
                logging.getLogger(__name__).setLevel(logging.DEBUG)
            if "qmp" in targets:
                logging.getLogger("qemu.qmp").setLevel(logging.DEBUG)

    monitor = BalloonMonitor(args)
    asyncio.run(monitor.start())

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.debug("Monitor stopped by user.")
        sys.exit(0)
