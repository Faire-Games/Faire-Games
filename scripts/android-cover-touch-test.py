#!/usr/bin/env python3
"""Native hit-test regression, on a 360×640dp Android emulator (e.g. 720×1280 @ 320dpi).

First launch Day-Games with `day launch -p android-mdc --android-device SERIAL
--env DAY_GAMES_SEED=15 --keep-alive`, then run this script with SERIAL.
Requires adb on PATH. This changes only the emulator's game/navigation state.
Dayscript taps target a node directly; adb taps exercise Android's actual view dispatch.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# The framework CLI: the checkout beside this repo, never an installed `day`, whose build date is
# unknown and whose drive protocol may predate the app's. Override with DAY_CLI to name another.
DAY_CLI = os.environ.get("DAY_CLI", "").split() or [
    "cargo",
    "run",
    "--manifest-path",
    str(Path(__file__).resolve().parents[2] / "day" / "Cargo.toml"),
    "-q",
    "-p",
    "day-cli",
    "--",
]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} EMULATOR_SERIAL")
    serial = sys.argv[1]
    if not serial.startswith("emulator-"):
        raise SystemExit("Use an emulator, not a physical device.")
    env = dict(os.environ, ANDROID_SERIAL=serial)
    project = Path(__file__).resolve().parents[1]

    def adb(*args):
        return subprocess.check_output(["adb", "-s", serial, *args], text=True)

    def drive(*steps):
        result = subprocess.run(
            [*DAY_CLI, "drive", "-p", "android-mdc", "--steps-json", json.dumps(steps)],
            cwd=project, env=env, text=True, capture_output=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        assert json.loads(result.stdout)["failed"] == 0, result.stdout

    density = int(re.findall(r"density: (\d+)", adb("shell", "wm", "density"))[-1]) / 160
    width, height = map(int, re.findall(r"size: (\d+)x(\d+)", adb("shell", "wm", "size"))[-1])
    assert (width / density, height / density) == (360, 640), "Requires a 360×640dp emulator"

    def tap(x, y):
        adb("shell", "input", "tap", str(round(x * density)), str(round(y * density)))
        time.sleep(0.4)

    # Dismiss first-run help deterministically, regardless of saved settings.
    for route in ("reversi", "pipes", "twentyfortyeight"):
        drive({"navigate": {"route": route}}, {"nav_back": {}}, {"pause": {"secs": 0.4}})
    def swipe(y1, y2):
        adb("shell", "input", "swipe", str(round(100 * density)), str(round(y1 * density)),
            str(round(100 * density)), str(round(y2 * density)), "1000")
        time.sleep(0.4)

    for _ in range(4):
        swipe(100, 570)  # return the home scroll to its top from any saved offset
    swipe(475, 200)  # bring 2048 underneath the cover's header coordinate

    # Positive control: this screen coordinate MUST hit 2048 before a cover is shown.
    # Otherwise a test could pass simply because there was nothing clickable underneath.
    tap(75, 30)
    drive({"assert_route": {"route": "twentyfortyeight"}}, {"nav_back": {}},
          {"pause": {"secs": 0.4}})

    for route, prefix in (("reversi", "rv"), ("pipes", "pp"), ("twentyfortyeight", "tf")):
        drive({"navigate": {"route": route}}, {"pause": {"secs": 0.4}})
        tap(75, 30)  # passive header beside X, above the hidden 2048 tile
        drive({"assert_route": {"route": route}})
        tap(330, 30)  # the cover must still deliver touches to its pause control
        drive({"assert_visible": {"id": f"{prefix}-resume"}})
        tap(75, 30)  # also modal while the pause scrim is present
        drive({"assert_route": {"route": route}}, {"tap": {"id": f"{prefix}-resume"}})
        tap(30, 30)  # native X dismisses; the underlying grid must become interactive again
        tap(75, 30)
        drive({"assert_route": {"route": "twentyfortyeight"}}, {"nav_back": {}},
              {"pause": {"secs": 0.4}})
        print(f"PASS {route}: header blocked, pause and close work, home restored", flush=True)


if __name__ == "__main__":
    main()
