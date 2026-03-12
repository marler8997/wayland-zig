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
    layer_shell,
    surface,
    layer_surface,
    wl_region,
    shm_pool,
    buffer,
    frame_callback,
};

fn go(
    stream: std.net.Stream,
    writer: *wl.Writer,
    reader: *wl.Reader,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    var ids: wl.IdTable(Id) = .{};

    try wl.display.get_registry(writer, ids.new(.registry));
    try wl.display.sync(writer, ids.new(.callback));
    try writer.flush();

    var maybe_shm_name: ?u32 = null;
    var maybe_compositor_name: ?u32 = null;
    var maybe_layer_shell_name: ?u32 = null;

    // Read registry globals until sync callback
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
                    std.log.info("registry: name={} interface='{s}' version={}", .{ name, interface, version });
                    if (std.mem.eql(u8, interface, wl.shm.name)) {
                        maybe_shm_name = name;
                    } else if (std.mem.eql(u8, interface, wl.compositor.name)) {
                        maybe_compositor_name = name;
                    } else if (std.mem.eql(u8, interface, wl.layer_shell.name)) {
                        maybe_layer_shell_name = name;
                    }
                },
                else => @panic("unhandled registry event"),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    if (size != 12) return error.WaylandProtocol;
                    _ = try reader.takeInt(u32, wl.native_endian);
                    break;
                },
                else => @panic("unhandled callback event"),
            },
            else => |sender_id| std.debug.panic("unhandled event from {t}", .{sender_id}),
        }
    }

    const compositor_name = maybe_compositor_name orelse {
        std.log.err("no wl_compositor", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(writer, ids.get(.registry), compositor_name, wl.compositor.name, wl.compositor.version, ids.new(.compositor));

    const shm_name = maybe_shm_name orelse {
        std.log.err("no wl_shm", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(writer, ids.get(.registry), shm_name, wl.shm.name, wl.shm.version, ids.new(.shm));

    const layer_shell_name = maybe_layer_shell_name orelse {
        std.log.err("no zwlr_layer_shell_v1 — compositor does not support wlr-layer-shell", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(writer, ids.get(.registry), layer_shell_name, wl.layer_shell.name, wl.layer_shell.version, ids.new(.layer_shell));

    // Create surface
    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(.surface));

    // Create layer surface in overlay layer
    try wl.layer_shell.get_layer_surface(
        writer,
        ids.get(.layer_shell),
        ids.new(.layer_surface),
        ids.get(.surface),
        null, // output: compositor picks
        .overlay,
        "overlay-example",
    );

    // Configure: anchor all edges (fullscreen), exclusive_zone=-1, no keyboard
    try wl.layer_surface.set_anchor(writer, ids.get(.layer_surface), 15); // top|bottom|left|right
    try wl.layer_surface.set_size(writer, ids.get(.layer_surface), 0, 0); // compositor decides
    try wl.layer_surface.set_exclusive_zone(writer, ids.get(.layer_surface), -1);
    try wl.layer_surface.set_keyboard_interactivity(writer, ids.get(.layer_surface), .none);

    // Create empty region for input passthrough
    try wl.compositor.create_region(writer, ids.get(.compositor), ids.new(.wl_region));
    try wl.surface.set_input_region(writer, ids.get(.surface), ids.get(.wl_region));
    try wl.region.destroy(writer, ids.get(.wl_region));

    // Set opaque region to null (fully transparent)
    try wl.surface.set_opaque_region(writer, ids.get(.surface), null);

    // Initial commit to get configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for layer_surface configure
    var width: u32 = 0;
    var height: u32 = 0;
    while (width == 0 or height == 0) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .display => try handleDisplayEvent(reader, opcode),
            .shm => {
                // shm format event — just consume it
                if (opcode == wl.shm.event.format) {
                    _ = try reader.takeInt(u32, wl.native_endian);
                } else {
                    std.debug.panic("unhandled shm event opcode={}", .{opcode});
                }
            },
            .layer_surface => switch (opcode) {
                wl.layer_surface.event.configure => {
                    const serial = try reader.takeInt(u32, wl.native_endian);
                    width = try reader.takeInt(u32, wl.native_endian);
                    height = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("layer_surface configure: {}x{} serial={}", .{ width, height, serial });
                    try wl.layer_surface.ack_configure(writer, ids.get(.layer_surface), serial);
                },
                wl.layer_surface.event.closed => {
                    std.log.info("layer_surface closed", .{});
                    return;
                },
                else => std.debug.panic("unhandled layer_surface event opcode={}", .{opcode}),
            },
            else => {
                // Skip unknown events
                const payload_size = size - 8;
                try reader.discardAll(payload_size);
            },
        }
    }

    // Allocate shared memory buffer
    const stride: u32 = width * 4;
    const shm_size: u32 = stride * height;

    const shm_memfd_name = "overlay-shm";
    const shm_fd = std.posix.memfd_createZ(shm_memfd_name, 0) catch |e| {
        std.log.err("memfd_create failed: {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    std.posix.ftruncate(shm_fd, shm_size) catch |e| {
        std.log.err("ftruncate failed: {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    const pixels = std.posix.mmap(null, shm_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e| {
        std.log.err("mmap failed: {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };
    const pixel_data: [*]u32 = @ptrCast(@alignCast(pixels.ptr));

    try writer.flush();
    wl.shm.create_pool(stream, ids.get(.shm), ids.new(.shm_pool), shm_fd, shm_size) catch |e| {
        std.log.err("create_pool failed: {s}", .{@errorName(e)});
        std.process.exit(0xff);
    };

    try wl.shm_pool.create_buffer(
        writer,
        ids.get(.shm_pool),
        ids.new(.buffer),
        0,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        .argb8888,
    );
    try wl.shm_pool.destroy(writer, ids.get(.shm_pool));

    // Animation loop
    var frame_count: u32 = 0;
    while (true) {
        // Clear buffer to transparent
        const pixel_count = width * height;
        for (0..pixel_count) |i| {
            pixel_data[i] = 0x00000000;
        }

        // Draw a spinning line from center
        drawSpinningLine(pixel_data, width, height, frame_count);

        // Draw a pulsing circle
        drawPulsingCircle(pixel_data, width, height, frame_count);

        // Attach, damage, request frame, commit
        try wl.surface.attach(writer, ids.get(.surface), ids.get(.buffer), 0, 0);
        try wl.surface.damage_buffer(writer, ids.get(.surface), 0, 0, @intCast(width), @intCast(height));
        try wl.surface.frame(writer, ids.get(.surface), ids.get(.frame_callback));
        try wl.surface.commit(writer, ids.get(.surface));
        try writer.flush();

        // Wait for frame callback
        var got_frame = false;
        while (!got_frame) {
            const sender, const opcode, const size = try wl.readHeader(reader);
            switch (ids.lookup(sender)) {
                .display => try handleDisplayEvent(reader, opcode),
                .shm => {
                    if (opcode == wl.shm.event.format) {
                        _ = try reader.takeInt(u32, wl.native_endian);
                    } else {
                        std.debug.panic("unhandled shm event opcode={}", .{opcode});
                    }
                },
                .frame_callback => switch (opcode) {
                    wl.callback.event.done => {
                        _ = try reader.takeInt(u32, wl.native_endian); // timestamp
                        got_frame = true;
                    },
                    else => @panic("unhandled frame callback event"),
                },
                .layer_surface => switch (opcode) {
                    wl.layer_surface.event.configure => {
                        const serial = try reader.takeInt(u32, wl.native_endian);
                        _ = try reader.takeInt(u32, wl.native_endian); // new width
                        _ = try reader.takeInt(u32, wl.native_endian); // new height
                        try wl.layer_surface.ack_configure(writer, ids.get(.layer_surface), serial);
                    },
                    wl.layer_surface.event.closed => {
                        std.log.info("layer_surface closed", .{});
                        return;
                    },
                    else => std.debug.panic("unhandled layer_surface event opcode={}", .{opcode}),
                },
                .buffer => {
                    // wl_buffer.release — ignore
                    const payload_size = size - 8;
                    try reader.discardAll(payload_size);
                },
                else => {
                    const payload_size = size - 8;
                    try reader.discardAll(payload_size);
                },
            }
        }

        frame_count +%= 1;
    }
}

fn handleDisplayEvent(
    reader: *wl.Reader,
    opcode: u16,
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
            _ = try reader.takeInt(u32, wl.native_endian);
        },
        else => std.debug.panic("unhandled display event opcode={}", .{opcode}),
    }
}

fn drawSpinningLine(pixel_data: [*]u32, width: u32, height: u32, frame: u32) void {
    const cx: f32 = @as(f32, @floatFromInt(width)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(height)) / 2.0;
    const radius: f32 = @min(cx, cy) * 0.8;
    const angle: f32 = @as(f32, @floatFromInt(frame % 360)) * std.math.pi / 180.0;

    const ex: f32 = cx + radius * @cos(angle);
    const ey: f32 = cy + radius * @sin(angle);

    // Bresenham-style line from (cx, cy) to (ex, ey)
    const steps: u32 = @intFromFloat(radius * 2.0);
    for (0..steps) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const px: i32 = @intFromFloat(cx + (ex - cx) * t);
        const py: i32 = @intFromFloat(cy + (ey - cy) * t);
        if (px >= 0 and py >= 0 and px < @as(i32, @intCast(width)) and py < @as(i32, @intCast(height))) {
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            // Draw a 3px thick line
            for (0..3) |dy| {
                for (0..3) |dx| {
                    const fx: u32 = ux +| @as(u32, @intCast(dx)) -| 1;
                    const fy: u32 = uy +| @as(u32, @intCast(dy)) -| 1;
                    if (fx < width and fy < height) {
                        pixel_data[fy * width + fx] = 0xFFFF0000; // red
                    }
                }
            }
        }
    }
}

fn drawPulsingCircle(pixel_data: [*]u32, width: u32, height: u32, frame: u32) void {
    const cx: f32 = @as(f32, @floatFromInt(width)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(height)) / 2.0;
    const base_radius: f32 = @min(cx, cy) * 0.3;
    const pulse: f32 = @sin(@as(f32, @floatFromInt(frame % 120)) * std.math.pi * 2.0 / 120.0);
    const radius: f32 = base_radius + pulse * base_radius * 0.3;
    const r_sq: f32 = radius * radius;
    const inner_r_sq: f32 = (radius - 3.0) * (radius - 3.0);

    const min_y: u32 = @intFromFloat(@max(0.0, cy - radius - 1.0));
    const max_y: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(height)), cy + radius + 1.0));
    const min_x: u32 = @intFromFloat(@max(0.0, cx - radius - 1.0));
    const max_x: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(width)), cx + radius + 1.0));

    for (min_y..max_y) |y| {
        const dy: f32 = @as(f32, @floatFromInt(y)) - cy;
        for (min_x..max_x) |x| {
            const dx: f32 = @as(f32, @floatFromInt(x)) - cx;
            const dist_sq: f32 = dx * dx + dy * dy;
            if (dist_sq <= r_sq and dist_sq >= inner_r_sq) {
                pixel_data[y * width + x] = 0xCC00FF00; // semi-transparent green
            }
        }
    }
}

const std = @import("std");
const wl = @import("wl");
