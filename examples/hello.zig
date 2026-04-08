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

const Ids = wl.Ids(&.{
    .{ .display, .wl_display },
    .{ .registry, .wl_registry },
    .{ .sync_callback, .wl_callback },
    .{ .compositor, .wl_compositor },
    .{ .shm, .wl_shm },
    .{ .xdg_wm_base, .xdg_wm_base },
    .{ .surface, .wl_surface },
    .{ .xdg_surface, .xdg_surface },
    .{ .xdg_toplevel, .xdg_toplevel },
    .{ .shm_pool, .wl_shm_pool },
    .{ .buffer, .wl_buffer },
    .{ .frame_callback, .wl_callback },
});

fn go(
    stream: std.net.Stream,
    writer: *wl.Writer,
    reader: *wl.Reader,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    var ids_store: Ids.Store = .{};
    var ids = Ids.init(&ids_store);

    var id_recycle_stack: [16]wl.object = undefined;
    var id_pool: wl.IdPool = .{ .next = 1, .recycle_stack = &id_recycle_stack };
    _ = ids.new(&id_pool, .display);

    try wl.display.get_registry(writer, ids.new(&id_pool, .registry));
    try wl.display.sync(writer, ids.new(&id_pool, .sync_callback));
    try writer.flush();

    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;

    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        const result = ids.lookup(sender);
        std.debug.assert(!result.dying);
        switch (result.kind) {
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
                        maybe_shm = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.compositor.name)) {
                        maybe_compositor = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.xdg_wm_base.name)) {
                        maybe_xdg_wm_base = .{ .name = name, .version = version };
                    }
                },
                else => @panic("unhandled registry event"),
            },
            .sync_callback => switch (opcode) {
                wl.callback.event.done => {
                    if (size != 12) return error.WaylandProtocol;
                    const timestamp = try reader.takeInt(u32, wl.native_endian);
                    _ = timestamp;
                    ids.remove(.sync_callback);
                    break;
                },
                else => @panic("unhandled callback opcode"),
            },
            .display => try handleDisplayEvent(&id_pool, &ids, reader, opcode, size),
            else => |k| std.debug.panic("unexpected event from {s} during handshake", .{@tagName(k)}),
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
        ids.new(&id_pool, .compositor),
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
        ids.new(&id_pool, .shm),
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
        ids.new(&id_pool, .xdg_wm_base),
    );

    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(&id_pool, .surface));
    try wl.xdg_wm_base.get_xdg_surface(writer, ids.get(.xdg_wm_base), ids.new(&id_pool, .xdg_surface), ids.get(.surface));
    try wl.xdg_surface.get_toplevel(writer, ids.get(.xdg_surface), ids.new(&id_pool, .xdg_toplevel));
    try wl.xdg_toplevel.set_title(writer, ids.get(.xdg_toplevel), "hello animation");

    // Initial empty commit to get the configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for the initial xdg configure sequence
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (try handleEvent(&ids, &id_pool, writer, reader, sender, opcode, size, &configured)) {
            .open => {},
            .closed => return,
        }
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
        std.log.err("ftruncate failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    const pixels = std.posix.mmap(null, shm_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e| {
        std.log.err("mmap failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    const pixels_u32: [*]u32 = @ptrCast(@alignCast(pixels.ptr));

    try writer.flush();
    wl.shm.create_pool(stream, ids.get(.shm), ids.new(&id_pool, .shm_pool), shm_fd, @intCast(shm_size)) catch |e| {
        std.log.err("sendmsg with shm fd failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };

    try wl.shm_pool.create_buffer(
        writer,
        ids.get(.shm_pool),
        ids.new(&id_pool, .buffer),
        0,
        width,
        height,
        stride,
        .argb8888,
    );
    try wl.shm_pool.destroy(writer, ids.get(.shm_pool));
    ids.destroy(.shm_pool);

    // Animation loop: draw, attach, request frame callback, commit
    var frame: u32 = 0;
    var running = true;
    while (running) {
        // Draw a shifting gradient
        for (0..height) |y| {
            for (0..width) |x| {
                const r: u8 = @truncate((x +% frame) * 255 / width);
                const g: u8 = @truncate((y +% frame * 2) * 255 / height);
                const b: u8 = @truncate(255 -% (x +% y +% frame * 3) * 255 / (width + height));
                pixels_u32[y * width + x] = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
            }
        }

        try wl.surface.attach(writer, ids.get(.surface), ids.get(.buffer), 0, 0);
        try wl.surface.damage(writer, ids.get(.surface), 0, 0, width, height);

        // Request frame callback — dynamic object, created/destroyed each frame
        try wl.surface.frame(writer, ids.get(.surface), ids.new(&id_pool, .frame_callback));
        try wl.surface.commit(writer, ids.get(.surface));
        try writer.flush();

        // Wait for frame callback done
        var frame_done = false;
        while (!frame_done) {
            var poll_fd = [1]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const poll_result = std.posix.poll(&poll_fd, 5000) catch |e| {
                std.log.err("poll failed with {s}", .{@errorName(e)});
                std.process.exit(0xff);
            };
            if (poll_result == 0) {
                std.log.info("timeout after {} frames, exiting", .{frame});
                return;
            }
            const sender, const opcode, const size = try wl.readHeader(reader);
            const result = ids.lookup(sender);
            if (result.dying) {
                const body_size = size -| 8;
                if (body_size > 0) try reader.discardAll(body_size);
                continue;
            }
            switch (result.kind) {
                .frame_callback => {
                    const timestamp = try reader.takeInt(u32, wl.native_endian);
                    _ = timestamp;
                    ids.remove(.frame_callback);
                    frame_done = true;
                },
                else => switch (try handleEvent(&ids, &id_pool, writer, reader, sender, opcode, size, null)) {
                    .open => {},
                    .closed => {
                        running = false;
                        frame_done = true;
                    },
                },
            }
        }
        frame +%= 1;
    }
}

fn handleDisplayEvent(
    id_pool: *wl.IdPool,
    ids: *Ids,
    reader: *wl.Reader,
    opcode: u16,
    size: u16,
) error{ ReadFailed, EndOfStream, WaylandProtocol }!void {
    switch (opcode) {
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
            const deleted_id: wl.object = @enumFromInt(try reader.takeInt(u32, wl.native_endian));
            ids.delete(id_pool, deleted_id);
        },
        else => {
            const body_size = size -| 8;
            if (body_size > 0) try reader.discardAll(body_size);
        },
    }
}

fn handleEvent(
    ids: *Ids,
    id_pool: *wl.IdPool,
    writer: *wl.Writer,
    reader: *wl.Reader,
    sender: wl.object,
    opcode: u16,
    size: u16,
    configured: ?*bool,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!enum { open, closed } {
    const result = ids.lookup(sender);
    if (result.dying) {
        const body_size = size -| 8;
        if (body_size > 0) try reader.discardAll(body_size);
        return .open;
    }
    switch (result.kind) {
        .display => try handleDisplayEvent(id_pool, ids, reader, opcode, size),
        .shm => switch (opcode) {
            wl.shm.event.format => {
                _ = try reader.takeInt(u32, wl.native_endian);
            },
            else => std.debug.panic("unhandled shm event opcode={}", .{opcode}),
        },
        .xdg_wm_base => switch (opcode) {
            wl.xdg_wm_base.event.ping => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                try wl.xdg_wm_base.pong(writer, ids.get(.xdg_wm_base), serial);
            },
            else => std.debug.panic("unhandled xdg_wm_base event opcode={}", .{opcode}),
        },
        .xdg_surface => switch (opcode) {
            wl.xdg_surface.event.configure => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                try wl.xdg_surface.ack_configure(writer, ids.get(.xdg_surface), serial);
                if (configured) |c| c.* = true;
            },
            else => std.debug.panic("unhandled xdg_surface event opcode={}", .{opcode}),
        },
        .xdg_toplevel => switch (opcode) {
            wl.xdg_toplevel.event.configure => {
                _ = try reader.takeInt(i32, wl.native_endian);
                _ = try reader.takeInt(i32, wl.native_endian);
                const states_len = try reader.takeInt(u32, wl.native_endian);
                try reader.discardAll(@divTrunc(states_len + 3, 4) * 4);
            },
            wl.xdg_toplevel.event.close => {
                std.log.info("xdg_toplevel close", .{});
                return .closed;
            },
            wl.xdg_toplevel.event.configure_bounds => {
                _ = try reader.takeInt(i32, wl.native_endian);
                _ = try reader.takeInt(i32, wl.native_endian);
            },
            wl.xdg_toplevel.event.wm_capabilities => {
                const caps_len = try reader.takeInt(u32, wl.native_endian);
                try reader.discardAll(@divTrunc(caps_len + 3, 4) * 4);
            },
            else => std.debug.panic("unhandled xdg_toplevel event opcode={}", .{opcode}),
        },
        .surface => {
            const body_size = size -| 8;
            if (body_size > 0) try reader.discardAll(body_size);
        },
        .buffer => {
            // buffer release — nothing to do
        },
        .frame_callback => {
            _ = try reader.takeInt(u32, wl.native_endian);
        },
        .registry, .sync_callback, .shm_pool, .compositor => {
            const body_size = size -| 8;
            if (body_size > 0) try reader.discardAll(body_size);
        },
    }
    return .open;
}

const std = @import("std");
const wl = @import("wl");
