pub const Writer = std.Io.Writer;
pub const Reader = std.Io.Reader;

/// Any application that supports windows can call this at
/// the start of their program to setup initialize WSA (Winsock API).
pub fn wsaStartup() !void {
    if (builtin.os.tag == .windows) {
        _ = try windows.WSAStartup(2, 2);
    }
}

const unix_sockaddr_path_offset = @offsetOf(posix.sockaddr.un, "path");

/// Wraps a unix sockaddr so it can also hold the associated socket len
/// and also provides a format function.
pub const Sockaddr = struct {
    unix: posix.sockaddr.un,
    len: posix.socklen_t,
    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(addr: *const Sockaddr, writer: *std.Io.Writer) error{WriteFailed}!void {
        try addr.formatLegacy("", .{}, writer);
    }
    fn formatLegacy(
        addr: *const Sockaddr,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{addr.unix.path[0 .. addr.len - unix_sockaddr_path_offset]});
    }
};

pub const SockaddrError = union(enum) {
    wayland_display_too_long: [:0]const u8,
    xdg_runtime_dir_too_long: [:0]const u8,
    path_too_long: struct {
        xdg_runtime_dir: [:0]const u8,
        wayland_display: [:0]const u8,
    },
    wayland_display_no_xdg: [:0]const u8,
    no_wayland_display_and_xdg,

    pub fn set(err: *SockaddrError, val: SockaddrError) error{Sockaddr} {
        err.* = val;
        return error.Sockaddr;
    }

    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(err: *const SockaddrError, writer: *std.Io.Writer) error{WriteFailed}!void {
        try err.formatLegacy("", .{}, writer);
    }
    fn formatLegacy(
        err: *const SockaddrError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (err.*) {
            .wayland_display_too_long => |d| try writer.print("WAYLAND_DISPLAY environment variable '{s}' is too long", .{d}),
            .xdg_runtime_dir_too_long => |d| try writer.print("XDG_RUNTIME_DIR environment variable '{s}' is too long", .{d}),
            .path_too_long => |p| try writer.print("$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ({s}/{s}) is too long", .{ p.xdg_runtime_dir, p.wayland_display }),
            .wayland_display_no_xdg => |d| try writer.print("XDG_RUNTIME_DIR environment variable is not set and WAYLAND_DISPLAY '{s}' is not an absolute path", .{d}),
            .no_wayland_display_and_xdg => try writer.writeAll("neither WAYLAND_DISPLAY nor XDG_RUNTIME_DIR environment variables are set"),
        }
    }
};

/// Retrieves the path to the Wayland socket file based on the WAYLAND_DISPLAY
/// and XDG_RUNTIME_DIR environment variables.
pub fn getSockaddr(out_err: *SockaddrError) error{Sockaddr}!Sockaddr {
    var result: Sockaddr = .{
        .unix = .{ .path = undefined },
        .len = 0,
    };
    const maybe_wayland_display: ?[:0]const u8 = blk: {
        if (posix.getenv("WAYLAND_DISPLAY")) |wayland_display| {
            if (wayland_display.len + 1 > result.unix.path.len) return out_err.set(.{
                .wayland_display_too_long = wayland_display,
            });
            if (std.fs.path.isAbsolute(wayland_display)) {
                @memcpy(&result.unix.path, wayland_display);
                result.unix.path[wayland_display.len] = 0;
                result.len = @intCast(wayland_display.len);
                return result;
            }
            break :blk wayland_display;
        }
        break :blk null;
    };

    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime_dir| {
        if (xdg_runtime_dir.len + 1 > result.unix.path.len) return out_err.set(.{ .xdg_runtime_dir_too_long = xdg_runtime_dir });
        const wayland_display = maybe_wayland_display orelse "wayland-0";
        const slice = std.fmt.bufPrintZ(&result.unix.path, "{s}/{s}", .{ xdg_runtime_dir, wayland_display }) catch |err| switch (err) {
            error.NoSpaceLeft => return out_err.set(.{ .path_too_long = .{
                .xdg_runtime_dir = xdg_runtime_dir,
                .wayland_display = wayland_display,
            } }),
        };
        result.len = @intCast(unix_sockaddr_path_offset + slice.len);
        return result;
    }
    return if (maybe_wayland_display) |d|
        out_err.set(.{ .wayland_display_no_xdg = d })
    else
        out_err.set(.no_wayland_display_and_xdg);
}

