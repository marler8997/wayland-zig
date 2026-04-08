pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.args();
    _ = args.next(); // skip program name

    var xml_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse errExit("expected output path after -o", .{});
        } else {
            try xml_paths.append(arena, arg);
        }
    }
    if (xml_paths.items.len == 0) errExit("expected at least one XML input file", .{});

    var interfaces: std.ArrayListUnmanaged(Interface) = .empty;
    for (xml_paths.items) |xml_path| {
        const _1_GB = 1 * 1024 * 1024 * 1024;
        const data = std.fs.cwd().readFileAlloc(arena, xml_path, _1_GB) catch |err|
            errExit("failed to read '{s}': {s}", .{ xml_path, @errorName(err) });
        var parser: xml.Parser = .{ .data = data };
        parseProtocol(&parser, arena, &interfaces) catch
            errExit("failed to parse '{s}'", .{xml_path});
    }

    const out_file = if (out_path) |p|
        std.fs.cwd().createFile(p, .{}) catch |e|
            errExit("failed to create output file '{s}': {s}", .{ p, @errorName(e) })
    else
        std.fs.File.stdout();

    var write_buf: [8192]u8 = undefined;
    var file_writer = out_file.writer(&write_buf);
    const writer = &file_writer.interface;

    generate(writer, interfaces.items) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
}

const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enums: []const Enum,
    description: ?Description = null,
};

const Message = struct {
    name: []const u8,
    args: []const Arg,
    is_destructor: bool,
    description: ?Description = null,
};

const Description = struct {
    summary: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

const Arg = struct {
    name: []const u8,
    arg_type: ArgType,
    interface: ?[]const u8,
    allow_null: bool,
    enum_name: ?[]const u8,
};

const ArgType = enum { int, uint, fixed, string, object, new_id, array, fd };

const Enum = struct {
    name: []const u8,
    bitfield: bool,
    entries: []const Entry,
};

const Entry = struct {
    name: []const u8,
    value: []const u8,
};

fn parseProtocol(
    parser: *xml.Parser,
    arena: std.mem.Allocator,
    interfaces: *std.ArrayListUnmanaged(Interface),
) !void {
    while (parser.nextTag()) |tag| {
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "interface")) {
            try interfaces.append(arena, try parseInterface(parser, arena, tag));
        } else if (!tag.self_closing and
            (std.mem.eql(u8, tag.name, "description") or std.mem.eql(u8, tag.name, "copyright")))
        {
            parser.skipToClose(tag.name);
        }
    }
}

fn parseInterface(parser: *xml.Parser, arena: std.mem.Allocator, open_tag: xml.Tag) !Interface {
    const name = open_tag.getAttr("name") orelse
        std.debug.panic("interface element missing 'name' attribute", .{});
    const version = if (open_tag.getAttr("version")) |v| std.fmt.parseInt(u32, v, 10) catch 1 else 1;

    var requests: std.ArrayListUnmanaged(Message) = .empty;
    var events: std.ArrayListUnmanaged(Message) = .empty;
    var enums: std.ArrayListUnmanaged(Enum) = .empty;
    var description: ?Description = null;

    while (parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "interface")) break;
        if (tag.is_closing) continue;

        if (std.mem.eql(u8, tag.name, "request")) {
            const msg = if (tag.self_closing) msgFromTag(tag) else try parseMessage(parser, arena, tag);
            try requests.append(arena, msg);
        } else if (std.mem.eql(u8, tag.name, "event")) {
            const msg = if (tag.self_closing) msgFromTag(tag) else try parseMessage(parser, arena, tag);
            try events.append(arena, msg);
        } else if (std.mem.eql(u8, tag.name, "enum")) {
            const e = if (tag.self_closing) Enum{
                .name = tag.getAttr("name") orelse
                    std.debug.panic("enum element missing 'name' attribute", .{}),
                .bitfield = if (tag.getAttr("bitfield")) |b| std.mem.eql(u8, b, "true") else false,
                .entries = &.{},
            } else try parseEnum(parser, arena, tag);
            try enums.append(arena, e);
        } else if (std.mem.eql(u8, tag.name, "description")) {
            description = parseDescription(parser, tag);
        }
    }

    return .{
        .name = name,
        .version = version,
        .requests = try requests.toOwnedSlice(arena),
        .events = try events.toOwnedSlice(arena),
        .enums = try enums.toOwnedSlice(arena),
        .description = description,
    };
}

