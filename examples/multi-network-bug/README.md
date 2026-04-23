# Multi-network reproduction

Minimal reproduction of the bug where a QEMU VM started by `qemux/qemu` loses
network access once the host container is attached to more than one Docker
network.

## Layout

| Case                  | Attached networks          | Expected today       |
| --------------------- | -------------------------- | -------------------- |
| `01-single-network`   | default bridge only        | VM has network       |
| `02-external-network` | one externally-created net | VM has network       |
| `03-two-networks`     | two user-defined bridges   | VM has **no** network |

All three compose files use `BOOT=alpine` (smallest auto-downloaded ISO,
~60 MB) and `DEBUG=Y` so `getInfo()` in `src/network.sh` prints the detected
interface to the container logs.

## Prerequisites

- Docker Engine with Compose v2
- Host with `/dev/kvm` and `/dev/net/tun`
- `NET_ADMIN` capability available to the container (default for root Docker)

## Running

```sh
./verify.sh 01-single-network
./verify.sh 02-external-network
./verify.sh 03-two-networks
```

`verify.sh` brings up the compose file, waits for in-container networking to
initialise, then checks:

1. Which container interface `getInfo()` picked (parsed from the logs).
2. Whether that interface holds the default route inside the container.
3. Whether a `MASQUERADE` rule exists on the detected interface.
4. Whether every external container interface (not `lo`, not the internal
   `docker` bridge, not the `qemu` tap) has a `MASQUERADE` rule.

The script exits 0 on all-pass, 1 otherwise, and always cleans up the
container. With the current `src/network.sh`, case `03-two-networks` fails
check #4 because `configureNAT()` only installs MASQUERADE on the single
interface `getInfo()` picked — any VM traffic routed through the other
attached network leaves un-NATed and dies on the host.

The script deliberately does **not** depend on the guest booting far enough
to DHCP or generate egress, because `BOOT=alpine` drops to a login prompt
rather than configuring networking automatically. The iptables /
interface-level checks reveal the misconfiguration directly, which is where
the defect lives.
