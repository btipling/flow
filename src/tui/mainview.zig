const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const tracy = @import("tracy");
const root = @import("root");
const location_history = @import("location_history");
const project_manager = @import("project_manager");

const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const command = @import("command.zig");
const Box = @import("Box.zig");
const EventHandler = @import("EventHandler.zig");
const Widget = @import("Widget.zig");
const WidgetList = @import("WidgetList.zig");
const WidgetStack = @import("WidgetStack.zig");
const ed = @import("editor.zig");
const home = @import("home.zig");

const Self = @This();
const Commands = command.Collection(cmds);

a: std.mem.Allocator,
plane: Plane,
widgets: *WidgetList,
widgets_widget: Widget,
floating_views: WidgetStack,
commands: Commands = undefined,
statusbar: *Widget,
editor: ?*ed.Editor = null,
panels: ?*WidgetList = null,
last_match_text: ?[]const u8 = null,
logview_enabled: bool = false,
location_history: location_history,
file_stack: std.ArrayList([]const u8),

const NavState = struct {
    time: i64 = 0,
    lines: usize = 0,
    rows: usize = 0,
    row: usize = 0,
    col: usize = 0,
    matches: usize = 0,
};

pub fn create(a: std.mem.Allocator, n: Plane) !Widget {
    try project_manager.open_cwd();
    const self = try a.create(Self);
    self.* = .{
        .a = a,
        .plane = n,
        .widgets = undefined,
        .widgets_widget = undefined,
        .floating_views = WidgetStack.init(a),
        .statusbar = undefined,
        .location_history = try location_history.create(),
        .file_stack = std.ArrayList([]const u8).init(a),
    };
    try self.commands.init(self);
    const w = Widget.to(self);
    const widgets = try WidgetList.createV(a, w, @typeName(Self), .dynamic);
    self.widgets = widgets;
    self.widgets_widget = widgets.widget();
    try widgets.add(try Widget.empty(a, n, .dynamic));
    self.statusbar = try widgets.addP(try @import("status/statusbar.zig").create(a, w));
    if (tp.env.get().is("show-input"))
        self.toggle_inputview_async();
    if (tp.env.get().is("show-log"))
        self.toggle_logview_async();
    return w;
}

pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.close_all_panel_views();
    for (self.file_stack.items) |file_path| self.a.free(file_path);
    self.file_stack.deinit();
    self.commands.deinit();
    self.widgets.deinit(a);
    self.floating_views.deinit();
    a.destroy(self);
}

pub fn receive(self: *Self, from_: tp.pid_ref, m: tp.message) error{Exit}!bool {
    if (try m.match(.{"write_restore_info"})) {
        self.write_restore_info();
        return true;
    }
    return if (try self.floating_views.send(from_, m)) true else self.widgets.send(from_, m);
}

pub fn update(self: *Self) void {
    self.widgets.update();
    self.floating_views.update();
}

pub fn render(self: *Self, theme: *const Widget.Theme) bool {
    const widgets_more = self.widgets.render(theme);
    const views_more = self.floating_views.render(theme);
    return widgets_more or views_more;
}

pub fn handle_resize(self: *Self, pos: Box) void {
    self.widgets.handle_resize(pos);
    self.floating_views.resize(pos);
}

pub fn box(self: *const Self) Box {
    return Box.from(self.plane);
}

fn toggle_panel_view(self: *Self, view: anytype, enable_only: bool) error{Exit}!bool {
    var enabled = true;
    if (self.panels) |panels| {
        if (panels.get(@typeName(view))) |w| {
            if (!enable_only) {
                panels.remove(w.*);
                if (panels.empty()) {
                    self.widgets.remove(panels.widget());
                    self.panels = null;
                }
                enabled = false;
            }
        } else {
            panels.add(view.create(self.a, self.widgets.plane) catch |e| return tp.exit_error(e)) catch |e| return tp.exit_error(e);
        }
    } else {
        const panels = WidgetList.createH(self.a, self.widgets.widget(), "panel", .{ .static = self.box().h / 5 }) catch |e| return tp.exit_error(e);
        self.widgets.add(panels.widget()) catch |e| return tp.exit_error(e);
        panels.add(view.create(self.a, self.widgets.plane) catch |e| return tp.exit_error(e)) catch |e| return tp.exit_error(e);
        self.panels = panels;
    }
    tui.current().resize();
    return enabled;
}