fn parseDescription(parser: *xml.Parser, tag: xml.Tag) Description {
    const summary = tag.getAttr("summary");
    const body = if (!tag.self_closing) blk: {
        const text = parser.getTextUntilClose("description");
        break :blk if (text.len > 0) text else null;
    } else null;
    return .{ .summary = summary, .body = body };
}

fn msgFromTag(tag: xml.Tag) Message {
    const type_str = tag.getAttr("type");
    return .{
        .name = tag.getAttr("name") orelse
            std.debug.panic("request/event element missing 'name' attribute", .{}),
        .args = &.{},
        .is_destructor = if (type_str) |t| std.mem.eql(u8, t, "destructor") else false,
    };
}

fn parseMessage(parser: *xml.Parser, arena: std.mem.Allocator, open_tag: xml.Tag) !Message {
    const name = open_tag.getAttr("name") orelse
        std.debug.panic("request/event element missing 'name' attribute", .{});
    const type_str = open_tag.getAttr("type");
    const is_destructor = if (type_str) |t| std.mem.eql(u8, t, "destructor") else false;
    var args: std.ArrayListUnmanaged(Arg) = .empty;
    var description: ?Description = null;

    while (parser.nextTag()) |tag| {
        if (tag.is_closing and (std.mem.eql(u8, tag.name, "request") or std.mem.eql(u8, tag.name, "event"))) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "arg")) {
            const arg_type_str = tag.getAttr("type") orelse
                std.debug.panic("arg element missing 'type' attribute", .{});
            try args.append(arena, .{
                .name = tag.getAttr("name") orelse
                    std.debug.panic("arg element missing 'name' attribute", .{}),
                .arg_type = parseArgType(arg_type_str),
                .interface = tag.getAttr("interface"),
                .allow_null = if (tag.getAttr("allow-null")) |s| std.mem.eql(u8, s, "true") else false,
                .enum_name = tag.getAttr("enum"),
            });
        } else if (std.mem.eql(u8, tag.name, "description")) {
            description = parseDescription(parser, tag);
        }
    }

    return .{ .name = name, .args = try args.toOwnedSlice(arena), .is_destructor = is_destructor, .description = description };
}

fn parseArgType(s: []const u8) ArgType {
    if (std.mem.eql(u8, s, "int")) return .int;
    if (std.mem.eql(u8, s, "uint")) return .uint;
    if (std.mem.eql(u8, s, "fixed")) return .fixed;
    if (std.mem.eql(u8, s, "string")) return .string;
    if (std.mem.eql(u8, s, "object")) return .object;
    if (std.mem.eql(u8, s, "new_id")) return .new_id;
    if (std.mem.eql(u8, s, "array")) return .array;
    if (std.mem.eql(u8, s, "fd")) return .fd;
    std.debug.panic("unrecognized wayland arg type: '{s}'", .{s});
}

fn parseEnum(parser: *xml.Parser, arena: std.mem.Allocator, open_tag: xml.Tag) !Enum {
    const name = open_tag.getAttr("name") orelse
        std.debug.panic("enum element missing 'name' attribute", .{});
    const bitfield = if (open_tag.getAttr("bitfield")) |s| std.mem.eql(u8, s, "true") else false;
    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    while (parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "enum")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "entry")) {
            try entries.append(arena, .{
                .name = tag.getAttr("name") orelse
                    std.debug.panic("entry element missing 'name' attribute", .{}),
                .value = tag.getAttr("value") orelse
                    std.debug.panic("entry element missing 'value' attribute", .{}),
            });
        } else if (std.mem.eql(u8, tag.name, "description")) {
            if (!tag.self_closing) parser.skipToClose("description");
        }
    }

    return .{ .name = name, .bitfield = bitfield, .entries = try entries.toOwnedSlice(arena) };
}

