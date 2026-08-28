#!/usr/bin/env python3
"""BC-250 CPU/GPU unlock dashboard.

Local-only Flask app (binds 127.0.0.1). Read-only status comes from
unprivileged sources (nproc, sensors, the governor config file). Anything
that changes system state runs through pkexec on a root-owned helper script
in /usr/local/bin/ - each action prompts for authentication separately.

Portable across BC-250 machines: paths and the GPU governor service name are
read from /etc/bc250-dashboard.conf, written by install.sh at setup time
rather than hardcoded here.
"""
import os
import re
import shutil
import subprocess

INSTALL_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "install.sh")

from flask import Flask, jsonify, request

app = Flask(__name__)

CONF_PATH = "/etc/bc250-dashboard.conf"
HELPER_CPU_UNLOCK = "/usr/local/bin/bc250-dash-cpu-unlock"
HELPER_GPU_CU = "/usr/local/bin/bc250-dash-gpu-cu"
HELPER_GPU_CLOCK = "/usr/local/bin/bc250-dash-gpu-clock"
HELPER_CPU_OC = "/usr/local/bin/bc250-dash-cpu-oc"
HELPER_GPU_AUTOOC = "/usr/local/bin/bc250-dash-gpu-autooc"

# Only the one broadly-validated universal floor is hardcoded. Everything
# above this is specific to one board's cooling/silicon and shouldn't be
# presented as generic defaults to a different machine - the rest of the
# "quick settings" ladder is built from this board's own Auto-search
# results (see /api/gpu/autooc/search) and rendered client-side.
CLOCK_PRESETS = [
    {"mhz": 1500, "mv": 900, "label": "1500MHz / 900mV", "risk": "safe",
     "note": "Broadly validated safe floor. Run Auto-search below to find this board's actual ceiling."},
]


def load_conf():
    conf = {"PREFIX": "/usr/local/share/bc250-dashboard",
            "OBERON_CONF": "/etc/oberon-config.yaml",
            "EXPECTED_CPUS": "16",
            "GOVERNOR_SERVICE": ""}
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    return conf


CONF = load_conf()
EXPECTED_CPUS = int(CONF.get("EXPECTED_CPUS", "16"))
OBERON_CONF = CONF["OBERON_CONF"]
GOVERNOR_CONFIGURED = bool(CONF.get("GOVERNOR_SERVICE"))
VERIFY_SCRIPT = os.path.join(CONF["PREFIX"], "bc250-compute-verify.sh")


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timed out"
    except FileNotFoundError as e:
        return -1, "", str(e)


def pkexec(helper_path, *args, timeout=60):
    return run(["pkexec", helper_path, *args], timeout=timeout)


CPU_OC_INSTALLED = os.path.exists(os.path.join(CONF["PREFIX"], "oc-venv", "bin", "bc250-detect"))


@app.get("/")
def index():
    return INDEX_HTML


def check_missing():
    """Mirror install.sh's own checks, unprivileged, for the dashboard to
    decide whether to surface the 'Run installer' button at all."""
    missing = []

    if not (shutil.which("umr") or os.path.exists("/usr/local/bin/umr")):
        missing.append("umr (GPU register access tool)")

    vulkan_ok = os.path.exists("/usr/include/vulkan/vulkan.h")
    if vulkan_ok:
        ldconfig = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True)
        vulkan_ok = "libvulkan.so " in ldconfig.stdout
    if not vulkan_ok:
        missing.append("Vulkan headers/loader (needed for the correctness test)")

    if not shutil.which("stress"):
        missing.append("stress (needed for CPU auto-overclock)")

    if not GOVERNOR_CONFIGURED:
        missing.append("GPU governor service (not detected - clock/voltage control unavailable)")

    if not CPU_OC_INSTALLED:
        missing.append("bc250_smu_oc (CPU auto-overclock tool)")

    if not os.path.exists(CONF_PATH):
        missing.append("dashboard config file")

    for svc in ("bc250-core-unlock.service", "bc250-cu-live-manager.service"):
        rc = subprocess.run(["systemctl", "is-enabled", svc], capture_output=True).returncode
        if rc != 0:
            missing.append(f"{svc} (not enabled)")

    return missing


