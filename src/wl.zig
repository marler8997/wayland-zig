pub const native_endian = @import("builtin").cpu.arch.endian();
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

const SizeOpcode = packed struct(u32) {
    opcode: u16,
    size: u16,
};

// returns the sender object/opcode/size
pub fn readHeader(reader: *Reader) error{ ReadFailed, EndOfStream }!struct { object, u16, u16 } {
    const sender: object = @enumFromInt(try reader.takeInt(u32, native_endian));
    const second: SizeOpcode = @bitCast(try reader.takeInt(u32, native_endian));
    return .{ sender, second.opcode, second.size };
}

pub const object = enum(u32) {
    null = 0,
    display = 1,
    _,
};

pub const display = struct {
    pub const event = struct {
        pub const @"error" = 0;
        pub const delete_id = 1;
    };
    pub fn sync(writer: *Writer, callback_id: object) error{WriteFailed}!void {
        const msg_len = 12;
        try writer.writeInt(u32, @intFromEnum(object.display), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(callback_id), native_endian);
    }
    pub fn get_registry(writer: *Writer, id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(object.display), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(id), native_endian);
    }
};
pub const registry = struct {
    pub const event = struct {
        pub const global = 0;
    };
    pub fn bind(writer: *Writer, registry_id: object, name: u32, interface: []const u8, version: u32, id: object) error{WriteFailed}!void {
        const str_len: u32 = @intCast(interface.len + 1); // includes null terminator
        const padded_str_len = std.mem.alignForward(u32, str_len, 4);
        const msg_len: u32 = 8 + 4 + (4 + padded_str_len) + 4 + 4; // header + name + string + version + new_id

        try writer.writeInt(u32, @intFromEnum(registry_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = @intCast(msg_len), .opcode = 0 }), native_endian);
        try writer.writeInt(u32, name, native_endian);
        // untyped new_id: string (interface), uint (version), uint (id)
        try writer.writeInt(u32, str_len, native_endian);
        try writer.writeAll(interface);
        const padding = padded_str_len - @as(u32, @intCast(interface.len));
        try writer.writeAll(("\x00\x00\x00\x00")[0..padding]); // null terminator + padding
        try writer.writeInt(u32, version, native_endian);
        try writer.writeInt(u32, @intFromEnum(id), native_endian);
    }
};
pub const callback = struct {
    pub const event = struct {
        pub const done = 0;
    };
};
pub const compositor = struct {
    pub const version = 5;
    pub fn create_surface(writer: *Writer, compositor_id: object, surface_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(compositor_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
    }
    pub fn create_region(writer: *Writer, compositor_id: object, region_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(compositor_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(region_id), native_endian);
    }
};
pub const shm = struct {
    pub const version = 2;
    pub const event = struct {
        pub const format = 0;
    };
    pub const format = enum(u32) {
        argb8888 = 0,
        xrgb8888 = 1,
    };

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
};

pub const shm_pool = struct {
    pub fn create_buffer(
        writer: *Writer,
        pool_id: object,
        buffer_id: object,
        offset: i32,
        width: i32,
        height: i32,
        stride: i32,
        format: shm.format,
    ) error{WriteFailed}!void {
        const msg_len: u16 = 32;
        try writer.writeInt(u32, @intFromEnum(pool_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(buffer_id), native_endian);
        try writer.writeInt(i32, offset, native_endian);
        try writer.writeInt(i32, width, native_endian);
        try writer.writeInt(i32, height, native_endian);
        try writer.writeInt(i32, stride, native_endian);
        try writer.writeInt(u32, @intFromEnum(format), native_endian);
    }
    pub fn destroy(writer: *Writer, pool_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(pool_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
    }
};
pub const xdg_wm_base = struct {
    pub const version = 5;
    pub const event = struct {
        pub const ping = 0;
    };
    pub fn get_xdg_surface(writer: *Writer, wm_base_id: object, xdg_surface_id: object, surface_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(wm_base_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 2 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(xdg_surface_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
    }
    pub fn pong(writer: *Writer, wm_base_id: object, serial: u32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(wm_base_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 3 }), native_endian);
        try writer.writeInt(u32, serial, native_endian);
    }
};

pub const xdg_surface = struct {
    pub const event = struct {
        pub const configure = 0;
    };
    pub fn get_toplevel(writer: *Writer, xdg_surface_id: object, toplevel_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(xdg_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(toplevel_id), native_endian);
    }
    pub fn ack_configure(writer: *Writer, xdg_surface_id: object, serial: u32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(xdg_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 4 }), native_endian);
        try writer.writeInt(u32, serial, native_endian);
    }
};

pub const xdg_toplevel = struct {
    pub const event = struct {
        pub const configure = 0;
        pub const close = 1;
        pub const configure_bounds = 2;
        pub const wm_capabilities = 3;
    };
    pub fn set_fullscreen(writer: *Writer, toplevel_id: object, output_id: ?object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(toplevel_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 11 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(output_id orelse .null), native_endian);
    }
    pub fn set_title(writer: *Writer, toplevel_id: object, title: []const u8) error{WriteFailed}!void {
        const str_len: u32 = @intCast(title.len + 1); // includes null terminator
        const padded_str_len = std.mem.alignForward(u32, str_len, 4);
        const msg_len: u32 = 8 + 4 + padded_str_len;
        try writer.writeInt(u32, @intFromEnum(toplevel_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = @intCast(msg_len), .opcode = 2 }), native_endian);
        try writer.writeInt(u32, str_len, native_endian);
        try writer.writeAll(title);
        const padding = padded_str_len - @as(u32, @intCast(title.len));
        try writer.writeAll(("\x00\x00\x00\x00")[0..padding]);
    }
};