fn generate(w: *std.Io.Writer, interfaces: []const Interface) error{WriteFailed}!void {
    try w.writeAll(
        \\// Auto-generated by wayland-zig scanner. Do not edit.
        \\pub const SizeOpcode = packed struct(u32) {
        \\    opcode: u16,
        \\    size: u16,
        \\};
        \\pub const object = enum(u32) {
        \\    null = 0,
        \\    display = 1,
        \\    _,
        \\};
        \\/// Wayland 24.8 fixed-point number.
        \\pub const Fixed = packed struct(i32) {
        \\    raw: i32,
        \\    pub fn fromFloat(v: f64) Fixed {
        \\        return .{ .raw = @intFromFloat(v * 256.0) };
        \\    }
        \\    pub fn toFloat(self: Fixed) f64 {
        \\        return @as(f64, @floatFromInt(self.raw)) / 256.0;
        \\    }
        \\};
        \\
    );
    for (interfaces) |iface| {
        try generateInterface(w, iface, interfaces);
    }

    // Generate Interface enum with hasDestructor
    try w.writeAll("pub const Interface = enum {\n");
    for (interfaces) |iface| {
        try w.print("    {f},\n", .{fmtId(iface.name)});
    }
    try w.writeAll(
        \\
        \\    pub fn hasDestructor(self: Interface) bool {
        \\        return switch (self) {
        \\
    );
    for (interfaces) |iface| {
        const has_destructor = for (iface.requests) |req| {
            if (req.is_destructor) break true;
        } else false;
        try w.print("            .{f} => {},\n", .{ fmtId(iface.name), has_destructor });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\};
        \\
    );

    try w.writeAll(
        \\pub const std = @import("std");
        \\pub const native_endian = @import("builtin").cpu.arch.endian();
        \\
    );
    try w.flush();
}

fn stripWlPrefix(name: []const u8) []const u8 {
    var result = name;
    // Strip common protocol prefixes
    const prefixes = [_][]const u8{ "wl_", "zwlr_", "zwp_", "wp_", "ext_" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, result, prefix)) {
            result = result[prefix.len..];
            break;
        }
    }
    // Strip _vN version suffix (e.g. _v1, _v2)
    if (result.len > 3 and result[result.len - 3] == '_' and result[result.len - 2] == 'v' and std.ascii.isDigit(result[result.len - 1])) {
        result = result[0 .. result.len - 3];
    }
    return result;
}

fn emitDocComment(w: *std.Io.Writer, desc: ?Description, indent: []const u8) error{WriteFailed}!void {
    const d = desc orelse return;
    if (d.body) |body| {
        try emitDocLines(w, body, indent);
    } else if (d.summary) |summary| {
        try emitDocLines(w, summary, indent);
    }
}

fn emitDocLines(w: *std.Io.Writer, text: []const u8, indent: []const u8) error{WriteFailed}!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            try w.print("{s}///\n", .{indent});
        } else {
            try w.print("{s}/// {s}\n", .{ indent, trimmed });
        }
    }
}

fn generateInterface(w: *std.Io.Writer, iface: Interface, all_interfaces: []const Interface) error{WriteFailed}!void {
    const name = stripWlPrefix(iface.name);
    try emitDocComment(w, iface.description, "");
    try w.print("pub const {f} = struct {{\n", .{fmtId(name)});
    try w.print("    pub const name = \"{s}\";\n", .{iface.name});
    const has_destructor = for (iface.requests) |req| {
        if (req.is_destructor) break true;
    } else false;
    try w.print("    pub const has_destructor = {};\n", .{has_destructor});
    if (iface.version == 1) {
        try w.writeAll("    /// This field only exists while the interface is at v1.\n");
        try w.writeAll("    /// Reference it to induce compile errors when the version changes.\n");
        try w.writeAll("    pub const version1 = 1;\n");
    } else {
        try w.print("    pub const version = {};\n", .{iface.version});
    }
    for (iface.enums) |e| {
        // Check if enum name collides with a request name (events are nested in
        // the event struct so they don't collide). Also check "event" and "version".
        const collides = for (iface.requests) |req| {
            if (std.mem.eql(u8, e.name, req.name)) break true;
        } else std.mem.eql(u8, e.name, "event") or std.mem.eql(u8, e.name, "name") or std.mem.eql(u8, e.name, "version") or std.mem.eql(u8, e.name, "version1");
        try generateEnum(w, e, collides);
    }
    if (iface.events.len > 0) {
        try w.writeAll("    pub const event = struct {\n");
        for (iface.events, 0..) |ev, i| {
            try w.print("        pub const {f} = {};\n", .{ fmtId(ev.name), i });
        }
        try w.writeAll("    };\n");
    }
    for (iface.requests, 0..) |req, opcode| {
        try generateRequest(w, name, req, @intCast(opcode), iface, all_interfaces);
    }
    try w.writeAll("};\n\n");
}

