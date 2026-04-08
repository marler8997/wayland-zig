/// A fixed-capacity bijective map from u32 keys to u32 values.
/// Keys are sparse (wayland object IDs), values are dense [0, capacity).
/// All storage is caller-provided, no heap allocation. The caller
/// must provide a buffer of at least `storeSize(capacity)` bytes
/// and a reverse array of length `capacity`.
const IdMap = @This();

const load_percentage = 80;
const Map = std.HashMapUnmanaged(u32, u32, Context, load_percentage);
const Context = std.hash_map.AutoContext(u32);
const context: Context = .{};

const no_key = 0;

store: []align(store_align) u8,
reverse: []u32,
map: Map = .empty,

pub fn init(store: []align(store_align) u8, reverse: []u32, capacity: u32) IdMap {
    std.debug.assert(store.len >= storeSize(capacity));
    std.debug.assert(reverse.len >= capacity);
    @memset(reverse[0..capacity], no_key);
    var map: Map = .empty;
    var fba = std.heap.FixedBufferAllocator.init(store);
    map.ensureTotalCapacityContext(fba.allocator(), capacity, context) catch
        unreachable; // caller provided sufficient storage
    return .{ .store = store, .reverse = reverse, .map = map };
}

pub fn put(self: *IdMap, key: u32, value: u32) void {
    std.debug.assert(key != no_key);
    if (self.reverse[value] != no_key)
        std.debug.panic("IdMap: value {} already mapped to key {}", .{ value, self.reverse[value] });
    self.reverse[value] = key;
    self.map.putAssumeCapacityNoClobber(key, value);
}

pub fn get(self: *const IdMap, key: u32) ?u32 {
    return self.map.get(key);
}

pub fn getKey(self: *const IdMap, value: u32) ?u32 {
    const key = self.reverse[value];
    return if (key == no_key) null else key;
}

pub fn remove(self: *IdMap, key: u32) bool {
    const kv = self.map.fetchRemove(key) orelse return false;
    std.debug.assert(self.reverse[kv.value] != no_key);
    self.reverse[kv.value] = no_key;
    return true;
}

pub fn storeSize(capacity: u32) usize {
    const cap: usize = mapCapacity(capacity);
    const header_align = @alignOf(MapHeader);
    const key_align = @alignOf(u32);
    const val_align = @alignOf(u32);
    const max_align = @max(header_align, key_align, val_align);

    const meta_size = @sizeOf(MapHeader) + cap; // Metadata is 1 byte
    const keys_start = std.mem.alignForward(usize, meta_size, key_align);
    const keys_end = keys_start + cap * @sizeOf(u32);
    const vals_start = std.mem.alignForward(usize, keys_end, val_align);
    const vals_end = vals_start + cap * @sizeOf(u32);
    return std.mem.alignForward(usize, vals_end, max_align);
}

pub const store_align = @max(@alignOf(MapHeader), @alignOf(u32));

fn mapCapacity(count: u32) u32 {
    var cap: u32 = @intCast((@as(u64, count) * 100) / load_percentage + 1);
    cap = std.math.ceilPowerOfTwo(u32, cap) catch unreachable;
    return @max(cap, 8); // std uses minimal_capacity = 8
}

/// Mirrors the layout of std.HashMapUnmanaged's private Header type.
/// Header = struct { values: [*]V, keys: [*]K, capacity: Size }.
/// For u32 keys/values: two pointers + one u32.
const MapHeader = struct { values: [*]u32, keys: [*]u32, capacity: u32 };
comptime {
    // If std ever changes the Header to have more or fewer fields,
    // this size check (combined with the unreachable in init) will catch it.
    // Header sits before metadata; capacity() reads it at metadata - @sizeOf(Header).
    const Metadata = @typeInfo(@typeInfo(std.meta.fieldInfo(Map, .metadata).type).optional.child).pointer.child;
    std.debug.assert(@sizeOf(Metadata) == 1);
}

const test_capacities = [_]u32{
    0,
    1,
    2,
    3,
    10,
    100,
    1000,
    // 10_000,
    // 1_000_000,
};

pub fn Store(comptime capacity: u32) type {
    return struct {
        store: [storeSize(capacity)]u8 align(store_align) = undefined,
        reverse: [capacity]u32 = undefined,
        pub fn map(s: *@This()) IdMap {
            return IdMap.init(&s.store, &s.reverse, capacity);
        }
    };
}

test "basic put and get" {
    var store: Store(8) = .{};
    var m = store.map();
    m.put(10, 1);
    m.put(20, 2);
    m.put(30, 3);
    try testing.expectEqual(1, m.get(10).?);
    try testing.expectEqual(2, m.get(20).?);
    try testing.expectEqual(3, m.get(30).?);
    try testing.expectEqual(null, m.get(99));
    // Reverse lookup
    try testing.expectEqual(10, m.getKey(1).?);
    try testing.expectEqual(null, m.getKey(0));
}

test "remove" {
    var s: Store(8) = .{};
    var m = s.map();
    m.put(5, 3);
    try testing.expectEqual(3, m.get(5).?);
    try testing.expectEqual(5, m.getKey(3).?);
    try testing.expect(m.remove(5));
    try testing.expect(!m.remove(5)); // already removed
    try testing.expectEqual(null, m.get(5));
    try testing.expectEqual(null, m.getKey(3));
}

