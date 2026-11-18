#!/usr/bin/env python3
"""Test helper for the display spike: a virtual absolute pointer through /dev/uinput.
Run as root inside the test machine.  pointer.py <width> <height> <step>...
Steps: move X Y | down | up | sleep SECONDS"""
import fcntl, os, struct, sys, time

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y, BTN_LEFT, BTN_TOUCH = 0, 1, 0x110, 0x14a
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT, UI_SET_PROPBIT = 0x40045564, 0x40045565, 0x40045567, 0x4004556e
UI_DEV_SETUP, UI_ABS_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405c5503, 0x401c5504, 0x5501, 0x5502

width, height = int(sys.argv[1]), int(sys.argv[2])
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
for bit in (EV_KEY, EV_ABS): fcntl.ioctl(fd, UI_SET_EVBIT, bit)
fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
for axis, limit in ((ABS_X, width - 1), (ABS_Y, height - 1)):
    fcntl.ioctl(fd, UI_SET_ABSBIT, axis)
    fcntl.ioctl(fd, UI_ABS_SETUP, struct.pack("HHiiiiii", axis, 0, 0, 0, limit, 0, 0, 0))
fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 3, 0x1234, 0x5678, 1, b"scriptwidget-spike-pointer", 0))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.0)

def event(kind, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, kind, code, value))

steps = sys.argv[3:]
index = 0
while index < len(steps):
    step = steps[index]; index += 1
    if step == "move":
        event(EV_ABS, ABS_X, int(steps[index])); event(EV_ABS, ABS_Y, int(steps[index + 1])); index += 2
    elif step == "down": event(EV_KEY, BTN_LEFT, 1)
    elif step == "up": event(EV_KEY, BTN_LEFT, 0)
    elif step == "sleep": time.sleep(float(steps[index])); index += 1; continue
    event(EV_SYN, 0, 0)
    time.sleep(0.03)
time.sleep(0.3)
fcntl.ioctl(fd, UI_DEV_DESTROY)