pub const surface = struct {
    // destroy 0
    pub fn attach(
        writer: *Writer,
        surface_id: object,
        buffer_id: object,
        x: i32,
        y: i32,
    ) error{WriteFailed}!void {
        const msg_len: u16 = 20;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(buffer_id), native_endian);
        try writer.writeInt(i32, x, native_endian);
        try writer.writeInt(i32, y, native_endian);
    }
    pub fn damage(
        writer: *Writer,
        surface_id: object,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) error{WriteFailed}!void {
        const msg_len: u16 = 24;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 2 }), native_endian);
        try writer.writeInt(i32, x, native_endian);
        try writer.writeInt(i32, y, native_endian);
        try writer.writeInt(i32, width, native_endian);
        try writer.writeInt(i32, height, native_endian);
    }
    pub fn frame(writer: *Writer, surface_id: object, callback_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 3 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(callback_id), native_endian);
    }
    pub fn set_opaque_region(writer: *Writer, surface_id: object, region_id: ?object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 4 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(region_id orelse .null), native_endian);
    }
    pub fn set_input_region(writer: *Writer, surface_id: object, region_id: ?object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 5 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(region_id orelse .null), native_endian);
    }
    pub fn commit(writer: *Writer, surface_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 6 }), native_endian);
    }
    // set_buffer_transform opcode 7
    pub fn set_buffer_scale(writer: *Writer, surface_id: object, scale: i32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 8 }), native_endian);
        try writer.writeInt(i32, scale, native_endian);
    }
    pub fn damage_buffer(
        writer: *Writer,
        surface_id: object,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) error{WriteFailed}!void {
        const msg_len: u16 = 24;
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 9 }), native_endian);
        try writer.writeInt(i32, x, native_endian);
        try writer.writeInt(i32, y, native_endian);
        try writer.writeInt(i32, width, native_endian);
        try writer.writeInt(i32, height, native_endian);
    }
};

pub const output = struct {
    pub const version = 4;
    pub const event = struct {
        pub const geometry = 0;
        pub const mode = 1;
        pub const done = 2;
        pub const scale = 3;
        pub const name = 4;
        pub const description = 5;
    };
};