fn generateEnum(w: *std.Io.Writer, e: Enum, name_collision: bool) error{WriteFailed}!void {
    var name_buf: [256]u8 = undefined;
    const zig_name = if (name_collision) blk: {
        const written = std.fmt.bufPrint(&name_buf, "{s}_enum", .{e.name}) catch e.name;
        break :blk fmtId(written);
    } else fmtId(e.name);

    if (e.bitfield) {
        try w.print("    pub const {f} = struct {{\n", .{zig_name});
        for (e.entries) |entry| {
            try w.print("        pub const {f}: u32 = {s};\n", .{ fmtId(entry.name), entry.value });
        }
        try w.writeAll("    };\n");
    } else {
        try w.print("    pub const {f} = enum(u32) {{\n", .{zig_name});
        for (e.entries) |entry| {
            try w.print("        {f} = {s},\n", .{ fmtId(entry.name), entry.value });
        }
        try w.writeAll("    };\n");
    }
}

fn hasFdArg(msg: Message) bool {
    for (msg.args) |arg| {
        if (arg.arg_type == .fd) return true;
    }
    return false;
}

fn hasUntypedNewId(msg: Message) bool {
    for (msg.args) |arg| {
        if (arg.arg_type == .new_id and arg.interface == null) return true;
    }
    return false;
}

/// Write an arg's parameter name. For object/new_id types, appends "_id" if
/// the XML name doesn't already end with "_id", to avoid shadowing top-level types.
/// Also appends "_arg" if the name collides with a declaration in the same struct.
fn writeArgParam(w: *std.Io.Writer, arg: Arg, enums: []const Enum) error{WriteFailed}!void {
    if ((arg.arg_type == .object or arg.arg_type == .new_id) and !std.mem.endsWith(u8, arg.name, "_id") and !std.mem.eql(u8, arg.name, "id")) {
        try w.print("{f}_id", .{fmtId(arg.name)});
    } else if (declCollision(arg.name, enums)) {
        try w.print("{f}_arg", .{fmtId(arg.name)});
    } else {
        try w.print("{f}", .{fmtId(arg.name)});
    }
}

/// Check if an arg name collides with a struct-level declaration (enum, constant, or nested struct).
fn declCollision(name: []const u8, enums: []const Enum) bool {
    const reserved = [_][]const u8{ "name", "version", "version1", "event" };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    for (enums) |e| {
        if (std.mem.eql(u8, name, e.name)) return true;
    }
    return false;
}

fn generateRequest(w: *std.Io.Writer, iface_name: []const u8, req: Message, opcode: u16, iface: Interface, all_interfaces: []const Interface) error{WriteFailed}!void {
    if (hasFdArg(req)) {
        try w.print("    // {s}: fd-passing request, see manual implementation\n", .{req.name});
        return;
    }

    if (hasUntypedNewId(req)) {
        return generateUntypedNewIdRequest(w, iface_name, req, opcode, iface, all_interfaces);
    }

    var has_dynamic = false;
    for (req.args) |arg| {
        if (arg.arg_type == .string or arg.arg_type == .array) {
            has_dynamic = true;
            break;
        }
    }

    const is_display = std.mem.eql(u8, iface.name, "wl_display");

    // Doc comment
    try emitDocComment(w, req.description, "    ");
    if (req.is_destructor) {
        if (req.description != null) try w.writeAll("    ///\n");
        try w.writeAll("    /// This request is a destructor, the object id is invalid after sending it.\n");
    }

    // Signature
    try w.print("    pub fn {f}(writer: *std.Io.Writer", .{fmtId(req.name)});
    if (!is_display) {
        try w.print(", {f}_id: object", .{fmtId(iface_name)});
    }
    for (req.args) |arg| {
        try w.writeAll(", ");
        try writeArgParam(w, arg, iface.enums);
        try w.writeAll(": ");
        try writeArgType(w, arg, iface, all_interfaces);
    }
    try w.writeAll(") error{WriteFailed}!void {\n");

    if (has_dynamic) {
        try emitDynamicBody(w, iface_name, req, opcode, iface, all_interfaces);
    } else {
        try emitStaticBody(w, iface_name, req, opcode, iface, all_interfaces);
    }

    try w.writeAll("    }\n");
}

