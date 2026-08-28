# BC-250 Command Center

A portable GUI for unlocking and tuning the AMD BC-250 board (the repurposed
Xbox Series S APU sold as a mini PC/dev board). Covers CPU core unlock, GPU
compute-unit unlock, and CPU/GPU clock/voltage tuning — all through one
desktop app, no manual terminal commands required after install.

Not every BC-250 can unlock all 40 GPU compute units or all 8 CPU cores —
most can, but it depends on the individual chip. Every unlock and every
overclock/undervolt search in this app runs a real correctness test before
keeping the change, and automatically reverts if that test fails.

## What it does

- **CPU core unlock** — enables the 2 factory-disabled Zen 2 cores
  (6c/12t → 8c/16t), checking the core-presence mask before writing and
  refusing on boards where it looks like a genuine defect rather than
  market segmentation. Includes an optional stress test to validate
  stability afterward.
- **GPU compute-unit unlock** — enables all 40 RDNA2 compute units (16 are
  firmware-disabled, not defective, on stock configs). Runs a Vulkan
  correctness test *before* enabling (so a pre-existing GPU problem isn't
  mistaken for an unlock failure) and *after* (reverting automatically if
  the extra CUs don't compute correctly on your specific chip).
- **CPU auto-overclock** — steps up CPU frequency, measuring real voltage
  and testing stability at each step, and reverts to stock the moment the
  search ends. Nothing is applied until you explicitly accept a result.
- **GPU auto-overclock** — the same idea for GPU clock/voltage, with a real
  multi-minute heat-soak per step (not a quick check) and a cooldown pause
  before the next step, so the result reflects your board's actual thermal
  ceiling on your actual cooling.
- **GPU undervolt search** — holds a clock fixed and searches downward for
  the lowest stable voltage at that clock, validated with a real Vulkan
  graphics-pipeline workload (textured, alpha-blended rendering with
  per-frame correctness checks), not just a synthetic compute dispatch —
  same performance, less heat and power. Never searches below the safe
  baseline voltage by default.
- **Quick settings** — every search result becomes a one-click card you can
  apply (or remove) later, so you don't have to re-run a search to get back
  to a result you've already found and trusted.

## Requirements

- An AMD BC-250 board, running Linux.
- A GPU governor service already present for clock/voltage control
  (`oberon-governor.service` is the only variant tested end-to-end so far —
  other variants are detected best-effort). CPU/GPU unlock features work
  without one.
- `rpm-ostree`, `dnf`, `apt`, or `pacman` as the package manager (the
  installer detects which one you have and layers packages accordingly;
  immutable/ostree images are supported).

## Getting started

Five steps, download to running app:

**1. Download it.** Go to the
[Releases page](https://github.com/r0mn-creator/bc250-command-center/releases/latest)
and download `bc250-command-center-vX.Y.Z.zip` (the `.tar.gz` next to it has
the same contents, pick whichever your system opens by default).

**2. Extract it.** Right-click the downloaded file and choose **Extract**,
or in a terminal:
```
unzip bc250-command-center-v1.0.0.zip
cd bc250-command-center-v1.0.0
```

**3. Install it.** From a terminal, inside that folder:
```
./install.sh
```
This asks for your password once, to set up the few system pieces the app
needs (like the root-only helper scripts each unlock/overclock action
calls). It's safe to re-run any time — it detects what's already in place
and skips it, whether this is a fresh, never-unlocked BC-250 or one that's
already partially set up.

**4. Launch it.** Look for **BC-250 Command Center** in your application
menu — the installer adds it automatically. Or, from the same terminal:
```
venv/bin/python3 desktop.py
```

**5. Click past the disclaimer.** Every launch shows a one-time risk
summary first. Click **I understand — proceed**, enter your password when
asked (needed once per launch, to show live GPU status), and the dashboard
is ready to use.

That's it — no other setup needed. Prefer `git` over downloading a zip?
`git clone https://github.com/r0mn-creator/bc250-command-center.git` works
the same way; just run `./install.sh` from inside the cloned folder instead
of an extracted one.

Every action that *changes* something (an unlock, an overclock, a clock
change) asks for your password separately, right when you take that action
— the app itself never runs as root.

## A note on risk

This app writes directly to low-level hardware registers and firmware-level
SMU settings. Incorrect values can crash the system or cause instability,
and CPU voltage/frequency overclocking in particular carries real risk of
permanent hardware damage if pushed too far. Every unlock and search in
this app is gated by a real correctness test and reverts automatically on
failure — but you're still responsible for understanding what a control
does before you click it. Read the in-app disclaimer.

## Credits

The actual hardware-unlock mechanisms are the work of several prior
community reverse-engineering projects — this app wraps them in one GUI
with a consistent test-before-trust flow. Full attribution in
[CREDITS.md](CREDITS.md).
