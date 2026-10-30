#!/usr/bin/env python3
# A stand-in xdg-desktop-portal ScreenCast for testing Go Live on Linux where the desktop has none (WSLg):
# answers CreateSession / SelectSources / Start with the PipeWire node given, and OpenPipeWireRemote with a
# plain connection to the PipeWire socket. Prints the options each call got.
#   python3 tools/fake_screencast_portal.py <node id> [cancel|close-after-seconds]
import os, socket, sys
import dbus, dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

NODE = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else ""
BASE = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.portal.ScreenCast"


class Session(dbus.service.Object):
    @dbus.service.method("org.freedesktop.portal.Session", in_signature="", out_signature="")
    def Close(self):
        print("Session.Close", flush=True)

    @dbus.service.signal("org.freedesktop.portal.Session", signature="a{sv}")
    def Closed(self, details):
        pass


class Request(dbus.service.Object):
    @dbus.service.signal("org.freedesktop.portal.Request", signature="ua{sv}")
    def Response(self, code, results):
        pass

    @dbus.service.method("org.freedesktop.portal.Request", in_signature="", out_signature="")
    def Close(self):
        print("Request.Close", flush=True)


class Portal(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, BASE)
        self.bus = bus
        self.sessions = []

    def respond(self, sender, opts, code, results):
        path = "%s/request/%s/%s" % (BASE, sender[1:].replace(".", "_"), opts["handle_token"])
        req = Request(self.bus, path)
        GLib.timeout_add(200, lambda: (req.Response(dbus.UInt32(code), dbus.Dictionary(results, signature="sv")), False)[1])
        return dbus.ObjectPath(path)

    @dbus.service.method(IFACE, in_signature="a{sv}", out_signature="o", sender_keyword="sender")
    def CreateSession(self, opts, sender=None):
        print("CreateSession", dict(opts), flush=True)
        spath = "%s/session/%s/%s" % (BASE, sender[1:].replace(".", "_"), opts["session_handle_token"])
        self.sessions.append(Session(self.bus, spath))
        return self.respond(sender, opts, 0, {"session_handle": dbus.String(spath)})

    @dbus.service.method(IFACE, in_signature="oa{sv}", out_signature="o", sender_keyword="sender")
    def SelectSources(self, session, opts, sender=None):
        print("SelectSources", session, {k: (type(v).__name__, v) for k, v in opts.items()}, flush=True)
        return self.respond(sender, opts, 0, {})

    @dbus.service.method(IFACE, in_signature="osa{sv}", out_signature="o", sender_keyword="sender")
    def Start(self, session, parent, opts, sender=None):
        print("Start", session, repr(parent), dict(opts), flush=True)
        if MODE == "cancel":
            return self.respond(sender, opts, 1, {})
        if MODE.isdigit():
            GLib.timeout_add(int(MODE) * 1000, lambda: (self.sessions[-1].Closed({}), False)[1])
        streams = dbus.Array([dbus.Struct((dbus.UInt32(NODE), dbus.Dictionary({"size": dbus.Struct((640, 480), signature="ii")}, signature="sv")), signature="ua{sv}")], signature="(ua{sv})")
        return self.respond(sender, opts, 0, {"streams": streams})

    @dbus.service.method(IFACE, in_signature="oa{sv}", out_signature="h")
    def OpenPipeWireRemote(self, session, opts):
        print("OpenPipeWireRemote", session, flush=True)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], "pipewire-0"))
        return dbus.types.UnixFd(s)

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        return {"version": dbus.UInt32(5), "AvailableSourceTypes": dbus.UInt32(3), "AvailableCursorModes": dbus.UInt32(7)}[prop]


DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
name = dbus.service.BusName("org.freedesktop.portal.Desktop", bus)
Portal(bus)
print("fake portal up, node", NODE, flush=True)
GLib.MainLoop().run()