fn emitStaticBody(w: *std.Io.Writer, iface_name: []const u8, req: Message, opcode: u16, iface: Interface, all_interfaces: []const Interface) error{WriteFailed}!void {
    const is_display = std.mem.eql(u8, iface.name, "wl_display");
    var size: u32 = 8;
    for (req.args) |arg| size += argFixedSize(arg);
    try w.print("        const msg_len: u16 = {};\n", .{size});
    if (is_display) {
        try w.writeAll("        try writer.writeInt(u32, @intFromEnum(object.display), native_endian);\n");
    } else {
        try w.print("        try writer.writeInt(u32, @intFromEnum({f}_id), native_endian);\n", .{fmtId(iface_name)});
    }
    try w.print("        try writer.writeInt(u32, @bitCast(SizeOpcode{{ .size = msg_len, .opcode = {} }}), native_endian);\n", .{opcode});
    for (req.args) |arg| try emitSerialize(w, arg, iface, all_interfaces);
}

fn emitDynamicBody(
    w: *std.Io.Writer,
    iface_name: []const u8,
    req: Message,
    opcode: u16,
    iface: Interface,
    all_interfaces: []const Interface,
) error{WriteFailed}!void {
    const enums = iface.enums;
    // Compute variable lengths
    for (req.args) |arg| {
        if (arg.arg_type == .string and arg.allow_null) {
            try w.writeAll("        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_len: u32 = if (");
            try writeArgParam(w, arg, enums);
            try w.writeAll(") |s| @intCast(s.len + 1) else 0;\n        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padded_len: u32 = if (");
            try writeArgParam(w, arg, enums);
            try w.writeAll(" != null) std.mem.alignForward(u32, ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_len, 4) else 0;\n");
        } else if (arg.arg_type == .string) {
            try w.writeAll("        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_len: u32 = @intCast(");
            try writeArgParam(w, arg, enums);
            try w.writeAll(".len + 1);\n        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padded_len = std.mem.alignForward(u32, ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_len, 4);\n");
        } else if (arg.arg_type == .array) {
            try w.writeAll("        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padded_len = std.mem.alignForward(u32, @as(u32, @intCast(");
            try writeArgParam(w, arg, enums);
            try w.writeAll(".len)), 4);\n");
        }
    }

    try w.writeAll("        const msg_len: u16 = 8");
    for (req.args) |arg| {
        if (arg.arg_type == .string or arg.arg_type == .array) {
            try w.writeAll(" + 4 + @as(u16, @intCast(");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padded_len))");
        } else {
            try w.print(" + {}", .{argFixedSize(arg)});
        }
    }
    try w.writeAll(";\n");

    if (std.mem.eql(u8, iface.name, "wl_display")) {
        try w.writeAll("        try writer.writeInt(u32, @intFromEnum(object.display), native_endian);\n");
    } else {
        try w.print("        try writer.writeInt(u32, @intFromEnum({f}_id), native_endian);\n", .{fmtId(iface_name)});
    }
    try w.print("        try writer.writeInt(u32, @bitCast(SizeOpcode{{ .size = msg_len, .opcode = {} }}), native_endian);\n", .{opcode});

    for (req.args) |arg| try emitSerialize(w, arg, iface, all_interfaces);
}

