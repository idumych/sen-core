#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 SEN Labs e.U.
"""Does the AppImage's server show up in a desktop's tray? Plays the tray of a desktop on a D-Bus session of its own: it starts the
AppImage, waits for its StatusNotifierItem, and checks its icon and its menu.

    dbus-run-session -- python3 packaging/appimage/tray-check.py <AppImage> <OUT_DIR>

Run it on a display, with HOME set, as smoke.sh does. Exits with 0 if all is well.
"""
import os
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

WATCHER_XML = """
<node>
  <interface name='org.kde.StatusNotifierWatcher'>
    <method name='RegisterStatusNotifierItem'><arg type='s' name='service' direction='in'/></method>
    <method name='RegisterStatusNotifierHost'><arg type='s' name='service' direction='in'/></method>
    <property name='RegisteredStatusNotifierItems' type='as' access='read'/>
    <property name='IsStatusNotifierHostRegistered' type='b' access='read'/>
    <property name='ProtocolVersion' type='i' access='read'/>
    <signal name='StatusNotifierItemRegistered'><arg type='s'/></signal>
  </interface>
</node>
"""

items = []


def method_call(connection, sender, path, interface, method, parameters, invocation):
    if method == "RegisterStatusNotifierItem":
        service = parameters.unpack()[0]
        # (an item names its bus name, or its path on the caller's connection)
        items.append((sender, service if service.startswith("/") else "/StatusNotifierItem"))
    invocation.return_value(None)


def get_property(connection, sender, path, interface, name):
    if name == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", [sender_ + path_ for sender_, path_ in items])
    if name == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    return GLib.Variant("i", 0)


def pump(context, seconds, until=lambda: False):
    end = time.monotonic() + seconds
    while time.monotonic() < end and not until():
        context.iteration(False)
        time.sleep(0.02)
    return until()


def item_id(layout, wanted):
    """The id of the first item in a dbusmenu layout whose label has these words."""
    identifier, properties, children = layout
    if wanted in properties.get("label", "").replace("_", ""):
        return identifier
    for child in children:
        found = item_id(child, wanted)
        if found is not None:
            return found
    return None


def windows():
    result = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "."], capture_output=True, text=True)
    names = []
    for window in result.stdout.split():
        name = subprocess.run(["xdotool", "getwindowname", window], capture_output=True, text=True).stdout.strip()
        if name:
            names.append(name)
    return names


def labels(layout):
    """The labels in a dbusmenu layout, (id, properties, children), with their children."""
    _, properties, children = layout
    found = []
    if "label" in properties:
        found.append(properties["label"].replace("_", ""))
    for child in children:
        found += labels(child)
    return found


