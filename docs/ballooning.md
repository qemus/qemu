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
| `BALLOONING_MIN_MEM` | `33%` | Minimum amount of memory retained by the VM, specified as a percentage of `RAM_SIZE`, such as `33%`, or an absolute size, such as `2G`. |
| `BALLOONING_RAM_THRESHOLD` | `80.0` | Host RAM usage percentage at which ballooning begins adjusting memory. The PI controller aims to keep usage at or below this value. |
| `BALLOONING_RAM_THRESHOLD_HARD` | `90.0` | Host RAM usage percentage at which ballooning becomes more aggressive and may reduce the target below the guest's current RAM usage. |
| `BALLOONING_PSI_PRESSURE` | `10.0` | PSI memory pressure level at which ballooning becomes more aggressive. |
| `BALLOONING_PSI_PRESSURE_MAX` | `50.0` | PSI memory pressure level at which ballooning reaches its strongest response. |
| `BALLOONING_HYSTERESIS` | `128M` | Minimum change required before the balloon target is updated, specified as a percentage, such as `2%`, or an absolute size, such as `256M`. |
| `BALLOONING_KP` | `0.5` | Proportional gain used by the ballooning controller. Higher values react faster but may cause oscillation. |
| `BALLOONING_KI` | `0.05` | Integral gain used by the ballooning controller. Higher values correct persistent error faster but may cause overshoot. |
| `BALLOONING_INTERVAL` | `5` | Polling interval in seconds. |
| `BALLOONING_DEBUG` | `N` | Enables debug output for the ballooning monitor. |

> [!NOTE]
> Memory ballooning uses Linux PSI data from `/proc/pressure/memory` for progressive pressure detection. Between `BALLOONING_PSI_PRESSURE` and `BALLOONING_PSI_PRESSURE_MAX`, the PSI ceiling gradually lowers the maximum balloon target from `RAM_SIZE` to `BALLOONING_MIN_MEM`. If PSI is unavailable because the kernel lacks `CONFIG_PSI`, these thresholds are ignored and ballooning continues using host RAM usage alone.

> [!WARNING]
> If the container memory limit is reduced below the VM's current memory usage at runtime, the container may be terminated by the OOM killer when the ballooning driver cannot reclaim guest memory quickly enough.
