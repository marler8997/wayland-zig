pub const IdMap = @import("IdMap.zig");

/// An incrementing pool of ids with with recycle stack. Reuses IDs from the recycle stack when
/// available, otherwise increments a counter. Drops IDs if the stack is full.
pub const IdPool = struct {
    next: u32,
    recycle_stack: []object,
    recycle_count: u32 = 0,

    /// Allocates a new object ID.
    pub fn new(self: *IdPool) object {
        if (self.recycle_count > 0) {
            self.recycle_count -= 1;
            return self.recycle_stack[self.recycle_count];
        }
        const id = self.next;
        self.next = id + 1;
        return @enumFromInt(id);
    }

    /// Returns an ID for reuse, called when processing wl_display.delete_id.
    pub fn delete(self: *IdPool, id: object) void {
        if (self.recycle_count < self.recycle_stack.len) {
            self.recycle_stack[self.recycle_count] = id;
            self.recycle_count += 1;
        }
    }
};

/// Optional zombie ID tracking. If enabled, lookup() can distinguish
/// "zombie" (recently destroyed, expected) from "truly unknown" (API misuse).
/// If the zombie map ever fails to allocate, tracking is disabled
/// connection-wide and the oom_handler fires once. Subsequent destructor
/// calls behave as if zombie tracking was never enabled.
pub const Zombies = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(object, void) = .empty,
    oom_handler: *const fn () void = &defaultOomHandler,

    /// Returns true if tracked, false if OOM (caller should disable tracking).
    fn put(self: *Zombies, id: object) bool {
        self.map.put(self.allocator, id, {}) catch return false;
        return true;
    }

    pub fn contains(self: *const Zombies, id: object) bool {
        return self.map.contains(id);
    }

    fn remove(self: *Zombies, id: object) void {
        _ = self.map.remove(id);
    }

    fn defaultOomHandler() void {
        std.debug.panic("zombie tracking allocation failed (out of memory)", .{});
    }
};

// NOTE: we use a string instead of enum literal because strings can be
//       constructed at comptime.
pub const Object = struct { [:0]const u8, Interface };

