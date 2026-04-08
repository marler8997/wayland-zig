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

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(&read_buf);

    var inst_store: Instance.Store = .{};
    var id_recycle_stack: [16]wl.object = undefined;
    var id_pool: wl.IdPool = .{ .next = 1, .recycle_stack = &id_recycle_stack };
    var zombie_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var inst = Instance.init(&stream_writer.interface, &inst_store, &id_pool, .{
        .zombies = .{ .allocator = zombie_arena.allocator() },
    });

    return go(stream, &inst, stream_reader.interface()) catch |err| switch (err) {
        error.WriteFailed => stream_writer.err orelse error.Unexpected,
        error.ReadFailed => stream_reader.getError() orelse error.Unexpected,
        error.EndOfStream,
        error.WaylandProtocol,
        => |e| e,
    };
}

const Instance = @import("wl").Instance(&.{
    .{ "display", .wl_display },
    .{ "registry", .wl_registry },
    .{ "sync_callback", .wl_callback },
    .{ "compositor", .wl_compositor },
    .{ "shm", .wl_shm },
    .{ "xdg_wm_base", .xdg_wm_base },
    .{ "surface", .wl_surface },
    .{ "xdg_surface", .xdg_surface },
    .{ "xdg_toplevel", .xdg_toplevel },
    .{ "shm_pool", .wl_shm_pool },
    .{ "buffer", .wl_buffer },
    .{ "frame_callback", .wl_callback },
});

fn go(
    stream: std.net.Stream,
    inst: *Instance,
    reader: *wl.Reader,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    _ = inst.new(.display);

    try inst.write(.display, .get_registry, .{inst.new(.registry)});
    try inst.write(.display, .sync, .{inst.new(.sync_callback)});
    try inst.writer.flush();

    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;

    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        const result = inst.lookup(sender) orelse {
            try reader.discardAll(size -| 8);
            continue;
        };
        switch (result) {
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
                    inst.remove(.sync_callback);
                    break;
                },
                else => @panic("unhandled callback opcode"),
            },
            .display => try handleDisplayEvent(inst, reader, opcode, size),
            else => |k| std.debug.panic("unexpected event from {s} during handshake", .{@tagName(k)}),
        }
    }
    const compositor_global = maybe_compositor orelse {
        std.log.err("no wl_compositor object", .{});
        std.process.exit(0xff);
    };
    try inst.write(.registry, .bind, .{
        compositor_global.name,
        wl.compositor.name,
        @min(wl.compositor.version, compositor_global.version),
        inst.new(.compositor),
    });

    const shm_global = maybe_shm orelse {
        std.log.err("no wl_shm object", .{});
        std.process.exit(0xff);
    };
    try inst.write(.registry, .bind, .{
        shm_global.name,
        wl.shm.name,
        @min(wl.shm.version, shm_global.version),
        inst.new(.shm),
    });

    const xdg_wm_base_global = maybe_xdg_wm_base orelse {
        std.log.err("no xdg_wm_base object", .{});
        std.process.exit(0xff);
    };
    try inst.write(.registry, .bind, .{
        xdg_wm_base_global.name,
        wl.xdg_wm_base.name,
        @min(wl.xdg_wm_base.version, xdg_wm_base_global.version),
        inst.new(.xdg_wm_base),
    });

    try inst.write(.compositor, .create_surface, .{inst.new(.surface)});
    try inst.write(.xdg_wm_base, .get_xdg_surface, .{ inst.new(.xdg_surface), inst.get(.surface) });
    try inst.write(.xdg_surface, .get_toplevel, .{inst.new(.xdg_toplevel)});
    try inst.write(.xdg_toplevel, .set_title, .{"hello animation"});

    // Initial empty commit to get the configure event
    try inst.write(.surface, .commit, .{});
    try inst.writer.flush();

    // Wait for the initial xdg configure sequence
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (try handleEvent(inst, reader, sender, opcode, size, &configured)) {
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

    try inst.writer.flush();
    wl.shm.create_pool(stream, inst.get(.shm), inst.new(.shm_pool), shm_fd, @intCast(shm_size)) catch |e| {
        std.log.err("sendmsg with shm fd failed with {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };

    try inst.write(.shm_pool, .create_buffer, .{
        inst.new(.buffer),
        0,
        width,
        height,
        stride,
        .argb8888,
    });
    try inst.write(.shm_pool, .destroy, .{});

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

        try inst.write(.surface, .attach, .{ inst.get(.buffer), 0, 0 });
        try inst.write(.surface, .damage, .{ 0, 0, width, height });

        // Request frame callback - dynamic object, created/destroyed each frame
        try inst.write(.surface, .frame, .{inst.new(.frame_callback)});
        try inst.write(.surface, .commit, .{});
        try inst.writer.flush();

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
            const result = inst.lookup(sender) orelse {
                try reader.discardAll(size -| 8);
                continue;
            };
            switch (result) {
                .frame_callback => {
                    const timestamp = try reader.takeInt(u32, wl.native_endian);
                    _ = timestamp;
                    inst.remove(.frame_callback);
                    frame_done = true;
                },
                else => switch (try handleEvent(inst, reader, sender, opcode, size, null)) {
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
    inst: *Instance,
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
            inst.delete(deleted_id);
        },
        else => {
            const body_size = size -| 8;
            if (body_size > 0) try reader.discardAll(body_size);
        },
    }
}

fn handleEvent(
    inst: *Instance,
    reader: *wl.Reader,
    sender: wl.object,
    opcode: u16,
    size: u16,
    configured: ?*bool,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!enum { open, closed } {
    const result = inst.lookup(sender) orelse {
        try reader.discardAll(size -| 8);
        return .open;
    };
    switch (result) {
        .display => try handleDisplayEvent(inst, reader, opcode, size),
        .shm => switch (opcode) {
            wl.shm.event.format => {
                _ = try reader.takeInt(u32, wl.native_endian);
            },
            else => std.debug.panic("unhandled shm event opcode={}", .{opcode}),
        },
        .xdg_wm_base => switch (opcode) {
            wl.xdg_wm_base.event.ping => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                try inst.write(.xdg_wm_base, .pong, .{serial});
            },
            else => std.debug.panic("unhandled xdg_wm_base event opcode={}", .{opcode}),
        },
        .xdg_surface => switch (opcode) {
            wl.xdg_surface.event.configure => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                try inst.write(.xdg_surface, .ack_configure, .{serial});
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