fn generateUntypedNewIdRequest(
    w: *std.Io.Writer,
    iface_name: []const u8,
    req: Message,
    opcode: u16,
    iface: Interface,
    all_interfaces: []const Interface,
) error{WriteFailed}!void {
    const is_display = std.mem.eql(u8, iface.name, "wl_display");
    try emitDocComment(w, req.description, "    ");
    try w.print("    pub fn {f}(writer: *std.Io.Writer", .{fmtId(req.name)});
    if (!is_display) {
        try w.print(", {f}_id: object", .{fmtId(iface_name)});
    }
    for (req.args) |arg| {
        if (arg.arg_type == .new_id and arg.interface == null) {
            try w.writeAll(", interface: []const u8, version: u32, id: object");
        } else {
            try w.writeAll(", ");
            try writeArgParam(w, arg, iface.enums);
            try w.writeAll(": ");
            try writeArgType(w, arg, iface, all_interfaces);
        }
    }
    try w.writeAll(") error{WriteFailed}!void {\n");

    try w.writeAll(
        \\        const str_len: u32 = @intCast(interface.len + 1);
        \\        const padded_str_len = std.mem.alignForward(u32, str_len, 4);
        \\
    );

    try w.writeAll("        const msg_len: u16 = 8");
    for (req.args) |arg| {
        if (arg.arg_type == .new_id and arg.interface == null) {
            try w.writeAll(" + (4 + @as(u16, @intCast(padded_str_len))) + 4 + 4");
        } else {
            try w.print(" + {}", .{argFixedSize(arg)});
        }
    }
    try w.writeAll(";\n");

    if (is_display) {
        try w.writeAll("        try writer.writeInt(u32, @intFromEnum(object.display), native_endian);\n");
    } else {
        try w.print("        try writer.writeInt(u32, @intFromEnum({f}_id), native_endian);\n", .{fmtId(iface_name)});
    }
    try w.print("        try writer.writeInt(u32, @bitCast(SizeOpcode{{ .size = msg_len, .opcode = {} }}), native_endian);\n", .{opcode});

    for (req.args) |arg| {
        if (arg.arg_type == .new_id and arg.interface == null) {
            try w.writeAll(
                \\        try writer.writeInt(u32, str_len, native_endian);
                \\        try writer.writeAll(interface);
                \\        const padding = padded_str_len - @as(u32, @intCast(interface.len));
                \\        try writer.writeAll(("\x00\x00\x00\x00")[0..padding]);
                \\        try writer.writeInt(u32, version, native_endian);
                \\        try writer.writeInt(u32, @intFromEnum(id), native_endian);
                \\
            );
        } else {
            try emitSerialize(w, arg, iface, all_interfaces);
        }
    }

    try w.writeAll("    }\n");
}

fn writeArgType(
    w: *std.Io.Writer,
    arg: Arg,
    iface: Interface,
    all_interfaces: []const Interface,
) error{WriteFailed}!void {
    if (arg.enum_name) |enum_ref| {
        if (!isEnumBitfield(enum_ref, iface, all_interfaces)) {
            // Non-bitfield enum: use the actual enum type
            if (std.mem.indexOfScalar(u8, enum_ref, '.')) |dot_pos| {
                // Cross-interface: "wl_shm.format" -> "shm.format"
                try w.print("{f}.{f}", .{ fmtId(stripWlPrefix(enum_ref[0..dot_pos])), fmtId(enum_ref[dot_pos + 1 ..]) });
            } else {
                try w.print("{f}", .{fmtId(enum_ref)});
            }
            return;
        }
        // Bitfield enums stay as u32
    }
    switch (arg.arg_type) {
        .int => try w.writeAll("i32"),
        .uint => try w.writeAll("u32"),
        .fixed => try w.writeAll("Fixed"),
        .string => try w.writeAll(if (arg.allow_null) "?[]const u8" else "[]const u8"),
        .object => try w.writeAll(if (arg.allow_null) "?object" else "object"),
        .new_id => try w.writeAll("object"),
        .array => try w.writeAll("[]const u8"),
        .fd => try w.writeAll("std.posix.fd_t"),
    }
}

fn isEnumBitfield(enum_ref: []const u8, current_iface: Interface, all_interfaces: []const Interface) bool {
    if (std.mem.indexOfScalar(u8, enum_ref, '.')) |dot_pos| {
        // Cross-interface reference
        const iface_name = enum_ref[0..dot_pos];
        const enum_name = enum_ref[dot_pos + 1 ..];
        for (all_interfaces) |iface| {
            if (std.mem.eql(u8, iface.name, iface_name)) {
                for (iface.enums) |e| {
                    if (std.mem.eql(u8, e.name, enum_name)) return e.bitfield;
                }
            }
        }
    } else {
        // Local reference
        for (current_iface.enums) |e| {
            if (std.mem.eql(u8, e.name, enum_ref)) return e.bitfield;
        }
    }
    return false; // Unknown enum, treat as non-bitfield
}