fn close_all_panel_views(self: *Self) void {
    if (self.panels) |panels| {
        self.widgets.remove(panels.widget());
        self.panels = null;
    }
    tui.current().resize();
}

fn toggle_view(self: *Self, view: anytype) tp.result {
    if (self.widgets.get(@typeName(view))) |w| {
        self.widgets.remove(w.*);
    } else {
        self.widgets.add(view.create(self.a, self.plane) catch |e| return tp.exit_error(e)) catch |e| return tp.exit_error(e);
    }
    tui.current().resize();
}

const cmds = struct {
    pub const Target = Self;
    const Ctx = command.Context;

    pub fn quit(self: *Self, _: Ctx) tp.result {
        if (self.editor) |editor| if (editor.is_dirty())
            return tp.exit("unsaved changes");
        try tp.self_pid().send("quit");
    }

    pub fn quit_without_saving(_: *Self, _: Ctx) tp.result {
        try tp.self_pid().send("quit");
    }

    pub fn navigate(self: *Self, ctx: Ctx) tp.result {
        tui.reset_drag_context();
        const frame = tracy.initZone(@src(), .{ .name = "navigate" });
        defer frame.deinit();
        var file: ?[]const u8 = null;
        var file_name: []const u8 = undefined;
        var line: ?i64 = null;
        var column: ?i64 = null;
        var goto_args: []const u8 = &.{};

        var iter = ctx.args.buf;
        if (cbor.decodeMapHeader(&iter)) |len_| {
            var len = len_;
            while (len > 0) : (len -= 1) {
                var field_name: []const u8 = undefined;
                if (!(cbor.matchString(&iter, &field_name) catch |e| return tp.exit_error(e)))
                    return tp.exit_error(error.InvalidArgument);
                if (std.mem.eql(u8, field_name, "line")) {
                    if (!(cbor.matchValue(&iter, cbor.extract(&line)) catch |e| return tp.exit_error(e)))
                        return tp.exit_error(error.InvalidArgument);
                } else if (std.mem.eql(u8, field_name, "column")) {
                    if (!(cbor.matchValue(&iter, cbor.extract(&column)) catch |e| return tp.exit_error(e)))
                        return tp.exit_error(error.InvalidArgument);
                } else if (std.mem.eql(u8, field_name, "file")) {
                    if (!(cbor.matchValue(&iter, cbor.extract(&file)) catch |e| return tp.exit_error(e)))
                        return tp.exit_error(error.InvalidArgument);
                } else if (std.mem.eql(u8, field_name, "goto")) {
                    if (!(cbor.matchValue(&iter, cbor.extract_cbor(&goto_args)) catch |e| return tp.exit_error(e)))
                        return tp.exit_error(error.InvalidArgument);
                } else {
                    cbor.skipValue(&iter) catch |e| return tp.exit_error(e);
                }
            }
        } else |_| if (ctx.args.match(tp.extract(&file_name)) catch false) {
            file = file_name;
        } else return tp.exit_error(error.InvalidArgument);

        const f = project_manager.normalize_file_path(file orelse return);
        const same_file = if (self.editor) |editor| if (editor.file_path) |fp|
            std.mem.eql(u8, fp, f)
        else
            false else false;

        if (!same_file) {
            if (self.editor) |editor| {
                if (editor.is_dirty()) return tp.exit("unsaved changes");
                editor.send_editor_jump_source() catch {};
            }
            try self.create_editor();
            try command.executeName("open_file", command.fmt(.{f}));
        }
        if (goto_args.len != 0) {
            try command.executeName("goto", .{ .args = .{ .buf = goto_args } });
        } else if (line) |l| {
            try command.executeName("goto_line", command.fmt(.{l}));
            if (!same_file)
                try command.executeName("scroll_view_center", .{});
            if (column) |col|
                try command.executeName("goto_column", command.fmt(.{col}));
        } else {
            if (!same_file)
                try project_manager.get_mru_position(f);
        }
        tui.need_render();
    }

    pub fn open_help(self: *Self, _: Ctx) tp.result {
        tui.reset_drag_context();
        try self.create_editor();
        try command.executeName("open_scratch_buffer", command.fmt(.{ "help.md", @embedFile("help.md") }));
        tui.need_render();
    }

    pub fn open_config(_: *Self, _: Ctx) tp.result {
        const file_name = root.get_config_file_name() catch |e| return tp.exit_error(e);
        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_name } });
    }

    pub fn restore_session(self: *Self, _: Ctx) tp.result {
        try self.create_editor();
        self.read_restore_info() catch |e| return tp.exit_error(e);
        tui.need_render();
    }

    pub fn toggle_logview(self: *Self, _: Ctx) tp.result {
        self.logview_enabled = try self.toggle_panel_view(@import("logview.zig"), false);
    }

    pub fn show_logview(self: *Self, _: Ctx) tp.result {
        self.logview_enabled = try self.toggle_panel_view(@import("logview.zig"), true);
    }

    pub fn toggle_inputview(self: *Self, _: Ctx) tp.result {
        _ = try self.toggle_panel_view(@import("inputview.zig"), false);
    }

    pub fn toggle_inspector_view(self: *Self, _: Ctx) tp.result {
        _ = try self.toggle_panel_view(@import("inspector_view.zig"), false);
    }

    pub fn show_inspector_view(self: *Self, _: Ctx) tp.result {
        _ = try self.toggle_panel_view(@import("inspector_view.zig"), true);
    }

    pub fn jump_back(self: *Self, _: Ctx) tp.result {
        try self.location_history.back(location_jump);
    }

    pub fn jump_forward(self: *Self, _: Ctx) tp.result {
        try self.location_history.forward(location_jump);
    }

    pub fn show_home(self: *Self, _: Ctx) tp.result {
        return self.create_home();
    }

    pub fn gutter_mode_next(self: *Self, _: Ctx) tp.result {
        const tui_ = tui.current();
        var ln = tui_.config.gutter_line_numbers;
        var lnr = tui_.config.gutter_line_numbers_relative;
        if (ln and !lnr) {
            ln = true;
            lnr = true;
        } else if (ln and lnr) {
            ln = false;
            lnr = false;
        } else {
            ln = true;
            lnr = false;
        }
        tui_.config.gutter_line_numbers = ln;
        tui_.config.gutter_line_numbers_relative = lnr;
        tui_.save_config() catch |e| return tp.exit_error(e);
        if (self.widgets.get("editor_gutter")) |gutter_widget| {
            const gutter = if (gutter_widget.dynamic_cast(@import("editor_gutter.zig"))) |p| p else return;
            gutter.linenum = ln;
            gutter.relative = lnr;
        }
    }
};