test "fill, remove all, refill" {
    inline for (&test_capacities) |capacity| {
        var s: Store(capacity) = .{};
        var m = s.map();

        for (0..capacity) |i| {
            m.put(@intCast(i * 1000 + 1), @intCast(i));
        }
        for (0..capacity) |i| {
            try testing.expect(m.remove(@intCast(i * 1000 + 1)));
        }
        for (0..capacity) |i| {
            m.put(@intCast(i * 7777 + 1), @intCast(i));
        }
        for (0..capacity) |i| {
            try testing.expectEqual(@as(u32, @intCast(i)), m.get(@intCast(i * 7777 + 1)).?);
        }
    }
}

test "fill to capacity with sparse keys" {
    inline for (&test_capacities) |capacity| {
        const seeds = [_]u64{ 0, 1, 42, 0xcafebabe, 0xffffffff };
        for (seeds) |seed| {
            var s: Store(capacity) = .{};
            var m = s.map();

            var rng = std.Random.DefaultPrng.init(seed);
            const random = rng.random();

            // Include boundary keys when capacity allows
            if (capacity >= 1) m.put(std.math.maxInt(u32), m.map.size);
            if (capacity >= 2) m.put(1, m.map.size);
            while (m.map.size < capacity) {
                const key = random.intRangeAtMost(u32, 1, std.math.maxInt(u32));
                if (m.get(key) != null) continue;
                m.put(key, m.map.size);
            }

            for (0..capacity) |i| {
                try testing.expect(m.getKey(@intCast(i)) != null);
            }
        }
    }
}

test "tombstone stress: repeated fill/remove cycles at full capacity" {
    inline for (&test_capacities) |capacity| {
        var s: Store(capacity) = .{};
        var m = s.map();

        var rng = std.Random.DefaultPrng.init(0x12345678);
        const random = rng.random();

        for (0..50) |_| {
            var keys: [capacity]u32 = undefined;
            var i: u32 = 0;
            while (i < capacity) {
                const key = random.intRangeAtMost(u32, 1, std.math.maxInt(u32));
                if (m.get(key) != null) continue;
                keys[i] = key;
                m.put(key, i);
                i += 1;
            }
            try testing.expectEqual(capacity, m.map.size);

            for (keys[0..capacity], 0..) |k, j| {
                try testing.expectEqual(@as(u32, @intCast(j)), m.get(k).?);
            }

            for (keys[0..capacity]) |k| {
                try testing.expect(m.remove(k));
            }
            try testing.expectEqual(@as(u32, 0), m.map.size);
        }
    }
}

test "exhaustive storeSize verification" {
    const max_capacity = 199;
    var store: [storeSize(max_capacity)]u8 align(store_align) = undefined;
    var reverse: [max_capacity]u32 = undefined;

    for (1..max_capacity + 1) |capacity_usize| {
        const capacity: u32 = @intCast(capacity_usize);

        var m = IdMap.init(&store, reverse[0..capacity], capacity);

        // Fill to exact capacity with sparse keys
        for (0..capacity) |i| {
            m.put(@intCast(i + 1), @intCast(i));
        }
        try testing.expectEqual(capacity, m.map.size);

        // Verify all entries
        for (0..capacity) |i| {
            try testing.expectEqual(@as(u32, @intCast(i)), m.get(@intCast(i + 1)).?);
            try testing.expectEqual(@as(u32, @intCast(i + 1)), m.getKey(@intCast(i)).?);
        }

        // Remove all and refill to verify tombstone handling
        for (0..capacity) |i| {
            try testing.expect(m.remove(@intCast(i + 1)));
        }
        for (0..capacity) |i| {
            m.put(@intCast(i + 1000), @intCast(i));
        }
        try testing.expectEqual(capacity, m.map.size);
    }
}

test "all possible keys (slow)" {
    if (true) return error.SkipZigTest;
    const capacity = 32;
    var store: [storeSize(capacity)]u8 align(store_align) = undefined;
    var reverse: [capacity]u32 = undefined;

    var m = IdMap.init(&store, &reverse, capacity);

    var rng = std.Random.DefaultPrng.init(0xaabbccdd);
    const random = rng.random();

    var timer = try std.time.Timer.start();
    var high_water: u32 = 0;
    var key: u32 = 1;
    var milestone: u32 = 1 << 20; // ~1M
    while (true) {
        const value = random.intRangeLessThan(u32, 0, capacity);
        if (m.getKey(value)) |old_key| {
            std.debug.assert(m.remove(old_key));
        }
        m.put(key, value);
        if (m.map.size > high_water) {
            high_water = m.map.size;
            std.debug.print("high water: {}/{} at key={}\n", .{ high_water, capacity, key });
        }
        if (key == milestone) {
            const elapsed = timer.read();
            const elapsed_s = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
            const total_est = elapsed_s * @as(f64, @floatFromInt(std.math.maxInt(u32))) / @as(f64, @floatFromInt(key));
            std.debug.print("key={} elapsed={d:.1}s est_total={d:.1}s\n", .{ key, elapsed_s, total_est });
            milestone *|= 2;
        }
        if (key == std.math.maxInt(u32)) break;
        if (timer.read() >= 60 * std.time.ns_per_s) break;
        key += 1;
    }
    const elapsed = timer.read();
    std.debug.print("final high water: {}/{} keys tested: {} done in {d:.1}s\n", .{ high_water, capacity, key, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s });
}

const std = @import("std");
const testing = std.testing;