pub const region = struct {
    pub fn destroy(writer: *Writer, region_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(region_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
};

pub const linux_dmabuf = struct {
    pub const version = 4;
    pub const event = struct {
        pub const format = 0;
        pub const modifier = 3;
    };
    pub fn destroy(writer: *Writer, dmabuf_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(dmabuf_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
    pub fn create_params(writer: *Writer, dmabuf_id: object, params_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(dmabuf_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(params_id), native_endian);
    }
};

pub const linux_dmabuf_params = struct {
    pub const event = struct {
        pub const created = 0;
        pub const failed = 1;
    };
    pub fn destroy(writer: *Writer, params_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(params_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
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
        // fd placeholder (sent via SCM_RIGHTS, but we still need to account for the arg in the message)
        std.mem.writeInt(u32, request[8..12], plane_idx, native_endian);
        std.mem.writeInt(u32, request[12..16], offset, native_endian);
        std.mem.writeInt(u32, request[16..20], stride, native_endian);
        std.mem.writeInt(u32, request[20..24], modifier_hi, native_endian);
        std.mem.writeInt(u32, request[24..28], modifier_lo, native_endian);
        // pad to 32 bytes
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
    pub fn create_immed(
        writer: *Writer,
        params_id: object,
        buffer_id: object,
        width: i32,
        height: i32,
        format: u32,
        flags: u32,
    ) error{WriteFailed}!void {
        const msg_len: u16 = 28;
        try writer.writeInt(u32, @intFromEnum(params_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 3 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(buffer_id), native_endian);
        try writer.writeInt(i32, width, native_endian);
        try writer.writeInt(i32, height, native_endian);
        try writer.writeInt(u32, format, native_endian);
        try writer.writeInt(u32, flags, native_endian);
    }
};

pub const xdg_decoration_manager = struct {
    pub const version = 1;
    pub fn destroy(writer: *Writer, manager_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(manager_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
    pub fn get_toplevel_decoration(writer: *Writer, manager_id: object, decoration_id: object, toplevel_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(manager_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(decoration_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(toplevel_id), native_endian);
    }
};

pub const xdg_toplevel_decoration = struct {
    pub const event = struct {
        pub const configure = 0;
    };
    pub const Mode = enum(u32) {
        client_side = 1,
        server_side = 2,
    };
    pub fn destroy(writer: *Writer, decoration_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(decoration_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
    pub fn set_mode(writer: *Writer, decoration_id: object, mode: Mode) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(decoration_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(mode), native_endian);
    }
    pub fn unset_mode(writer: *Writer, decoration_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(decoration_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 2 }), native_endian);
    }
};

pub const wl_buffer = struct {
    pub const event = struct {
        pub const release = 0;
    };
    pub fn destroy(writer: *Writer, buffer_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 8;
        try writer.writeInt(u32, @intFromEnum(buffer_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
    }
};

pub const layer_shell = struct {
    pub const version = 4;
    pub const Layer = enum(u32) {
        background = 0,
        bottom = 1,
        top = 2,
        overlay = 3,
    };
    pub fn get_layer_surface(
        writer: *Writer,
        shell_id: object,
        layer_surface_id: object,
        surface_id: object,
        output_id: ?object,
        layer: Layer,
        namespace: []const u8,
    ) error{WriteFailed}!void {
        const str_len: u32 = @intCast(namespace.len + 1);
        const padded_str_len = std.mem.alignForward(u32, str_len, 4);
        const msg_len: u32 = 8 + 4 + 4 + 4 + 4 + 4 + padded_str_len;
        try writer.writeInt(u32, @intFromEnum(shell_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = @intCast(msg_len), .opcode = 0 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(output_id orelse .null), native_endian);
        try writer.writeInt(u32, @intFromEnum(layer), native_endian);
        try writer.writeInt(u32, str_len, native_endian);
        try writer.writeAll(namespace);
        const padding = padded_str_len - @as(u32, @intCast(namespace.len));
        try writer.writeAll(("\x00\x00\x00\x00")[0..padding]);
    }
};

pub const layer_surface = struct {
    pub const event = struct {
        pub const configure = 0;
        pub const closed = 1;
    };
    pub fn set_size(writer: *Writer, layer_surface_id: object, width: u32, height: u32) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 0 }), native_endian);
        try writer.writeInt(u32, width, native_endian);
        try writer.writeInt(u32, height, native_endian);
    }
    pub fn set_anchor(writer: *Writer, layer_surface_id: object, anchor: u32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, anchor, native_endian);
    }
    pub fn set_exclusive_zone(writer: *Writer, layer_surface_id: object, zone: i32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 2 }), native_endian);
        try writer.writeInt(i32, zone, native_endian);
    }
    pub fn set_keyboard_interactivity(writer: *Writer, layer_surface_id: object, interactivity: u32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 4 }), native_endian);
        try writer.writeInt(u32, interactivity, native_endian);
    }
    pub fn ack_configure(writer: *Writer, layer_surface_id: object, serial: u32) error{WriteFailed}!void {
        const msg_len: u16 = 12;
        try writer.writeInt(u32, @intFromEnum(layer_surface_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 6 }), native_endian);
        try writer.writeInt(u32, serial, native_endian);
    }
};

