#!/usr/bin/env python3
"""A media player (MPRIS) and a notification service for the private bus of
tests/api_bus.rs. It owns the two names, answers the calls the runtime makes,
and writes every notification it is asked to show to the file named on the
command line, one JSON object per line."""
import json
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

PLAYER = "org.mpris.MediaPlayer2.Player"


class Player(dbus.service.Object):
    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != PLAYER:
            return {}
        metadata = dbus.Dictionary(
            {
                "mpris:trackid": dbus.ObjectPath("/stand/in/1"),
                "mpris:length": dbus.Int64(200_000_000),
                "xesam:title": "Stand-in --title",
                "xesam:artist": dbus.Array(["First", "Second"], signature="s"),
                "xesam:album": "An Album",
                "xesam:url": "file:///home/someone/private/song.flac",
                "mpris:artUrl": "file:///home/someone/private/cover.png",
            },
            signature="sv",
        )
        return {"PlaybackStatus": "Playing", "Position": dbus.Int64(42_500_000), "Metadata": metadata, "Volume": 1.0}


class Notifications(dbus.service.Object):
    def __init__(self, bus, record):
        super().__init__(bus, "/org/freedesktop/Notifications")
        self.record = record
        self.count = 0

    @dbus.service.method("org.freedesktop.Notifications", out_signature="as")
    def GetCapabilities(self):
        return ["body", "body-markup"]

    @dbus.service.method("org.freedesktop.Notifications", in_signature="susssasa{sv}i", out_signature="u")
    def Notify(self, app, replaces, icon, summary, body, actions, hints, timeout):
        self.count += 1
        with open(self.record, "a", encoding="utf-8") as output:
            output.write(json.dumps({"app": str(app), "summary": str(summary), "body": str(body), "actions": len(actions), "hints": len(hints), "timeout": int(timeout)}) + "\n")
        return dbus.UInt32(self.count)


DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
names = [dbus.service.BusName("org.mpris.MediaPlayer2.standin", bus), dbus.service.BusName("org.freedesktop.Notifications", bus)]
player = Player(bus, "/org/mpris/MediaPlayer2")
notifications = Notifications(bus, sys.argv[1])
print("ready", flush=True)
GLib.MainLoop().run()
