import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'org.illumina.WindowManager';
const OBJECT_PATH = '/org/illumina/WindowManager';
const PROTOCOL_VERSION = 1;

const INTERFACE_XML = `
<node>
  <interface name="org.illumina.WindowManager">
    <method name="GetProtocolVersion">
      <arg type="u" direction="out"/>
    </method>
    <method name="GetDisplays">
      <arg type="s" direction="out"/>
    </method>
    <method name="MoveWindow">
      <arg type="s" direction="in" name="title"/>
      <arg type="b" direction="in" name="prefixMatch"/>
      <arg type="i" direction="in" name="x"/>
      <arg type="i" direction="in" name="y"/>
      <arg type="i" direction="in" name="width"/>
      <arg type="i" direction="in" name="height"/>
      <arg type="i" direction="in" name="tolerancePx"/>
      <arg type="u" direction="out"/>
    </method>
  </interface>
</node>`;

export default class IlluminaWindowManagerExtension extends Extension {
    enable() {
        this._exported = Gio.DBusExportedObject.wrapJSObject(INTERFACE_XML, this);
        this._exported.export(Gio.DBus.session, OBJECT_PATH);
        this._ownerId = Gio.bus_own_name_on_connection(
            Gio.DBus.session,
            BUS_NAME,
            Gio.BusNameOwnerFlags.NONE,
            null,
            null);
    }

    disable() {
        if (this._ownerId) {
            Gio.bus_unown_name(this._ownerId);
            this._ownerId = null;
        }
        if (this._exported) {
            this._exported.unexport();
            this._exported = null;
        }
    }

    GetProtocolVersion() {
        return PROTOCOL_VERSION;
    }

    GetDisplays() {
        const display = global.display;
        const primary = display.get_primary_monitor();
        const workspace = display.get_workspace_manager().get_active_workspace();
        const displays = [];

        for (let index = 0; index < display.get_n_monitors(); index++) {
            const rect = display.get_monitor_geometry(index);
            const work = workspace.get_work_area_for_monitor(index);
            displays.push({
                X: rect.x,
                Y: rect.y,
                Width: rect.width,
                Height: rect.height,
                WorkX: work.x,
                WorkY: work.y,
                WorkWidth: work.width,
                WorkHeight: work.height,
                IsPrimary: index === primary,
            });
        }

        const json = JSON.stringify(displays);
        return GLib.base64_encode(new TextEncoder().encode(json));
    }

    MoveWindow(title, prefixMatch, x, y, width, height, tolerancePx) {
        if (!this._validRequest(title, x, y, width, height, tolerancePx))
            return 2;

        try {
            const window = this._findWindow(title, prefixMatch);
            if (!window)
                return 1;
            if (window.minimized)
                return 0;

            if (window.is_fullscreen()) {
                const monitor = this._monitorForRect(x, y, width, height);
                if (monitor < 0)
                    return 2;
                window.move_to_monitor(monitor);
                return 0;
            }

            const rect = window.get_frame_rect();
            const deviates = Math.abs(rect.x - x) > Math.max(0, tolerancePx)
                || Math.abs(rect.y - y) > Math.max(0, tolerancePx)
                || Math.abs(rect.width - width) > Math.max(0, tolerancePx)
                || Math.abs(rect.height - height) > Math.max(0, tolerancePx);
            const maximized = window.get_maximized() !== 0;
            if (tolerancePx >= 0 && !deviates && !maximized)
                return 0;

            if (maximized)
                window.unmaximize(Meta.MaximizeFlags.BOTH);
            window.move_resize_frame(false, x, y, width, height);
            return 0;
        } catch (error) {
            logError(error, 'Illumina MoveWindow');
            return 2;
        }
    }

    _validRequest(title, x, y, width, height, tolerancePx) {
        const allowedTitle = title === 'Illumina'
            || title === 'Illumina - '
            || title.startsWith('Illumina — ');
        return allowedTitle
            && title.length <= 256
            && Math.abs(x) <= 32768
            && Math.abs(y) <= 32768
            && width > 0 && width <= 16384
            && height > 0 && height <= 16384
            && tolerancePx >= -1 && tolerancePx <= 1024;
    }

    _findWindow(title, prefixMatch) {
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            if (!window)
                continue;

            const windowClass = [window.get_wm_class(), window.get_wm_class_instance()]
                .filter(value => !!value)
                .join('.');
            if (!/chrome|chromium/i.test(windowClass))
                continue;

            const windowTitle = window.get_title() || '';
            if (prefixMatch ? windowTitle.startsWith(title) : windowTitle === title)
                return window;
        }
        return null;
    }

    _monitorForRect(x, y, width, height) {
        const centerX = x + Math.floor(width / 2);
        const centerY = y + Math.floor(height / 2);
        for (let index = 0; index < global.display.get_n_monitors(); index++) {
            const rect = global.display.get_monitor_geometry(index);
            if (centerX >= rect.x && centerX < rect.x + rect.width
                && centerY >= rect.y && centerY < rect.y + rect.height)
                return index;
        }
        return -1;
    }
}