@app.get("/api/install/missing")
def install_missing():
    return jsonify({"missing": check_missing()})


@app.post("/api/install/run")
def install_run():
    # install.sh needs a real interactive terminal (sudo prompts, and the
    # confirmation prompts on some steps) - pkexec/subprocess from Flask
    # can't provide that. Launch a real terminal emulator on the user's
    # own desktop session instead and let them drive it directly.
    term_cmd = "; ".join([
        f"bash {INSTALL_SH}",
        "echo",
        "read -p 'Installer finished - press Enter to close this window...'",
    ])
    terminals = [
        ["konsole", "-e", "bash", "-c", term_cmd],
        ["gnome-terminal", "--", "bash", "-c", term_cmd],
        ["xterm", "-e", "bash", "-c", term_cmd],
    ]
    for cmd in terminals:
        if subprocess.run(["which", cmd[0]], capture_output=True).returncode == 0:
            subprocess.Popen(cmd, start_new_session=True)
            return jsonify({"ok": True, "terminal": cmd[0]})
    return jsonify({"ok": False, "error": "no terminal emulator found (tried konsole, gnome-terminal, xterm)"}), 500


ALLOWED_CREDIT_URLS = {
    "https://github.com/WinnieLV/bc250-cu-live-manager",
    "https://github.com/duggasco/bc250-40cu-unlock",
    "https://github.com/bc250-collective/bc250_smu_oc",
    "https://github.com/rw-r-r-0644/bc250-core-unlock",
    "https://github.com/elektricM/amd-bc250-docs",
}


@app.post("/api/open-url")
def open_url():
    # The desktop app has no address bar - clicking a normal <a> link would
    # navigate this kiosk window itself away with no way back. Open it in
    # the user's actual browser instead. Allowlisted to the credited repos
    # only, since this endpoint exists purely for the Credits panel.
    url = (request.get_json(force=True) or {}).get("url", "")
    if url not in ALLOWED_CREDIT_URLS:
        return jsonify({"ok": False, "error": "not an allowed URL"}), 400
    try:
        subprocess.Popen(["xdg-open", url], start_new_session=True)
        return jsonify({"ok": True})
    except FileNotFoundError:
        return jsonify({"ok": False, "error": "xdg-open not found"}), 500


@app.get("/api/cpu/status")
def cpu_status():
    rc, out, err = run(["nproc"])
    online = int(out.strip()) if rc == 0 and out.strip().isdigit() else None
    return jsonify({
        "online": online,
        "expected": EXPECTED_CPUS,
        "unlocked": online is not None and online >= EXPECTED_CPUS,
    })


@app.get("/api/cpu/clocks")
def cpu_clocks():
    # Unprivileged - /proc/cpuinfo's "cpu MHz" field is live, no root needed.
    try:
        with open("/proc/cpuinfo") as f:
            text = f.read()
    except OSError:
        return jsonify({"mhz": []})
    mhz = [float(m) for m in re.findall(r"cpu MHz\s*:\s*([0-9.]+)", text)]
    return jsonify({
        "mhz": mhz,
        "min": min(mhz) if mhz else None,
        "max": max(mhz) if mhz else None,
        "avg": round(sum(mhz) / len(mhz), 0) if mhz else None,
    })


@app.post("/api/cpu/unlock")
def cpu_unlock():
    rc, out, err = pkexec(HELPER_CPU_UNLOCK)
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip()})


@app.post("/api/cpu/stresstest")
def cpu_stresstest():
    # Unprivileged - stress-ng needs no root. Validates the unlocked cores
    # actually hold up under sustained load, mirroring the manual
    # `stress-ng --cpu 16` soak done when this unlock was first built.
    data = request.get_json(silent=True) or {}
    minutes = int(data.get("minutes", 20))
    nproc = os.cpu_count() or 1
    rc, out, err = run(
        ["stress-ng", "--cpu", str(nproc), "--timeout", f"{minutes}m", "--metrics-brief"],
        timeout=minutes * 60 + 60,
    )
    text = out + err
    passed = failed = None
    m = re.search(r"passed:\s*(\d+)", text)
    if m:
        passed = int(m.group(1))
    m = re.search(r"failed:\s*(\d+)", text)
    if m:
        failed = int(m.group(1))
    ok = rc == 0 and failed == 0 and passed is not None and passed > 0
    return jsonify({"ok": ok, "passed": passed, "failed": failed, "cores": nproc, "output": text.strip()})