pub fn handle_editor_event(self: *Self, _: tp.pid_ref, m: tp.message) tp.result {
    const editor = if (self.editor) |editor_| editor_ else return;
    var sel: ed.Selection = undefined;

    if (try m.match(.{ "E", "location", tp.more }))
        return self.location_update(m);

    if (try m.match(.{ "E", "close" })) {
        if (self.pop_file_stack(editor.file_path)) |file_path| {
            defer self.a.free(file_path);
            self.show_previous_async(file_path);
        } else self.show_home_async();
        self.editor = null;
        return;
    }

    if (try m.match(.{ "E", "sel", tp.more })) {
        if (try m.match(.{ tp.any, tp.any, "none" }))
            return self.clear_auto_find(editor);
        if (try m.match(.{ tp.any, tp.any, tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
            sel.normalize();
            if (sel.end.row - sel.begin.row > ed.max_match_lines)
                return self.clear_auto_find(editor);
            const text = editor.get_selection(sel, self.a) catch return self.clear_auto_find(editor);
            if (text.len == 0)
                return self.clear_auto_find(editor);
            if (!self.is_last_match_text(text)) {
                editor.find_in_buffer(text) catch return;
            }
        }
        return;
    }
}

pub fn location_update(self: *Self, m: tp.message) tp.result {
    var row: usize = 0;
    var col: usize = 0;
    const file_path = (self.editor orelse return).file_path orelse return;

    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col) })) {
        if (row == 0 and col == 0) return;
        project_manager.update_mru(file_path, row, col) catch {};
        return self.location_history.update(file_path, .{ .row = row + 1, .col = col + 1 }, null);
    }

    var sel: location_history.Selection = .{};
    if (try m.match(.{ tp.any, tp.any, tp.any, tp.extract(&row), tp.extract(&col), tp.extract(&sel.begin.row), tp.extract(&sel.begin.col), tp.extract(&sel.end.row), tp.extract(&sel.end.col) })) {
        project_manager.update_mru(file_path, row, col) catch {};
        return self.location_history.update(file_path, .{ .row = row + 1, .col = col + 1 }, sel);
    }
}

