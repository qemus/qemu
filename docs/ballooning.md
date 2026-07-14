# Dynamic memory allocation

By default, the VM keeps the full amount of RAM configured through `RAM_SIZE` for its entire lifetime.

Memory ballooning allows the container to reclaim guest memory dynamically in response to host memory pressure. It also helps keep the VM within the container memory limit, including when that limit is changed at runtime:

```yaml
environment:
  BALLOONING: "Y"
```

The following optional variables control the ballooning behavior:

| Variable | Default | Description |
|---|---|---|
| `BALLOONING` | `N` | Enables dynamic memory ballooning. |
| `BALLOONING_MIN_MEM` | `33%` | Minimum amount of memory retained by the VM, specified as a percentage of its maximum memory, such as `33%`, or an absolute size, such as `2G`. |
| `BALLOONING_RAM_THRESHOLD` | `80.0` | Target host RAM usage percentage. The PI controller adjusts the balloon target toward this value. |
| `BALLOONING_RAM_THRESHOLD_HARD` | `90.0` | Host RAM usage percentage above which the balloon target may drop below the guest's current memory usage, inducing guest memory pressure. |
| `BALLOONING_PSI_PRESSURE` | `10.0` | Host PSI `some avg10` percentage at which the PSI ceiling begins lowering the maximum balloon target. |
| `BALLOONING_PSI_PRESSURE_MAX` | `50.0` | Host PSI `some avg10` percentage at which the PSI ceiling reaches `BALLOONING_MIN_MEM`. |
| `BALLOONING_HYSTERESIS` | `128M` | Minimum balloon-target change normally required before a resize is applied, specified as a percentage of total host RAM, such as `2%`, or an absolute size, such as `256M`. |
| `BALLOONING_KP` | `0.5` | Proportional gain used by the ballooning controller. Higher values react faster but may cause oscillation. |
| `BALLOONING_KI` | `0.05` | Integral gain used by the ballooning controller. Higher values correct steady-state error faster but may cause overshoot. |
| `BALLOONING_INTERVAL` | `5` | Polling interval in seconds. |
| `BALLOONING_DEBUG` | `N` | Enables debug output for the ballooning monitor. Can also be set to `controller`, `qmp`, or `all`. |

> [!NOTE]
> Memory ballooning uses the Linux PSI `some avg10` value from `/proc/pressure/memory` for progressive pressure detection. Between `BALLOONING_PSI_PRESSURE` and `BALLOONING_PSI_PRESSURE_MAX`, the PSI ceiling linearly lowers the maximum balloon target from the VM's maximum memory to `BALLOONING_MIN_MEM`. If PSI cannot be read, these thresholds are ignored and ballooning continues using host RAM usage alone.

> [!WARNING]
> If the container memory limit is reduced below the VM's current memory usage at runtime, the container may be terminated by the OOM killer when the ballooning driver cannot reclaim guest memory quickly enough.