@app.get("/api/gpu/sensors")
def gpu_sensors():
    rc, out, err = run(["sensors"])
    edge = power = None
    if rc == 0:
        m = re.search(r"edge:\s*\+?([0-9.]+)", out)
        if m:
            edge = float(m.group(1))
        m = re.search(r"PPT:\s*([0-9.]+)\s*W", out)
        if m:
            power = float(m.group(1))
    return jsonify({"edge_c": edge, "power_w": power})


@app.get("/api/gpu/config")
def gpu_config():
    rc, out, err = run(["cat", OBERON_CONF])
    max_mhz = max_mv = None
    if rc == 0:
        freqs = re.findall(r"frequency:\s*\n\s*-\s*min:\s*(\d+)\s*\n\s*-\s*max:\s*(\d+)", out)
        volts = re.findall(r"voltage:\s*\n\s*-\s*min:\s*(\d+)\s*\n\s*-\s*max:\s*(\d+)", out)
        if freqs:
            max_mhz = int(freqs[0][1])
        if volts:
            max_mv = int(volts[0][1])
    return jsonify({
        "max_mhz": max_mhz, "max_mv": max_mv, "presets": CLOCK_PRESETS,
        "governor_available": GOVERNOR_CONFIGURED,
    })


@app.post("/api/gpu/clock")
def gpu_set_clock():
    if not GOVERNOR_CONFIGURED:
        return jsonify({"ok": False, "output": "", "error": "no governor service configured on this machine"}), 400
    data = request.get_json(force=True)
    mhz = str(int(data["mhz"]))
    mv = str(int(data["mv"]))
    rc, out, err = pkexec(HELPER_GPU_CLOCK, mhz, mv)
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip()})


@app.post("/api/gpu/autooc/search")
def gpu_autooc_search():
    if not GOVERNOR_CONFIGURED:
        return jsonify({"ok": False, "error": "no governor service configured on this machine"}), 400
    data = request.get_json(force=True)
    target = str(int(data["target_mhz"]))
    step = str(int(data.get("step_mhz", 50)))
    mv_per_100 = str(int(data.get("mv_per_100mhz", 10)))
    soak = str(int(data.get("soak_seconds", 180)))
    temp = str(int(data.get("temp_limit", 90)))
    # Real heat-soak per step (minutes) plus a cooldown wait between steps
    # means this can legitimately run for an hour or more on a wide
    # target range. Generous timeout so a big search doesn't get killed
    # partway through.
    rc, out, err = pkexec(
        HELPER_GPU_AUTOOC,
        "--target-mhz", target, "--step-mhz", step,
        "--mv-per-100mhz", mv_per_100, "--soak-seconds", soak, "--temp-limit", temp,
        timeout=5400,
    )
    result = None
    m = re.search(r"Final Result:\s*(\d+)\s*MHz @ (\d+)\s*mV", out)
    if m:
        result = {"mhz": int(m.group(1)), "mv": int(m.group(2))}
    aborted = "Stopped early at" in out
    # Every step that actually held for its full soak, in order - this is
    # the real per-board data the "quick settings" ladder is built from.
    history = [{"mhz": int(a), "mv": int(b)}
               for a, b in re.findall(r"OK:\s*(\d+)MHz/(\d+)mV held", out)]
    edge = None
    m = re.search(r"Stopped early at (\d+)MHz/(\d+)mV", out)
    if m:
        edge = {"mhz": int(m.group(1)), "mv": int(m.group(2))}
    return jsonify({
        "ok": rc == 0, "output": out.strip(), "error": err.strip(),
        "result": result, "aborted": aborted, "history": history, "edge": edge,
    })


