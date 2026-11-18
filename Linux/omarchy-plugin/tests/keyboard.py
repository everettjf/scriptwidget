#!/usr/bin/env python3
"""Test helper: a virtual keyboard through /dev/uinput, so that key presses go
through the compositor and the input method like a real keyboard's.
Run as root inside the test machine.  kbd.py <step>...
Steps: type TEXT (a-z, 0-9, space) | key NAME (enter, space, backspace, esc, end, ctrl+end) | sleep SECONDS"""
import fcntl, os, struct, sys, time

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x405c5503, 0x5501, 0x5502
ROWS = {"qwertyuiop": 16, "asdfghjkl": 30, "zxcvbnm": 44}
CODES = {letter: base + index for letters, base in ROWS.items() for index, letter in enumerate(letters)}
CODES.update({str(digit): 1 + digit for digit in range(1, 10)})
CODES.update({"0": 11, " ": 57})
NAMED = {"enter": 28, "space": 57, "backspace": 14, "esc": 1, "end": 107, "ctrl": 29, "shift": 42}

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for code in set(CODES.values()) | set(NAMED.values()):
    fcntl.ioctl(fd, UI_SET_KEYBIT, code)
fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 3, 0x1234, 0x5679, 1, b"scriptwidget-test-keyboard", 0))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.5)

def event(kind, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, kind, code, value))

def press(codes):
    for code in codes: event(EV_KEY, code, 1); event(EV_SYN, 0, 0); time.sleep(0.02)
    for code in reversed(codes): event(EV_KEY, code, 0); event(EV_SYN, 0, 0); time.sleep(0.02)
    time.sleep(0.08)

steps = sys.argv[1:]
index = 0
while index < len(steps):
    step, value = steps[index], steps[index + 1]
    index += 2
    if step == "type":
        for letter in value: press([CODES[letter]])
    elif step == "key":
        press([NAMED[name] for name in value.split("+")])
    elif step == "sleep":
        time.sleep(float(value))
time.sleep(0.3)
fcntl.ioctl(fd, UI_DEV_DESTROY)