fn location_jump(from: tp.pid_ref, file_path: []const u8, cursor: location_history.Cursor, selection: ?location_history.Selection) void {
    if (selection) |sel|
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{ cursor.row, cursor.col, sel.begin.row, sel.begin.col, sel.end.row, sel.end.col },
        } }) catch return
    else
        from.send(.{ "cmd", "navigate", .{
            .file = file_path,
            .goto = .{ cursor.row, cursor.col },
        } }) catch return;
}

fn clear_auto_find(self: *Self, editor: *ed.Editor) !void {
    try editor.clear_matches();
    self.store_last_match_text(null);
}

fn is_last_match_text(self: *Self, text: []const u8) bool {
    const is = if (self.last_match_text) |old| std.mem.eql(u8, old, text) else false;
    self.store_last_match_text(text);
    return is;
}

fn store_last_match_text(self: *Self, text: ?[]const u8) void {
    if (self.last_match_text) |old|
        self.a.free(old);
    self.last_match_text = text;
}

pub fn get_editor(self: *Self) ?*ed.Editor {
    return self.editor;
}

pub fn walk(self: *Self, ctx: *anyopaque, f: Widget.WalkFn, w: *Widget) bool {
    return self.floating_views.walk(ctx, f) or self.widgets.walk(ctx, f, &self.widgets_widget) or f(ctx, w);
}

fn create_editor(self: *Self) tp.result {
    if (self.editor) |editor| if (editor.file_path) |file_path| self.push_file_stack(file_path) catch {};
    self.widgets.replace(0, Widget.empty(self.a, self.plane, .dynamic) catch |e| return tp.exit_error(e));
    command.executeName("enter_mode_default", .{}) catch {};
    var editor_widget = ed.create(self.a, Widget.to(self)) catch |e| return tp.exit_error(e);
    errdefer editor_widget.deinit(self.a);
    if (editor_widget.get("editor")) |editor| {
        editor.subscribe(EventHandler.to_unowned(self.statusbar)) catch @panic("subscribe unsupported");
        editor.subscribe(EventHandler.bind(self, handle_editor_event)) catch @panic("subscribe unsupported");
        self.editor = if (editor.dynamic_cast(ed.EditorWidget)) |p| &p.editor else null;
    } else @panic("mainview editor not found");
    self.widgets.replace(0, editor_widget);
    tui.current().resize();
}

fn toggle_logview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_logview" }) catch return;
}

fn toggle_inputview_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "toggle_inputview" }) catch return;
}

fn show_previous_async(_: *Self, file_path: []const u8) void {
    tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } }) catch return;
}

fn show_home_async(_: *Self) void {
    tp.self_pid().send(.{ "cmd", "show_home" }) catch return;
}

fn create_home(self: *Self) tp.result {
    tui.reset_drag_context();
    if (self.editor) |_| return;
    var home_widget = home.create(self.a, Widget.to(self)) catch |e| return tp.exit_error(e);
    errdefer home_widget.deinit(self.a);
    self.widgets.replace(0, home_widget);
    tui.current().resize();
}

fn write_restore_info(self: *Self) void {
    if (self.editor) |editor| {
        var sfa = std.heap.stackFallback(512, self.a);
        const a = sfa.get();
        var meta = std.ArrayList(u8).init(a);
        editor.write_state(meta.writer()) catch return;
        const file_name = root.get_restore_file_name() catch return;
        var file = std.fs.createFileAbsolute(file_name, .{ .truncate = true }) catch return;
        defer file.close();
        file.writeAll(meta.items) catch return;
    }
}

fn read_restore_info(self: *Self) !void {
    if (self.editor) |editor| {
        const file_name = try root.get_restore_file_name();
        const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        var buf = try self.a.alloc(u8, stat.size);
        defer self.a.free(buf);
        const size = try file.readAll(buf);
        try editor.extract_state(buf[0..size]);
    }
}

fn push_file_stack(self: *Self, file_path: []const u8) !void {
    for (self.file_stack.items, 0..) |file_path_, i|
        if (std.mem.eql(u8, file_path, file_path_))
            self.a.free(self.file_stack.orderedRemove(i));
    (try self.file_stack.addOne()).* = try self.a.dupe(u8, file_path);
}

fn pop_file_stack(self: *Self, closed: ?[]const u8) ?[]const u8 {
    if (closed) |file_path|
        for (self.file_stack.items, 0..) |file_path_, i|
            if (std.mem.eql(u8, file_path, file_path_))
                self.a.free(self.file_stack.orderedRemove(i));
    return self.file_stack.popOrNull();
}