@app.get("/api/gpu/cu/status")
def gpu_cu_status():
    rc, out, err = pkexec(HELPER_GPU_CU, "status")
    active = None
    m = re.search(r"CUs active & routed\s*:\s*(\d+)/(\d+)", out)
    if m:
        active = {"active": int(m.group(1)), "total": int(m.group(2))}
    return jsonify({"ok": rc == 0, "raw": out.strip(), "error": err.strip(), "summary": active})


@app.post("/api/gpu/cu/enable-all")
def gpu_cu_enable_all():
    # Includes two real compile+run correctness tests (baseline + after
    # enabling) before it returns, so give it more room than the default
    # pkexec timeout.
    rc, out, err = pkexec(HELPER_GPU_CU, "enable-all", timeout=180)
    text = out + err
    failed_baseline = "FAILED baseline test" in text
    failed_verify = "FAILED correctness test after enabling" in text
    return jsonify({
        "ok": rc == 0, "output": out.strip(), "error": err.strip(),
        "failed_baseline": failed_baseline, "failed_verify": failed_verify,
    })


@app.post("/api/gpu/cu/stock")
def gpu_cu_stock():
    rc, out, err = pkexec(HELPER_GPU_CU, "stock")
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip()})


@app.get("/api/cpu/oc/available")
def cpu_oc_available():
    return jsonify({"installed": CPU_OC_INSTALLED})


@app.get("/api/cpu/oc/status")
def cpu_oc_status():
    if not CPU_OC_INSTALLED:
        return jsonify({"ok": False, "error": "not installed - run the installer"})
    rc, out, err = pkexec(HELPER_CPU_OC, "status")
    staged = None
    m = re.search(r"frequency\s*=\s*(\d+)\s*\n\s*scale\s*=\s*(-?\d+)\s*\n\s*max_temperature\s*=\s*(\d+)", out)
    if m:
        staged = {"mhz": int(m.group(1)), "scale": int(m.group(2)), "temp": int(m.group(3))}
    persisted = "PERSISTED: yes" in out
    return jsonify({"ok": rc == 0, "raw": out.strip(), "error": err.strip(), "staged": staged, "persisted": persisted})


@app.post("/api/cpu/oc/detect")
def cpu_oc_detect():
    if not CPU_OC_INSTALLED:
        return jsonify({"ok": False, "error": "not installed - run the installer"}), 400
    data = request.get_json(force=True)
    mhz = str(int(data["mhz"]))
    mv = str(int(data["mv"]))
    temp = str(int(data.get("temp", 90)))
    # Can take a couple minutes: search steps up in 100MHz increments, each
    # accepted step runs a 10s stress test plus overhead.
    rc, out, err = pkexec(HELPER_CPU_OC, "detect", mhz, mv, temp, timeout=360)
    result = None
    m = re.search(r"Final Result:\s*(\d+)\s*MHz @ (\d+)\s*mV using scale (-?\d+)", out)
    if m:
        result = {"mhz": int(m.group(1)), "measured_mv": int(m.group(2)), "scale": int(m.group(3))}
    aborted = "Aborting because" in out
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip(), "result": result, "aborted": aborted})


@app.post("/api/cpu/oc/apply")
def cpu_oc_apply():
    rc, out, err = pkexec(HELPER_CPU_OC, "apply")
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip()})


@app.post("/api/cpu/oc/revert")
def cpu_oc_revert():
    rc, out, err = pkexec(HELPER_CPU_OC, "revert")
    return jsonify({"ok": rc == 0, "output": out.strip(), "error": err.strip()})


@app.post("/api/gpu/verify")
def gpu_verify():
    # Unprivileged correctness test - no pkexec needed. Uses default
    # (known-good) parameters; see PROGRESS.md gotcha #6 for why small
    # custom parameters give false-positive errors unrelated to clock.
    rc, out, err = run([VERIFY_SCRIPT], timeout=60)
    passed = "errors=0 int_errors=0 fp_errors=0" in out and "summary" in out
    return jsonify({"ok": rc == 0, "passed": passed, "output": out.strip(), "error": err.strip()})


INDEX_HTML = open(__file__.replace("app.py", "templates/index.html")).read()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5250, debug=False)