/// Just a convenience function to create/connect a unix socket to the given unix sockaddr.
pub const ConnectError = posix.SocketError || posix.ConnectError;
pub fn connect(addr: *const Sockaddr) ConnectError!std.net.Stream {
    const sockfd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer std.net.Stream.close(.{ .handle = sockfd });
    try posix.connect(sockfd, @ptrCast(&addr.unix), addr.len);
    return .{ .handle = sockfd };
}

pub fn disconnect(stream: std.net.Stream) void {
    posix.shutdown(stream.handle, .both) catch {}; // ignore any error here
    stream.close();
}

// returns the sender object/opcode/size
pub fn readHeader(reader: *Reader) error{ ReadFailed, EndOfStream }!struct { object, u16, u16 } {
    const sender: object = @enumFromInt(try reader.takeInt(u32, native_endian));
    const second: SizeOpcode = @bitCast(try reader.takeInt(u32, native_endian));
    return .{ sender, second.opcode, second.size };
}

pub const SizeOpcode = generated.SizeOpcode;
pub const object = generated.object;
pub const Fixed = generated.Fixed;
pub const native_endian = generated.native_endian;

// Re-export all generated interfaces. For interfaces with fd-passing requests,
// we define manual overrides below.
pub const display = generated.display;
pub const registry = generated.registry;
pub const callback = generated.callback;
pub const compositor = generated.compositor;
pub const shm_pool = generated.shm_pool;
pub const buffer = generated.buffer;
pub const data_offer = generated.data_offer;
pub const data_source = generated.data_source;
pub const data_device = generated.data_device;
pub const data_device_manager = generated.data_device_manager;
pub const shell = generated.shell;
pub const shell_surface = generated.shell_surface;
pub const surface = generated.surface;
pub const seat = generated.seat;
pub const pointer = generated.pointer;
pub const keyboard = generated.keyboard;
pub const touch = generated.touch;
pub const output = generated.output;
pub const region = generated.region;
pub const subcompositor = generated.subcompositor;
pub const subsurface = generated.subsurface;

// --- Extension protocols (xdg-shell, wlr-layer-shell) ---
pub const xdg_wm_base = generated.xdg_wm_base;
pub const xdg_positioner = generated.xdg_positioner;
pub const xdg_surface = generated.xdg_surface;
pub const xdg_toplevel = generated.xdg_toplevel;
pub const xdg_popup = generated.xdg_popup;
pub const viewporter = generated.viewporter;
pub const viewport = generated.viewport;
pub const layer_shell = generated.layer_shell;
pub const layer_surface = generated.layer_surface;

// --- Manual fd-passing implementations ---
// These interfaces have requests that pass file descriptors via SCM_RIGHTS.
// The generated code emits comments for these; we provide full manual implementations.

pub const shm = struct {
    pub const name = generated.shm.name;
    pub const version = generated.shm.version;
    pub const @"error" = generated.shm.@"error";
    pub const format = generated.shm.format;
    pub const event = generated.shm.event;

    // create_pool requires fd passing via sendmsg
    pub fn create_pool(stream: std.net.Stream, shm_id: object, pool_id: object, fd: std.posix.fd_t, size: u32) !void {
        var request: [16]u8 = undefined;
        std.mem.writeInt(u32, request[0..4], @intFromEnum(shm_id), native_endian);
        std.mem.writeInt(u32, request[4..8], @bitCast(SizeOpcode{ .size = request.len, .opcode = 0 }), native_endian);
        std.mem.writeInt(u32, request[8..12], @intFromEnum(pool_id), native_endian);
        std.mem.writeInt(u32, request[12..16], size, native_endian);
        const iov = [_]std.posix.iovec_const{
            .{ .base = &request, .len = request.len },
        };
        const cmsg: Cmsg(std.posix.fd_t) = .{
            .level = std.posix.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
            .data = fd,
        };
        const msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = cmsg.len,
            .flags = 0,
        };
        const sent = try std.posix.sendmsg(stream.handle, &msg, 0);
        if (sent != 16) {
            std.log.err("create_pool: expected to send 16 bytes but only sent {}", .{sent});
            return error.WriteTruncated;
        }
    }

    // release: generated as normal (no fd)
    pub const release = generated.shm.release;
};

pub const linux_dmabuf = generated.linux_dmabuf;
pub const linux_dmabuf_feedback = generated.linux_dmabuf_feedback;