pub const viewporter = struct {
    pub const version = 1;
    // destroy opcode 0
    pub fn get_viewport(writer: *Writer, viewporter_id: object, viewport_id: object, surface_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(viewporter_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(viewport_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
    }
};

pub const viewport = struct {
    // destroy opcode 0
    // set_source opcode 1 (fixed-point, not needed for now)
    pub fn set_destination(writer: *Writer, viewport_id: object, width: i32, height: i32) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(viewport_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 2 }), native_endian);
        try writer.writeInt(i32, width, native_endian);
        try writer.writeInt(i32, height, native_endian);
    }
};

pub const fractional_scale_manager = struct {
    pub const version = 1;
    // destroy opcode 0
    pub fn get_fractional_scale(writer: *Writer, manager_id: object, fractional_scale_id: object, surface_id: object) error{WriteFailed}!void {
        const msg_len: u16 = 16;
        try writer.writeInt(u32, @intFromEnum(manager_id), native_endian);
        try writer.writeInt(u32, @bitCast(SizeOpcode{ .size = msg_len, .opcode = 1 }), native_endian);
        try writer.writeInt(u32, @intFromEnum(fractional_scale_id), native_endian);
        try writer.writeInt(u32, @intFromEnum(surface_id), native_endian);
    }
};

pub const fractional_scale = struct {
    pub const event = struct {
        pub const preferred_scale = 0; // uint32: scale * 120
    };
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
    // Object IDs range from 1..capacity, with 0 meaning "not allocated".
    const ObjId = std.math.IntFittingRange(0, capacity);
    const Count = std.math.IntFittingRange(0, capacity);

    const count_before_display = @intFromEnum(IdEnum.display);
    const count_after_display = capacity - 1 - @intFromEnum(IdEnum.display);

    return struct {
        /// Maps enum to wayland object ID. 0 means not allocated.
        enum_to_obj: [capacity]ObjId = ([1]ObjId{0} ** count_before_display) ++
            [1]ObjId{1} ++
            ([1]ObjId{0} ** count_after_display),
        /// Maps (object_id - 1) -> enum variant.
        obj_to_enum: [capacity]IdEnum = [1]IdEnum{.display} ++ ([1]IdEnum{undefined} ** (capacity - 1)),
        /// The next object ID to hand out.
        next_id: Count = 2, // 1 is already taken by display

        const Self = @This();

        /// Allocate a new wayland object ID for the given id enum value.
        pub fn new(table: *Self, id: IdEnum) object {
            std.debug.assert(table.enum_to_obj[@intFromEnum(id)] == 0);
            std.debug.assert(table.next_id <= capacity);

            const obj_id = table.next_id;
            table.enum_to_obj[@intFromEnum(id)] = obj_id;
            table.obj_to_enum[obj_id - 1] = id;
            table.next_id += 1;
            return @enumFromInt(obj_id);
        }

        /// Get the wayland object ID for an already-allocated enum variant.
        pub fn get(table: *const Self, id: IdEnum) object {
            const obj_id = table.enum_to_obj[@intFromEnum(id)];
            std.debug.assert(obj_id != 0);
            return @enumFromInt(obj_id);
        }

        /// Look up which enum variant a received wayland object ID corresponds to.
        pub fn lookup(table: *const Self, o: object) IdEnum {
            const raw = @intFromEnum(o);
            std.debug.assert(raw >= 1 and raw < table.next_id);
            return table.obj_to_enum[raw - 1];
        }
    };
}

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