/// A bound instance of wayland objects. Tracks object IDs and provides
/// type-safe write() that automatically injects writer and object ID.
pub fn Instance(comptime objects: []const Object) type {
    const capacity = objects.len;
    const E = std.math.IntFittingRange(0, capacity);

    return struct {
        writer: *std.Io.Writer,
        inner: IdMap,
        id_pool: *IdPool,
        maybe_zombies: ?Zombies,

        const Self = @This();

        pub const Store = IdMap.Store(capacity);

        pub const Kind = blk: {
            var fields: [capacity]std.builtin.Type.EnumField = undefined;
            for (objects, 0..) |obj, i| {
                fields[i] = .{ .name = obj[0], .value = i };
            }
            break :blk @Type(.{ .@"enum" = .{
                .tag_type = E,
                .fields = &fields,
                .is_exhaustive = true,
                .decls = &.{},
            } });
        };

        pub const ServerKind = blk: {
            var fields: [capacity]std.builtin.Type.EnumField = undefined;
            var count: usize = 0;
            for (objects, 0..) |obj, i| {
                if (!obj[1].hasDestructor()) {
                    fields[count] = .{ .name = obj[0], .value = i };
                    count += 1;
                }
            }
            break :blk @Type(.{ .@"enum" = .{
                .tag_type = E,
                .fields = fields[0..count],
                .is_exhaustive = false,
                .decls = &.{},
            } });
        };

        pub fn init(writer: *std.Io.Writer, store: *Store, id_pool: *IdPool, opt: struct {
            /// Optional sanity checking. Due to the nature of IDs on wayland, it
            /// required unbounded growth so, it takes an allocator. If your app has no
            /// bugs around
            /// id lifetimes then you don't need this.
            zombies: ?Zombies = null,
        }) Self {
            return .{
                .writer = writer,
                .inner = store.map(),
                .id_pool = id_pool,
                .maybe_zombies = opt.zombies,
            };
        }

        /// Allocates a new object ID and maps it to the given kind.
        pub fn new(self: *Self, kind: Kind) object {
            std.debug.assert(self.inner.getKey(@intFromEnum(kind)) == null);
            const id = self.id_pool.new();
            self.inner.put(@intFromEnum(id), @intFromEnum(kind));
            return id;
        }

        /// Returns the object ID for the given kind (reverse array index).
        pub fn getOpt(self: *const Self, kind: Kind) ?object {
            const k = self.inner.getKey(@intFromEnum(kind)) orelse return null;
            return @enumFromInt(k);
        }

        /// Returns the object ID for the given kind, panics if not mapped.
        pub fn get(self: *const Self, kind: Kind) object {
            return self.getOpt(kind) orelse
                std.debug.panic("Instance: no object for {s}", .{@tagName(kind)});
        }

        /// Looks up the kind for an object ID (hash map lookup).
        /// Returns null for zombie IDs (destroyed but delete_id not yet received).
        /// If zombie tracking is enabled, panics on truly unknown IDs (API misuse).
        pub fn lookup(self: *const Self, key: object) ?Kind {
            const v = self.inner.get(@intFromEnum(key)) orelse {
                if (self.maybe_zombies) |*zombies| {
                    if (zombies.contains(key)) return null;
                    std.debug.panic("Instance: unknown object {} (not live and not zombie)", .{@intFromEnum(key)});
                }
                return null;
            };
            return @enumFromInt(v);
        }

        /// Remove a server-destroyed object from the map. No zombie tracking
        /// needed since the server initiated the destruction.
        pub fn remove(self: *Self, kind: ServerKind) void {
            const idx = @intFromEnum(kind);
            const k = self.inner.getKey(idx) orelse
                std.debug.panic("Instance: no object for {s}", .{@tagName(kind)});
            std.debug.assert(self.inner.remove(k));
        }

        /// Abandon a live object that has no destructor request. Removes it
        /// from the map and adds it to zombie tracking so that late events
        /// are silently discarded instead of panicking.
        pub fn abandon(self: *Self, kind: ServerKind) void {
            const idx = @intFromEnum(kind);
            const k = self.inner.getKey(idx) orelse
                std.debug.panic("Instance: no object for {s}", .{@tagName(kind)});
            std.debug.assert(self.inner.remove(k));
            if (self.maybe_zombies) |*zombies| {
                if (!zombies.put(@enumFromInt(k))) {
                    zombies.oom_handler();
                    zombies.map.deinit(zombies.allocator);
                    self.maybe_zombies = null;
                }
            }
        }

        /// Handle wl_display.delete_id - recycle the ID and remove from
        /// zombie tracking if present.
        pub fn delete(self: *Self, key: object) void {
            // ID must already be out of the map (removed by remove() or write(destructor))
            std.debug.assert(self.inner.get(@intFromEnum(key)) == null);
            if (self.maybe_zombies) |*zombies| {
                zombies.remove(key);
            }
            self.id_pool.delete(key);
        }

        /// Send a request on a bound object. Writer and object ID are
        /// automatically prepended. If the method is a destructor, the
        /// object is automatically removed from the map and tracked as
        /// a zombie (if zombies is set).
        pub fn write(
            self: *Self,
            comptime kind: Kind,
            comptime method: InterfaceType(kind).Method,
            args: @field(InterfaceType(kind), @tagName(method) ++ "_params"),
        ) @typeInfo(@TypeOf(@field(InterfaceType(kind), @tagName(method)))).@"fn".return_type.? {
            const func = @field(InterfaceType(kind), @tagName(method));
            const id = self.get(kind);
            const FullArgs = std.meta.ArgsTuple(@TypeOf(func));
            var full_args: FullArgs = undefined;
            full_args[0] = self.writer;
            full_args[1] = id;
            inline for (2..@typeInfo(FullArgs).@"struct".fields.len) |i| {
                full_args[i] = args[i - 2];
            }
            const result = @call(.auto, func, full_args);
            if (method.isDestructor()) {
                const k = self.inner.getKey(@intFromEnum(kind)) orelse unreachable;
                std.debug.assert(self.inner.remove(k));
                if (self.maybe_zombies) |*zombies| {
                    if (!zombies.put(id)) {
                        zombies.oom_handler();
                        // Disable zombie tracking. If we miss a zombie ID,
                        // lookup() would incorrectly panic thinking it's API misuse.
                        zombies.map.deinit(zombies.allocator);
                        self.maybe_zombies = null;
                    }
                }
            }
            return result;
        }

        fn InterfaceType(comptime kind: Kind) type {
            return objects[@intFromEnum(kind)][1].Type();
        }
    };
}

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
                result.len = @intCast(unix_sockaddr_path_offset + wayland_display.len);
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

pub const Interface = generated.Interface;
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

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const generated = @import("generated");
