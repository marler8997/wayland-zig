pub fn main() !void {
    try wl.wsaStartup();

    const stream = blk: {
        var err: wl.SockaddrError = undefined;
        const addr = wl.getSockaddr(&err) catch {
            std.log.err("{f}", .{err});
            std.process.exit(0xff);
        };
        std.log.info("connecting to '{f}'", .{addr});
        break :blk wl.connect(&addr) catch |e| {
            std.log.err("connect to {f} failed with {s}", .{ addr, @errorName(e) });
            std.process.exit(0xff);
        };
    };
    defer wl.disconnect(stream);

    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(&write_buf);
    const writer = &stream_writer.interface;

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(&read_buf);
    const reader = stream_reader.interface();

    return go(stream, writer, reader) catch |err| switch (err) {
        error.WriteFailed => stream_writer.err orelse error.Unexpected,
        error.ReadFailed => stream_reader.getError() orelse error.Unexpected,
        error.EndOfStream,
        error.WaylandProtocol,
        => |e| e,
    };
}

const Id = enum {
    display,
    registry,
    callback,
    compositor,
    shm,
    xdg_wm_base,
    surface,
    xdg_surface,
    xdg_toplevel,
    shm_pool,
    buffer,
};

fn go(
    stream: std.net.Stream,
    writer: *wl.Writer,
    reader: *wl.Reader,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    var ids: wl.IdTable(Id) = .{};
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // std.log.info("{}", .{ids});

    try wl.display.get_registry(writer, ids.new(.registry));
    try wl.display.sync(writer, ids.new(.callback));
    try writer.flush();

    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;

    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .registry => switch (opcode) {
                wl.registry.event.global => {
                    const name = try reader.takeInt(u32, wl.native_endian);
                    const interface_size = try reader.takeInt(u32, wl.native_endian);
                    const interface_word_count = @divTrunc(interface_size + 3, 4);
                    if (8 + 12 + interface_word_count * 4 != size) return error.WaylandProtocol;
                    var interface_buf: [400]u8 = undefined;
                    const interface = interface_buf[0..@min(interface_buf.len, interface_size -| 1)];
                    try reader.readSliceAll(interface);
                    try reader.discardAll(interface_word_count * 4 - interface.len);
                    const version = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("registry event global name={} interface='{s}' version={}", .{ name, interface, version });
                    if (std.mem.eql(u8, interface, wl.shm.name)) {
                        if (maybe_shm != null) {
                            std.log.err("got wl_shm multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_shm = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.compositor.name)) {
                        if (maybe_compositor != null) {
                            std.log.err("got wl_compositor multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_compositor = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.xdg_wm_base.name)) {
                        if (maybe_xdg_wm_base != null) {
                            std.log.err("got xdg_wm_base multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_xdg_wm_base = .{ .name = name, .version = version };
                    }
                },
                else => @panic("unhandled registry event"),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    if (size != 12) {
                        std.log.err("expected wl_callback.done event to be 12 bytes but got {}", .{size});
                        return error.WaylandProtocol;
                    }
                    const data: u32 = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("done data={}", .{data});
                    break;
                },
                else => @panic("unhandled opcode"),
            },
            else => |sender_id| std.debug.panic("unhandled event from {t}", .{sender_id}),
        }
    }

    const compositor_global = maybe_compositor orelse {
        std.log.err("no wl_compositor object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        compositor_global.name,
        wl.compositor.name,
        @min(wl.compositor.version, compositor_global.version),
        ids.new(.compositor),
    );

    const shm_global = maybe_shm orelse {
        std.log.err("no wl_shm object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        shm_global.name,
        wl.shm.name,
        @min(wl.shm.version, shm_global.version),
        ids.new(.shm),
    );

    const xdg_wm_base_global = maybe_xdg_wm_base orelse {
        std.log.err("no xdg_wm_base object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        xdg_wm_base_global.name,
        wl.xdg_wm_base.name,
        @min(wl.xdg_wm_base.version, xdg_wm_base_global.version),
        ids.new(.xdg_wm_base),
    );

    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(.surface));
    try wl.xdg_wm_base.get_xdg_surface(writer, ids.get(.xdg_wm_base), ids.new(.xdg_surface), ids.get(.surface));
    try wl.xdg_surface.get_toplevel(writer, ids.get(.xdg_surface), ids.new(.xdg_toplevel));
    try wl.xdg_toplevel.set_title(writer, ids.get(.xdg_toplevel), "hello");
    // Initial empty commit to get the configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for the initial xdg configure sequence
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        try handleEvent(&ids, writer, reader, ids.lookup(sender), opcode, size, &configured);
    }

    // Now we can set up the buffer and attach it
    const width = 640;
    const height = 480;
    const stride = width * 4;
    const shm_size = stride * height;

    const shm_memfd_name = "wayland-shm";
    const shm_fd = std.posix.memfd_createZ(shm_memfd_name, 0) catch |e| {
        std.log.err("memfd_create '{s}' failed with {s}", .{ shm_memfd_name, @errorName(e) });
        std.process.exit(0xff);
    };

    std.posix.ftruncate(shm_fd, shm_size) catch |e| {
        std.log.err("ftruncate {} failed with {s}", .{ shm_size, @errorName(e) });
        std.process.exit(0xff);
    };

    const pixels = std.posix.mmap(null, shm_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e| {
        std.log.err("mmap shm failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    const pixels_u32: [*]u32 = @ptrCast(@alignCast(pixels.ptr));
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @truncate(x * 255 / width);
            const g: u8 = @truncate(y * 255 / height);
            const b: u8 = @truncate(255 - (x + y) * 255 / (width + height));
            pixels_u32[y * width + x] = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        }
    }

    try writer.flush();
    wl.shm.create_pool(stream, ids.get(.shm), ids.new(.shm_pool), shm_fd, @intCast(shm_size)) catch |e| {
        std.log.err("sendmsg with shm fd failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };

    try wl.shm_pool.create_buffer(
        writer,
        ids.get(.shm_pool),
        ids.new(.buffer),
        0, // offset
        width,
        height,
        stride,
        .argb8888,
    );
    try wl.shm_pool.destroy(writer, ids.get(.shm_pool));
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: how do we invalidate an id?
    try wl.surface.attach(writer, ids.get(.surface), ids.get(.buffer), 0, 0);
    try wl.surface.damage(writer, ids.get(.surface), 0, 0, width, height);
    try wl.surface.commit(writer, ids.get(.surface));

    // Main event loop with 2 second timeout
    while (true) {
        try writer.flush();
        var poll_fd = [1]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const poll_result = std.posix.poll(&poll_fd, 2000) catch |e| {
            std.log.err("poll failed with {s}", .{@errorName(e)});
            std.process.exit(0xff);
        };
        if (poll_result == 0) {
            std.log.info("timeout, exiting", .{});
            return;
        }
        const sender, const opcode, const size = try wl.readHeader(reader);
        try handleEvent(&ids, writer, reader, ids.lookup(sender), opcode, size, null);
    }
}

fn handleEvent(
    ids: *const wl.IdTable(Id),
    writer: *wl.Writer,
    reader: *wl.Reader,
    sender: Id,
    opcode: u16,
    size: u16,
    configured: ?*bool,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    switch (sender) {
        .display => switch (opcode) {
            wl.display.event.@"error" => {
                const object_id = try reader.takeInt(u32, wl.native_endian);
                const code = try reader.takeInt(u32, wl.native_endian);
                const msg_size = try reader.takeInt(u32, wl.native_endian);
                const msg_word_count = @divTrunc(msg_size + 3, 4);
                var msg_buf: [400]u8 = undefined;
                const msg = msg_buf[0..@min(msg_buf.len, msg_size -| 1)];
                try reader.readSliceAll(msg);
                try reader.discardAll(msg_word_count * 4 - msg.len);
                std.log.err("display error: object={} code={} message='{s}'", .{ object_id, code, msg });
                return error.WaylandProtocol;
            },
            wl.display.event.delete_id => {
                const deleted_id = try reader.takeInt(u32, wl.native_endian);
                std.log.info("delete_id {}", .{deleted_id});
            },
            else => std.debug.panic("unhandled display event opcode={}", .{opcode}),
        },
        .shm => switch (opcode) {
            wl.shm.event.format => {
                const format = try reader.takeInt(u32, wl.native_endian);
                std.log.info("shm format {}", .{format});
            },
            else => std.debug.panic("unhandled shm event opcode={}", .{opcode}),
        },
        .xdg_wm_base => switch (opcode) {
            wl.xdg_wm_base.event.ping => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                std.log.info("ping serial={}", .{serial});
                try wl.xdg_wm_base.pong(writer, ids.get(.xdg_wm_base), serial);
            },
            else => std.debug.panic("unhandled xdg_wm_base event opcode={}", .{opcode}),
        },
        .xdg_surface => switch (opcode) {
            wl.xdg_surface.event.configure => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                std.log.info("xdg_surface configure serial={}", .{serial});
                try wl.xdg_surface.ack_configure(writer, ids.get(.xdg_surface), serial);
                if (configured) |c| c.* = true;
            },
            else => std.debug.panic("unhandled xdg_surface event opcode={}", .{opcode}),
        },
        .xdg_toplevel => switch (opcode) {
            wl.xdg_toplevel.event.configure => {
                // width(int) + height(int) + states(array: len + data)
                const toplevel_width = try reader.takeInt(i32, wl.native_endian);
                const toplevel_height = try reader.takeInt(i32, wl.native_endian);
                const states_len = try reader.takeInt(u32, wl.native_endian);
                const states_word_count = @divTrunc(states_len + 3, 4);
                try reader.discardAll(states_word_count * 4);
                std.log.info("xdg_toplevel configure width={} height={}", .{ toplevel_width, toplevel_height });
            },
            wl.xdg_toplevel.event.close => {
                std.log.info("xdg_toplevel close", .{});
                std.process.exit(0);
            },
            wl.xdg_toplevel.event.configure_bounds => {
                // width(int) + height(int)
                const bounds_width = try reader.takeInt(i32, wl.native_endian);
                const bounds_height = try reader.takeInt(i32, wl.native_endian);
                std.log.info("xdg_toplevel configure_bounds width={} height={}", .{ bounds_width, bounds_height });
            },
            wl.xdg_toplevel.event.wm_capabilities => {
                // array: len + data
                const caps_len = try reader.takeInt(u32, wl.native_endian);
                const caps_word_count = @divTrunc(caps_len + 3, 4);
                try reader.discardAll(caps_word_count * 4);
                std.log.info("xdg_toplevel wm_capabilities", .{});
            },
            else => std.debug.panic("unhandled xdg_toplevel event opcode={}", .{opcode}),
        },
        .buffer => {
            // wl_buffer.release
            std.log.info("buffer release (size={})", .{size});
        },
        else => std.debug.panic(
            "unhandled event, sender={} opcode={} size={}",
            .{ @intFromEnum(sender), opcode, size },
        ),
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const wl = @import("wl");
