#!/usr/bin/env python3
"""BC-250 GPU undervolt search.

Companion to gpu-autooc.py: that script finds how HIGH the clock can go
(voltage tags along, interpolated, and each step is judged purely by
temperature). This script instead holds a single clock FIXED - normally one
already found by gpu-autooc.py - and steps voltage DOWN from a starting
point, looking for the lowest voltage that still renders bit-correct
frames at that clock. "Same performance, less power": the clock
(and therefore throughput) never changes, only voltage/power/heat do.

Unlike gpu-autooc.py's search loop, which only watches temperature and
discards the verifier's own output, every step here runs a real Vulkan
GRAPHICS-pipeline check (bc250-graphics-verify.sh's compiled binary -
textured, alpha-blended, submit-per-frame rendering, checksummed frame by
frame against a golden value) and inspects both its checksum-mismatch count
and its FPS directly - because too-low voltage on a GPU does not show up as
"slower," it shows up as wrong answers (or a hang/crash) at the same speed.
A step that ever reports a mismatch fails immediately, even if it doesn't
crash and even if temperature is fine.

This used to run bc250-compute-verify.sh's compute-only check instead. That
walked all the way down to 705mV at 1750MHz with zero errors, and the
system then crashed on the very first real game launched at that voltage -
a compute-shader dispatch never touches rasterization, texture sampling, or
ROP writes, and doesn't reproduce a game's bursty per-frame submit pattern,
so it was too light a workload to find the real instability edge. The
graphics check exercises those parts of the chip and drives the GPU the way
a real frame loop does, so it's a much closer proxy for "will this survive
an actual game" - still not a substitute for a real play-session, but no
longer a workload known to false-pass.

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


def compile_graphics_verifier(graphics_verify_script):
    tmp_parent = tempfile.mkdtemp(prefix="bc250-undervolt-gfx-")
    env = dict(os.environ, TMPDIR=tmp_parent)
    p = subprocess.run(
        [graphics_verify_script, "--frames", "8", "--seed-cycle", "8", "--keep-tmp"],
        capture_output=True, text=True, env=env, timeout=60,
    )
    m = re.search(r"Keeping temporary files in (\S+)", p.stdout + p.stderr)
    if not m:
        raise RuntimeError("could not compile the graphics verifier: " + p.stdout + p.stderr)
    tmpdir = m.group(1)
    binary = os.path.join(tmpdir, "bc250_graphics_verify")
    vert_spv = os.path.join(tmpdir, "bc250_graphics_verify.vert.spv")
    frag_spv = os.path.join(tmpdir, "bc250_graphics_verify.frag.spv")
    if not (os.path.exists(binary) and os.path.exists(vert_spv) and os.path.exists(frag_spv)):
        raise RuntimeError(f"compiled graphics verifier not found in {tmpdir}")
    return tmp_parent, binary, vert_spv, frag_spv


# Same render workload as bc250-graphics-verify.sh's own defaults - textured,
# alpha-blended quads over several overlapping layers, submitted and fenced
# one frame at a time (the same submit/wait pattern a real game's frame loop
# uses, unlike one big compute dispatch). Invoked directly against the
# pre-compiled binary (not the .sh, which recompiles from scratch every
# call) so each step check stays fast.
GFX_WIDTH, GFX_HEIGHT = "1280", "800"
GFX_GRID, GFX_LAYERS, GFX_ITERS = "32", "4", "24"
GFX_FRAMES, GFX_SEED_CYCLE = "32", "8"

GFX_SUMMARY_RE = re.compile(
    r"summary frames=(\d+) duration_sec=[\d.]+ avg_fps=([\d.]+) min_fps=([\d.]+) checksum_mismatches=(\d+)"
)


def run_graphics_check(binary, vert_spv, frag_spv):
    """Runs one real graphics-pipeline correctness+FPS pass (rasterization,
    texture sampling, alpha blending, ROP writes) at the currently-applied
    clock/voltage. Returns (ok, detail) - ok is False on a parse failure, a
    timeout, a nonzero-but-uninterpretable exit, or any checksum mismatch;
    detail is a short human-readable reason (including FPS on success, since
    that's the other half of what a real benchmark reports)."""
    try:
        # On this hardware a real Vulkan graphics pass through this binary
        # measures ~20s wall-clock for the default 32-frame workload (driven
        # by fixed per-frame submit/fence overhead, not actual render time -
        # duration_sec in the summary line is under a tenth of that). 60s
        # gives real margin above that baseline so normal timing noise can't
        # get misread as an instability-driven hang.
        p = subprocess.run(
            [binary, vert_spv, frag_spv, GFX_WIDTH, GFX_HEIGHT, GFX_GRID, GFX_LAYERS, GFX_ITERS,
             f"{GFX_FRAMES}:{GFX_SEED_CYCLE}"],
            capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        return False, "timed out (possible instability at this voltage)"

    out = p.stdout + p.stderr
    m = GFX_SUMMARY_RE.search(out)
    if not m:
        # A crash/hang that still exits non-zero without a summary line is
        # itself a sign this voltage isn't stable - treat it as a failure
        # rather than raising, so the search can cleanly report where it
        # stopped instead of dying with a traceback.
        return False, f"no summary line in output (exit {p.returncode}) - possible crash/hang"

    avg_fps, min_fps, mismatches = float(m.group(2)), float(m.group(3)), int(m.group(4))
    if mismatches > 0:
        return False, f"{mismatches} rendered-frame checksum mismatch(es) (avg {avg_fps:.1f} fps)"
    return True, f"clean (avg {avg_fps:.1f} fps, min {min_fps:.1f} fps)"


def main():
    ap = argparse.ArgumentParser(description="Search for the lowest stable GPU voltage at a fixed clock")
    ap.add_argument("--mhz", type=int, required=True, help="Clock to hold fixed (normally a gpu-autooc.py result)")
    ap.add_argument("--start-mv", type=int, required=True, help="Voltage to start from (normally the known-good voltage at --mhz)")
    ap.add_argument("--mv-step", type=int, default=10)
    # Default floor is SAFE_MV itself (the project's established safe
    # baseline), not the hardware minimum, and not below SAFE_MV either: a
    # clock above the baseline (SAFE_MHZ) should never end up validated at
    # LESS voltage than the baseline uses - voltage/frequency curves on real
    # silicon are monotonic (more MHz needs equal-or-more mV, never less),
    # and this board runs real general-purpose work as well as games, which
    # depends on that same baseline voltage margin for reliability. Going
    # below SAFE_MV is a deliberate per-run decision (e.g. bisecting toward
    # a known crash point using real bounds from prior real-game testing),
    # not something a default search should wander into. This also means
    # the dashboard's "Test undervolt" button - which has no UI for
    # --min-mv - can't accidentally re-test a voltage already known to
    # hard-crash the system, without needing a separate check in app.py.
    ap.add_argument("--min-mv", type=int, default=SAFE_MV,
                     help=f"Voltage floor to stop at (default: {SAFE_MV}mV, the established safe "
                          "baseline - a higher-than-baseline clock shouldn't end up at less voltage "
                          "than the baseline itself uses). Pass explicitly to search below this - "
                          "e.g. toward a known crash point bisected from real-game testing - since "
                          "that's a deliberate choice, not a safe default.")
    ap.add_argument("--checks-per-step", type=int, default=3,
                     help="Repeat the correctness check this many times per voltage step - undervolt errors can be intermittent")
    ap.add_argument("--temp-limit", type=int, default=90,
                     help="Safety net only - undervolting doesn't add heat, but abort if something unexpected runs hot")
    ap.add_argument("--oberon-conf", required=True)
    ap.add_argument("--governor-service", required=True)
    ap.add_argument("--graphics-verify-script", required=True)
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: must run as root", file=sys.stderr)
        sys.exit(1)

    if not (HW_MV_MIN <= args.start_mv <= HW_MV_MAX):
        print(f"ERROR: --start-mv must be {HW_MV_MIN}-{HW_MV_MAX} mV", file=sys.stderr)
        sys.exit(2)

    print("Compiling graphics-pipeline correctness checker...")
    tmp_parent, binary, vert_spv, frag_spv = compile_graphics_verifier(args.graphics_verify_script)

    best_mv = None
    failed_at = None

    try:
        mv = args.start_mv
        while mv >= args.min_mv:
            print(f"\n--- Testing {args.mhz}MHz / {mv}mV: {args.checks_per_step} correctness pass(es) ---")
            set_clock(args.mhz, mv, args.oberon_conf, args.governor_service)
            time.sleep(2)  # let the governor settle before the first check

            step_ok = True
            step_detail = "clean"
            for i in range(args.checks_per_step):
                temp = read_edge_temp()
                if temp is not None and temp >= args.temp_limit:
                    step_ok = False
                    step_detail = f"edge temp {temp}C reached safety limit ({args.temp_limit}C)"
                    break
                ok, detail = run_graphics_check(binary, vert_spv, frag_spv)
                if not ok:
                    step_ok = False
                    step_detail = detail
                    break

            if not step_ok:
                print(f"FAIL: {args.mhz}MHz/{mv}mV - {step_detail}")
                failed_at = (mv, step_detail)
                break

            print(f"OK: {args.mhz}MHz/{mv}mV passed {args.checks_per_step} correctness check(s)")
            best_mv = mv
            mv -= args.mv_step
    except Exception as e:
        try:
            set_clock(SAFE_MHZ, SAFE_MV, args.oberon_conf, args.governor_service)
        except Exception:
            pass
        print(f"STATUS: unexpected error during search ({type(e).__name__}: {e}) - "
              f"reverted to the safe baseline ({SAFE_MHZ}MHz/{SAFE_MV}mV).", file=sys.stderr)
        shutil.rmtree(tmp_parent, ignore_errors=True)
        sys.exit(1)

    try:
        # Same "detect, don't keep" convention as gpu-autooc.py - never leave
        # the just-tested value live, accepting it is a separate step.
        set_clock(SAFE_MHZ, SAFE_MV, args.oberon_conf, args.governor_service)

        if best_mv is None:
            print(f"\nFinal Result: no stable voltage found at {args.mhz}MHz starting from {args.start_mv}mV")
            if failed_at:
                print(f"Failed immediately at {failed_at[0]}mV - {failed_at[1]}")
        else:
            print(f"\nFinal Result: {args.mhz} MHz @ {best_mv} mV")
            if failed_at:
                print(f"Stopped at {failed_at[0]}mV - {failed_at[1]}")
        print(f"Reverted live clock to the known-safe baseline ({SAFE_MHZ}MHz/{SAFE_MV}mV) - "
              "use the dashboard's clock control to accept and apply the result above if you want it.")
        print("NOTE: this checks real graphics-pipeline correctness and FPS (textured/blended "
              "rendering, not a compute-only dispatch) - much closer to a real game's workload than "
              "the old compute-only check, but still a short synthetic proxy, not a substitute for "
              "an extended real-game play session at the result above.")
    finally:
        shutil.rmtree(tmp_parent, ignore_errors=True)


if __name__ == "__main__":
    main()
