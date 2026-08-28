#!/usr/bin/env python3
"""BC-250 GPU clock/voltage auto-search.

Steps the GPU clock up (with an interpolated voltage), running a real
sustained heat-soak at each step (minutes, not seconds - short bursts
were confirmed on this exact hardware to understate the real thermal
ceiling) and watching real edge temperature, until the temperature limit
is hit or the target is reached. Cools back down toward idle between
steps so each one starts from a comparable baseline rather than already
warmed up from the last - otherwise later steps look hotter than they
really are just from cumulative heat. When a step hits the temperature
limit, the previous (last successfully-held) step is reported as the
result - that's the board's likely ceiling on whatever cooling is
actually installed, not a fixed number that applies to every unit.
Mirrors the
CPU auto-OC tool's "detect, don't keep" pattern: at the end it REVERTS the
live clock to a known-safe baseline (1500MHz/900mV, the only point this
project has confirmed stable under real, extended gameplay) and just
prints/records what it found - it does NOT leave the found value applied.
A separate, explicit step (the dashboard's existing GPU clock-preset
control) is what actually applies+persists the result, matching the
"search, then the user decides to accept" workflow.

IMPORTANT LIMITATION, learned the hard way on this exact project: a
synthetic compute-only dispatch loop is not a perfect stand-in for real
game load (rasterization/texturing/ROPs, not just compute shaders), and
even real gameplay bursts under ~1 minute understated the true sustained
thermal ceiling versus a ~30 minute continuous session. Treat this
search's result as a starting point that still deserves confirmation
under real extended use, not a final validated-safe value.

Must run as root (writes the governor config file and restarts its
systemd service).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SAFE_MHZ = 1500
SAFE_MV = 900
HW_MHZ_MIN, HW_MHZ_MAX = 1000, 2175
HW_MV_MIN, HW_MV_MAX = 700, 1129


def read_edge_temp():
    try:
        out = subprocess.run(["sensors"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    m = re.search(r"edge:\s*\+?([0-9.]+)", out)
    return float(m.group(1)) if m else None


def set_clock(mhz, mv, oberon_conf, governor_service):
    with open(oberon_conf, "w") as f:
        f.write(
            "opps:\n"
            "  - frequency:\n"
            f"    - min: 1000\n"
            f"    - max: {mhz}\n"
            "  - voltage:\n"
            f"    - min: 700\n"
            f"    - max: {mv}\n"
        )
    subprocess.run(["systemctl", "restart", governor_service], check=True, timeout=30)


def compile_verifier(verify_script):
    tmp_parent = tempfile.mkdtemp(prefix="bc250-autooc-")
    env = dict(os.environ, TMPDIR=tmp_parent)
    p = subprocess.run(
        [verify_script, "--elements", "4194304", "--passes", "1", "--iters", "1", "--keep-tmp"],
        capture_output=True, text=True, env=env, timeout=60,
    )
    m = re.search(r"Keeping temporary files in (\S+)", p.stdout + p.stderr)
    if not m:
        raise RuntimeError("could not compile the compute verifier: " + p.stdout + p.stderr)
    tmpdir = m.group(1)
    binary = os.path.join(tmpdir, "bc250_compute_verify")
    spv = os.path.join(tmpdir, "bc250_compute_verify.spv")
    if not (os.path.exists(binary) and os.path.exists(spv)):
        raise RuntimeError(f"compiled verifier not found in {tmpdir}")
    return tmp_parent, binary, spv


def dispatch_burst(binary, spv):
    # Same size as the known-good correctness-test default (confirmed to
    # run in well under a second) - the sustained load comes from calling
    # this repeatedly in a tight loop, not from making any single call
    # huge. An earlier version used 8x this workload with only a 30s
    # timeout and crashed (TimeoutExpired, uncaught) because the CPU-side
    # golden-value verification scales with elements*iters and doesn't
    # stay fast at that size - do not enlarge this without re-verifying
    # actual wall-clock time first.
    try:
        subprocess.run(
            [binary, spv, "16777216", "1", "64"],
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        pass  # skip this burst, the outer loop just checks temp/time again


def mv_for(mhz, start_mhz, start_mv, mv_per_100mhz):
    mv = start_mv + round((mhz - start_mhz) / 100.0 * mv_per_100mhz)
    return max(HW_MV_MIN, min(HW_MV_MAX, mv))


def main():
    ap = argparse.ArgumentParser(description="Auto-search a safe BC-250 GPU clock/voltage point")
    ap.add_argument("--start-mhz", type=int, default=SAFE_MHZ)
    ap.add_argument("--start-mv", type=int, default=SAFE_MV)
    ap.add_argument("--target-mhz", type=int, required=True)
    ap.add_argument("--step-mhz", type=int, default=50)
    ap.add_argument("--mv-per-100mhz", type=int, default=10)
    ap.add_argument("--soak-seconds", type=int, default=180)
    ap.add_argument("--temp-limit", type=int, default=90)
    ap.add_argument("--cooldown-target-c", type=int, default=60,
                     help="Wait between steps until edge temp drops to this or --cooldown-max-seconds elapses")
    ap.add_argument("--cooldown-max-seconds", type=int, default=120)
    ap.add_argument("--oberon-conf", required=True)
    ap.add_argument("--governor-service", required=True)
    ap.add_argument("--verify-script", required=True)
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: must run as root", file=sys.stderr)
        sys.exit(1)

    if not (HW_MHZ_MIN <= args.target_mhz <= HW_MHZ_MAX):
        print(f"ERROR: target frequency must be {HW_MHZ_MIN}-{HW_MHZ_MAX} MHz", file=sys.stderr)
        sys.exit(2)

    print("Compiling compute load generator...")
    tmp_parent, binary, spv = compile_verifier(args.verify_script)

    safe_mhz, safe_mv = args.start_mhz, args.start_mv
    mhz = args.start_mhz
    aborted_at = None

    try:
        while mhz <= args.target_mhz:
            mv = mv_for(mhz, args.start_mhz, args.start_mv, args.mv_per_100mhz)
            print(f"\n--- Testing {mhz}MHz / {mv}mV for {args.soak_seconds}s ---")
            set_clock(mhz, mv, args.oberon_conf, args.governor_service)

            step_start = time.time()
            hit_limit = False
            while time.time() - step_start < args.soak_seconds:
                temp = read_edge_temp()
                if temp is not None and temp >= args.temp_limit:
                    print(f"ABORT: edge temp {temp}C reached limit ({args.temp_limit}C) at {mhz}MHz/{mv}mV")
                    hit_limit = True
                    break
                dispatch_burst(binary, spv)

            if hit_limit:
                aborted_at = (mhz, mv)
                break

            print(f"OK: {mhz}MHz/{mv}mV held under {args.temp_limit}C for {args.soak_seconds}s")
            safe_mhz, safe_mv = mhz, mv
            mhz += args.step_mhz

            if mhz <= args.target_mhz:
                # Cool down before the next step so each step starts from a
                # comparable baseline instead of already warmed up from the
                # last one - otherwise later steps look hotter than they
                # really are just from cumulative heat carrying over.
                cool_start = time.time()
                temp = read_edge_temp()
                print(f"Cooling down (currently {temp}C, target {args.cooldown_target_c}C, "
                      f"up to {args.cooldown_max_seconds}s)...")
                while (temp is None or temp > args.cooldown_target_c) and \
                        time.time() - cool_start < args.cooldown_max_seconds:
                    time.sleep(3)
                    temp = read_edge_temp()
                print(f"Resuming at {temp}C after {int(time.time() - cool_start)}s cooldown")
    except Exception as e:
        # Defense in depth beyond fixing whatever specific bug caused this:
        # any unexpected failure here still reverts the live clock to a
        # known-safe point and prints one clean line, rather than letting a
        # raw traceback reach the dashboard UI (which just displays
        # whatever text the helper returns - it has no separate handling
        # for "this looks like a crash" vs a normal message).
        try:
            set_clock(SAFE_MHZ, SAFE_MV, args.oberon_conf, args.governor_service)
        except Exception:
            pass
        print(f"STATUS: unexpected error during search ({type(e).__name__}: {e}) - "
              f"reverted to the safe baseline ({SAFE_MHZ}MHz/{SAFE_MV}mV).", file=sys.stderr)
        shutil.rmtree(tmp_parent, ignore_errors=True)
        sys.exit(1)

    try:
        # Always revert to the known-safe baseline - never leave the
        # just-tested (possibly untrusted) value live. Accepting it is a
        # separate, explicit step.
        set_clock(SAFE_MHZ, SAFE_MV, args.oberon_conf, args.governor_service)

        print(f"\nFinal Result: {safe_mhz} MHz @ {safe_mv} mV")
        if aborted_at:
            print(f"Stopped early at {aborted_at[0]}MHz/{aborted_at[1]}mV - temperature limit reached")
        print(f"Reverted live clock to the known-safe baseline ({SAFE_MHZ}MHz/{SAFE_MV}mV) - "
              "use the dashboard's clock control to accept and apply the result above if you want it.")
        print("NOTE: this used a synthetic compute-only load, not a real game. Confirm under "
              "extended real use before fully trusting this - short soaks have understated the "
              "real thermal ceiling on this exact hardware before.")
    finally:
        shutil.rmtree(tmp_parent, ignore_errors=True)


if __name__ == "__main__":
    main()