pub const linux_buffer_params = struct {
    pub const event = generated.linux_buffer_params.event;
    pub const destroy = generated.linux_buffer_params.destroy;
    pub const create_immed = generated.linux_buffer_params.create_immed;

    /// Add a dmabuf plane. The fd is sent via SCM_RIGHTS using sendmsg.
    pub fn add(
        stream: std.net.Stream,
        params_id: object,
        fd: posix.fd_t,
        plane_idx: u32,
        offset: u32,
        stride: u32,
        modifier_hi: u32,
        modifier_lo: u32,
    ) !void {
        var request: [32]u8 = undefined;
        std.mem.writeInt(u32, request[0..4], @intFromEnum(params_id), native_endian);
        std.mem.writeInt(u32, request[4..8], @bitCast(SizeOpcode{ .size = request.len, .opcode = 1 }), native_endian);
        std.mem.writeInt(u32, request[8..12], plane_idx, native_endian);
        std.mem.writeInt(u32, request[12..16], offset, native_endian);
        std.mem.writeInt(u32, request[16..20], stride, native_endian);
        std.mem.writeInt(u32, request[20..24], modifier_hi, native_endian);
        std.mem.writeInt(u32, request[24..28], modifier_lo, native_endian);
        std.mem.writeInt(u32, request[28..32], 0, native_endian);
        const iov = [_]posix.iovec_const{
            .{ .base = &request, .len = request.len },
        };
        const cmsg: Cmsg(posix.fd_t) = .{
            .level = posix.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
            .data = fd,
        };
        const msg: posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = cmsg.len,
            .flags = 0,
        };
        const sent = try posix.sendmsg(stream.handle, &msg, 0);
        if (sent != request.len) {
            std.log.err("linux_dmabuf_params.add: expected to send {} bytes but sent {}", .{ request.len, sent });
            return error.WriteTruncated;
        }
    }
};

pub fn Cmsg(comptime T: type) type {
    const padding_size: usize = padLen(@sizeOf(c_ulong), @truncate(@sizeOf(T)));
    return extern struct {
        len: usize = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [1]u8{0} ** padding_size,
    };
}

pub fn Pad(align_to: comptime_int) type {
    return switch (align_to) {
        4 => u2,
        8 => u3,
        else => @compileError("todo"),
    };
}
fn padLen(comptime align_to: comptime_int, len: Pad(align_to)) Pad(align_to) {
    return (0 -% len) & (align_to - 1);
}

/// Tracks a statically-known set of object IDs.
pub fn IdTable(comptime IdEnum: type) type {
    const enum_info = switch (@typeInfo(IdEnum)) {
        .@"enum" => |i| i,
        else => |i| @compileError("IdTable requires an enum type but got " ++ @tagName(i)),
    };
    if (!@hasField(IdEnum, "display")) @compileError("the enum given to IdTable must have a field named 'display'");

    for (std.meta.fields(IdEnum), 0..) |field, i| {
        std.debug.assert(field.value == i);
    }

    const capacity = enum_info.fields.len;
    const ObjId = std.math.IntFittingRange(0, capacity);
    const Count = std.math.IntFittingRange(0, capacity);

    const count_before_display = @intFromEnum(IdEnum.display);
    const count_after_display = capacity - 1 - @intFromEnum(IdEnum.display);

    return struct {
        enum_to_obj: [capacity]ObjId = ([1]ObjId{0} ** count_before_display) ++
            [1]ObjId{1} ++
            ([1]ObjId{0} ** count_after_display),
        obj_to_enum: [capacity]IdEnum = [1]IdEnum{.display} ++ ([1]IdEnum{undefined} ** (capacity - 1)),
        last_id: Count = 1,

        const Self = @This();

        pub fn new(table: *Self, id: IdEnum) object {
            std.debug.assert(table.enum_to_obj[@intFromEnum(id)] == 0);
            const obj_id = table.last_id + 1;
            std.debug.assert(obj_id <= capacity);

            table.enum_to_obj[@intFromEnum(id)] = obj_id;
            table.obj_to_enum[obj_id - 1] = id;
            table.last_id = obj_id;
            return @enumFromInt(obj_id);
        }

        pub fn get(table: *const Self, id: IdEnum) object {
            const obj_id = table.enum_to_obj[@intFromEnum(id)];
            std.debug.assert(obj_id != 0);
            return @enumFromInt(obj_id);
        }

        pub fn lookup(table: *const Self, o: object) IdEnum {
            const raw = @intFromEnum(o);
            std.debug.assert(raw >= 1 and raw <= table.last_id);
            return table.obj_to_enum[raw - 1];
        }
    };
}

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const generated = @import("generated");
