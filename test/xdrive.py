"""Drive the FS-UAE window through the X server (XTEST) for GUI tests.

FS-UAE maps physical keys, and the emulated Amiga uses the US keymap, so
characters are sent as US-layout physical keys (evdev keycodes), whatever
the host keyboard layout is.
"""
import os
import subprocess
import time

from Xlib import X, display
from Xlib.ext import xtest

# evdev key codes + 8 = X key codes
_K = {
    "Escape": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8,
    "8": 9, "9": 10, "0": 11, "-": 12, "=": 13, "BackSpace": 14, "Tab": 15,
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23,
    "o": 24, "p": 25, "[": 26, "]": 27, "Return": 28, "Control_L": 29,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37,
    "l": 38, ";": 39, "'": 40, "`": 41, "Shift_L": 42, "\\": 43, "z": 44,
    "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52,
    "/": 53, "space": 57, "Up": 103, "Left": 105, "Right": 106, "Down": 108,
}
_SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
    ":": ";", '"': "'", "~": "`", "|": "\\", "<": ",", ">": ".", "?": "/",
}
_MODS = {"ctrl": "Control_L", "shift": "Shift_L"}


class Amiga:
    def __init__(self):
        self.d = display.Display()
        self.win = self._find(self.d.screen().root)
        if self.win is None:
            raise RuntimeError("FS-UAE window not found")

    def _find(self, w):
        try:
            name = w.get_wm_name()
        except Exception:
            name = None
        if name and "FS-UAE" in str(name):
            return w
        try:
            children = w.query_tree().children
        except Exception:
            return None
        for c in children:
            r = self._find(c)
            if r is not None:
                return r
        return None

    def focus(self):
        # tests run on a private Xvfb display, so taking the focus is safe
        self.win.set_input_focus(X.RevertToParent, X.CurrentTime)
        self.d.sync()

    def _send(self, name, down):
        xtest.fake_input(self.d, X.KeyPress if down else X.KeyRelease, _K[name] + 8)
        self.d.sync()

    def key(self, spec, times=1):
        """spec: 'Down', 'ctrl+l', 'shift+Tab', 'Return' ..."""
        parts = spec.split("+")
        mods = [_MODS[m] for m in parts[:-1]]
        k = parts[-1]
        for _ in range(times):
            self.focus()
            for m in mods:
                self._send(m, True)
                time.sleep(0.05)
            self._send(k, True)
            time.sleep(0.08)
            self._send(k, False)
            for m in reversed(mods):
                time.sleep(0.05)
                self._send(m, False)
            time.sleep(0.25)

    def type(self, text):
        for ch in text:
            if ch == " ":
                self.key("space")
            elif ch in _SHIFTED:
                self.key("shift+" + _SHIFTED[ch])
            elif ch.isupper():
                self.key("shift+" + ch.lower())
            else:
                self.key(ch)

    def shot(self, path):
        subprocess.run(["import", "-window", hex(self.win.id), path], check=False)


def wait_log(path, needle, count=1, timeout=60):
    """Wait until `needle` occurs in `count` lines of the log; return the lines."""
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            with open(path, "rb") as f:
                lines = f.read().decode("latin-1").splitlines()
            hits = [l for l in lines if needle in l]
            if len(hits) >= count:
                return lines
        time.sleep(0.5)
    raise TimeoutError(f"no {count}x '{needle}' in {path} after {timeout}s")
