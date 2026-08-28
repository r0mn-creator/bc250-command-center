# Credits

The BC-250 Command Center is a dashboard that ties together several
pieces of prior community reverse-engineering work. None of the actual
hardware-unlock mechanisms were invented by this project — the real work
of figuring out how to talk to the BC-250's SMU and GPU belongs to the
people below. This app just wraps their tools in one GUI, with a
correctness/stability check gating every unlock.

## Vendored tools (bundled unmodified in `vendor/`)

- **[WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager)**
  — the runtime GPU CU/WGP enable-disable tool. This is what actually
  talks to the GPU via UMR to route/unroute compute units. Bundled as
  `vendor/bc250-cu-live-manager.sh`.

- **[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)**
  — source of the Vulkan compute correctness test used to verify the
  unlocked CUs actually compute correctly, not just enumerate. Bundled
  as `vendor/bc250-compute-verify.sh`.

- **[bc250-collective/bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc)**
  — the CPU frequency/voltage auto-overclock search tool (`bc250-detect`
  / `bc250-apply`), used as-is for the CPU Auto-Overclock feature.
  Bundled in full under `vendor/bc250_smu_oc/`, including its own MIT
  license and copyright notice.

## Techniques referenced (reimplemented, not copied)

- **[rw-r-r-0644/bc250-core-unlock](https://github.com/rw-r-r-0644/bc250-core-unlock)**
  — documented and pioneered the SMU mailbox technique for unlocking the
  BC-250's 2 factory-disabled CPU cores that `scripts/bc250-unlock-cores.py`
  implements.

## Documentation referenced

- **[elektricm/amd-bc250-docs](https://github.com/elektricM/amd-bc250-docs)**
  — community documentation on BC-250 governor behavior and safe
  overclock ranges, used as background reference when designing this
  app's default clock/voltage presets and safety limits.

## This project

Everything else — the Flask/HTML dashboard itself, the pywebview desktop
app wrapper, the installer, the root-privilege helper scripts, the
test-before-trust sequencing (baseline test -> unlock -> test again ->
persist or revert), and the CPU core-unlock boot service — was built for
this project, on top of the tools and research credited above.
