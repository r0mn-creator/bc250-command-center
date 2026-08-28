#!/usr/bin/env python3
"""BC-250 Command Center - desktop launcher.

Runs the Flask app in a background thread and opens it in a native
pywebview window (WebKitGTK) instead of a browser tab - no URL bar, no
tabs, just the app. Same Flask backend/templates as running app.py
directly; only the presentation layer differs, so updating the dashboard
still just means editing app.py/templates and restarting this process.
"""
import os
import socket
import sys
import threading
import time

import webview

import app as flask_app

PORT = 5250


def port_free(port, host="127.0.0.1"):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex((host, port)) != 0


def run_flask():
    try:
        flask_app.app.run(host="127.0.0.1", port=PORT, debug=False, use_reloader=False)
    except OSError as e:
        # Flask runs in a daemon thread - an exception here would otherwise
        # die silently, leaving a webview window open with nothing behind
        # it. Fail loudly instead.
        print(f"FATAL: Flask failed to start: {e}", file=sys.stderr)
        os._exit(1)


def main():
    # A just-killed previous instance can hold the port for a moment after
    # exiting - wait briefly instead of racing it.
    for _ in range(20):
        if port_free(PORT):
            break
        time.sleep(0.25)
    else:
        print(f"FATAL: port {PORT} still in use after waiting - is another instance running?", file=sys.stderr)
        sys.exit(1)

    t = threading.Thread(target=run_flask, daemon=True)
    t.start()

    webview.create_window(
        "BC-250 Command Center",
        "http://127.0.0.1:5250",
        width=1280,
        height=860,
        min_size=(1000, 700),
    )
    # pywebview defaults private_mode=True, which on the GTK backend spins up
    # an ephemeral WebKit context (WebContext.new_ephemeral()) - cookies and
    # localStorage are deliberately never written to disk. That's why the GPU
    # auto-OC quick-settings ladder (saved via localStorage) never survived a
    # close/reboot - it wasn't a WebKitGTK flakiness issue, it was this flag.
    webview.start(private_mode=False)


if __name__ == "__main__":
    main()