fn argFixedSize(arg: Arg) u32 {
    return switch (arg.arg_type) {
        .int, .uint, .fixed, .object, .new_id => 4,
        .string, .array, .fd => 0,
    };
}

fn emitSerialize(
    w: *std.Io.Writer,
    arg: Arg,
    iface: Interface,
    all_interfaces: []const Interface,
) error{WriteFailed}!void {
    const enums = iface.enums;
    switch (arg.arg_type) {
        .int => {
            try w.writeAll("        try writer.writeInt(i32, ");
            if (arg.enum_name) |enum_ref| {
                if (!isEnumBitfield(enum_ref, iface, all_interfaces)) {
                    try w.writeAll("@bitCast(@intFromEnum(");
                    try writeArgParam(w, arg, enums);
                    try w.writeAll("))");
                } else {
                    try writeArgParam(w, arg, enums);
                }
            } else {
                try writeArgParam(w, arg, enums);
            }
            try w.writeAll(", native_endian);\n");
        },
        .fixed => {
            try w.writeAll("        try writer.writeInt(i32, ");
            try writeArgParam(w, arg, enums);
            try w.writeAll(".raw, native_endian);\n");
        },
        .uint => {
            try w.writeAll("        try writer.writeInt(u32, ");
            if (arg.enum_name) |enum_ref| {
                if (!isEnumBitfield(enum_ref, iface, all_interfaces)) {
                    try w.writeAll("@intFromEnum(");
                    try writeArgParam(w, arg, enums);
                    try w.writeAll(")");
                } else {
                    try writeArgParam(w, arg, enums);
                }
            } else {
                try writeArgParam(w, arg, enums);
            }
            try w.writeAll(", native_endian);\n");
        },
        .object => {
            try w.writeAll("        try writer.writeInt(u32, @intFromEnum(");
            try writeArgParam(w, arg, enums);
            if (arg.allow_null) try w.writeAll(" orelse .null");
            try w.writeAll("), native_endian);\n");
        },
        .new_id => {
            try w.writeAll("        try writer.writeInt(u32, @intFromEnum(");
            try writeArgParam(w, arg, enums);
            try w.writeAll("), native_endian);\n");
        },
        .string => {
            try w.writeAll("        try writer.writeInt(u32, ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_len, native_endian);\n");
            if (arg.allow_null) {
                try w.writeAll("        if (");
                try writeArgParam(w, arg, enums);
                try w.writeAll(") |s| {\n");
                try w.writeAll("            try writer.writeAll(s);\n            const ");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padding = ");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padded_len - @as(u32, @intCast(s.len));\n");
                try w.writeAll("            try writer.writeAll((\"\\x00\\x00\\x00\\x00\")[0..");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padding]);\n        }\n");
            } else {
                try w.writeAll("        try writer.writeAll(");
                try writeArgParam(w, arg, enums);
                try w.writeAll(");\n        const ");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padding = ");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padded_len - @as(u32, @intCast(");
                try writeArgParam(w, arg, enums);
                try w.writeAll(".len));\n        try writer.writeAll((\"\\x00\\x00\\x00\\x00\")[0..");
                try writeArgParam(w, arg, enums);
                try w.writeAll("_padding]);\n");
            }
        },
        .array => {
            try w.writeAll("        try writer.writeInt(u32, @intCast(");
            try writeArgParam(w, arg, enums);
            try w.writeAll(".len), native_endian);\n        try writer.writeAll(");
            try writeArgParam(w, arg, enums);
            try w.writeAll(");\n        const ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padding = ");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padded_len - @as(u32, @intCast(");
            try writeArgParam(w, arg, enums);
            try w.writeAll(".len));\n        if (");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padding > 0) try writer.writeAll((\"\\x00\\x00\\x00\\x00\")[0..");
            try writeArgParam(w, arg, enums);
            try w.writeAll("_padding]);\n");
        },
        .fd => {},
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const fmtId = std.zig.fmtId;
const xml = @import("xml.zig");