def main():
    app, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    context = GLib.MainContext.default()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    info = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML).interfaces[0]
    bus.register_object("/StatusNotifierWatcher", info, method_call, get_property, None)
    Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE, None, None)
    pump(context, 0.5)

    environment = dict(os.environ)
    environment.pop("SEN_NO_DESKBAR", None)
    environment["SEN_LOG_LEVEL"] = "info"
    with open(os.path.join(out, "tray-app.log"), "w") as log:
        server = subprocess.Popen([app], env=environment, stdout=log, stderr=subprocess.STDOUT)

    failures = []
    try:
        if not pump(context, 60, lambda: bool(items)):
            print("tray: no item was registered")
            return 1
        name, path = items[0]
        print(f"tray: an item was registered: {name}{path}")

        def get(prop):
            result = bus.call_sync(name, path, "org.freedesktop.DBus.Properties", "Get",
                                   GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", prop)), None,
                                   Gio.DBusCallFlags.NONE, 5000, None)
            return result.unpack()[0]

        # the knot, once the replicant has drawn it
        pixmaps = []
        pump(context, 20, lambda: bool(pixmaps) or pixmaps.extend(p for p in get("IconPixmap") if any(p[2])) or bool(pixmaps))
        title = get("Title")
        print(f"tray: title {title!r}, {len(pixmaps)} icon(s)" + (f", {pixmaps[0][0]}x{pixmaps[0][1]}" if pixmaps else ""))
        if not pixmaps:
            failures.append("the item has no icon, or it is blank")

        menu_path = get("Menu")
        print(f"tray: menu at {menu_path}")

        # what a tray does before it shows a menu
        wanted = ["Info", "Check", "Settings", "Quit"]
        shown = []

        def fetch_menu():
            nonlocal shown
            try:
                bus.call_sync(name, menu_path, "com.canonical.dbusmenu", "AboutToShow", GLib.Variant("(i)", (0,)), None,
                              Gio.DBusCallFlags.NONE, 5000, None)
            except GLib.Error:
                pass
            result = bus.call_sync(name, menu_path, "com.canonical.dbusmenu", "GetLayout",
                                   GLib.Variant("(iias)", (0, -1, [])), None, Gio.DBusCallFlags.NONE, 5000, None)
            shown = labels(result.unpack()[1])
            return all(any(want in label for label in shown) for want in wanted)

        # (a right click on the item is what makes its menu)
        try:
            bus.call_sync(name, path, "org.kde.StatusNotifierItem", "ContextMenu", GLib.Variant("(ii)", (10, 10)), None,
                          Gio.DBusCallFlags.NONE, 5000, None)
        except GLib.Error as error:
            print(f"tray: ContextMenu: {error.message}")
        ok = pump(context, 20, fetch_menu)
        print(f"tray: menu items: {shown}")
        if not ok:
            failures.append(f"the menu lacks some of {wanted}")

        def click(label):
            # (as a tray does: the menu is asked for each time it opens, and the last one's items are gone)
            bus.call_sync(name, path, "org.kde.StatusNotifierItem", "ContextMenu", GLib.Variant("(ii)", (10, 10)), None,
                          Gio.DBusCallFlags.NONE, 5000, None)
            pump(context, 20, fetch_menu)
            result = bus.call_sync(name, menu_path, "com.canonical.dbusmenu", "GetLayout",
                                   GLib.Variant("(iias)", (0, -1, [])), None, Gio.DBusCallFlags.NONE, 5000, None)
            identifier = item_id(result.unpack()[1], label)
            if identifier is None:
                return False
            bus.call_sync(name, menu_path, "com.canonical.dbusmenu", "Event",
                          GLib.Variant("(isvu)", (identifier, "clicked", GLib.Variant("s", ""), 0)), None,
                          Gio.DBusCallFlags.NONE, 5000, None)
            return True

        # it does what it says: a window opens...
        if ok and os.environ.get("COSMOE_BACKEND") == "x11":
            before = windows()
            click("Info")
            opened = pump(context, 15, lambda: any(w not in before for w in windows()))
            print(f"tray: after Info: {[w for w in windows() if w not in before]}")
            if not opened:
                failures.append("Info opened no window")

        # ...and Quit stops the server, the only way a desktop user has of doing that. It asks first, in a window that has
        # its default button on Quit. (Keys and windows can only be reached from here on X11.)
        if ok and os.environ.get("COSMOE_BACKEND") == "x11":
            before = windows()
            click("Quit")
            asked = pump(context, 15, lambda: any(w not in before for w in windows()))
            print(f"tray: after Quit: {[w for w in windows() if w not in before]}")
            if not asked:
                failures.append("Quit asked nothing")
            else:
                pump(context, 1)
                alert = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "^SEN$"], capture_output=True, text=True)
                for window in alert.stdout.split():
                    subprocess.run(["xdotool", "windowactivate", "--sync", window], capture_output=True)
                    subprocess.run(["xdotool", "key", "Return"], capture_output=True)
                stopped = pump(context, 20, lambda: server.poll() is not None)
                print("tray: the answer " + (f"stopped the server, status {server.poll()}" if stopped else "left the server running"))
                if not stopped:
                    failures.append("answering Quit didn't stop the server")
    finally:
        server.terminate()
        pump(context, 3, lambda: server.poll() is not None)
        if server.poll() is None:
            server.kill()

    for failure in failures:
        print(f"tray: FAIL: {failure}")
    if not failures:
        print("tray: PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
