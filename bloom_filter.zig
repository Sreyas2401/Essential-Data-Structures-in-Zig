const std = @import("std");
const Allocator = std.mem.Allocator;

// Bloom Filter:
// - Probabilistic data structure for set membership testing
// - Space-efficient but allows false positives (never false negatives)
// - False positive rate depends on: number of hash functions (k), bit array size (m), and number of elements (n)
// - Optimal k = (m/n) * ln(2)
// - Applications: caching, database query optimization, network routers
// - Time complexity: O(k) for insert and query operations
//
// Implementation inspired by Google Guava's Bloom Filter

pub fn BloomFilter(comptime T: type) type {
    return struct {
        const Self = @This();

        bit_array: []u64,
        num_hash_functions: u32,
        num_bits: u64,
        num_items: u64,
        allocator: Allocator,

        pub fn create(allocator: Allocator, expected_insertions: usize, fpp: f64) !Self {
            if (expected_insertions == 0) return error.InvalidExpectedInsertions;
            if (fpp <= 0.0 or fpp >= 1.0) return error.InvalidFalsePositiveProbability;

            const num_bits = optimalNumOfBits(expected_insertions, fpp);
            const num_hash_functions = optimalNumOfHashFunctions(expected_insertions, num_bits);

            const array_size = (num_bits + 63) / 64;
            const bit_array = try allocator.alloc(u64, array_size);
            @memset(bit_array, 0);

            return Self{
                .bit_array = bit_array,
                .num_hash_functions = @intCast(num_hash_functions),
                .num_bits = num_bits,
                .num_items = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bit_array);
        }

        pub fn put(self: *Self, item: T) bool {
            const hash_val = hashItem(item);
            const changed = self.putCombinedHash(hash_val);
            if (changed) {
                self.num_items += 1;
            }
            return changed;
        }

        pub fn mightContain(self: *const Self, item: T) bool {
            const hash_val = hashItem(item);
            return self.mightContainCombinedHash(hash_val);
        }

        fn putCombinedHash(self: *Self, combined_hash: u128) bool {
            var changed = false;
            const hash1: u64 = @truncate(combined_hash);
            const hash2: u64 = @truncate(combined_hash >> 64);

            var i: u32 = 0;
            while (i < self.num_hash_functions) : (i += 1) {
                const combined = @as(u128, hash1) +% (@as(u128, i) *% @as(u128, hash2));
                const bit_index = @as(u64, @truncate(combined)) % self.num_bits;
                changed = self.setBit(bit_index) or changed;
            }
            return changed;
        }

        fn mightContainCombinedHash(self: *const Self, combined_hash: u128) bool {
            const hash1: u64 = @truncate(combined_hash);
            const hash2: u64 = @truncate(combined_hash >> 64);

            var i: u32 = 0;
            while (i < self.num_hash_functions) : (i += 1) {
                const combined = @as(u128, hash1) +% (@as(u128, i) *% @as(u128, hash2));
                const bit_index = @as(u64, @truncate(combined)) % self.num_bits;
                if (!self.getBit(bit_index)) {
                    return false;
                }
            }
            return true;
        }

        fn setBit(self: *Self, index: u64) bool {
            const word_index = index / 64;
            const bit_index: u6 = @intCast(index % 64);
            const mask: u64 = @as(u64, 1) << bit_index;
            const old_value = self.bit_array[word_index];
            self.bit_array[word_index] |= mask;
            return old_value != self.bit_array[word_index];
        }

        fn getBit(self: *const Self, index: u64) bool {
            const word_index = index / 64;
            const bit_index: u6 = @intCast(index % 64);
            const mask: u64 = @as(u64, 1) << bit_index;
            return (self.bit_array[word_index] & mask) != 0;
        }

        fn hashItem(item: T) u128 {
            const bytes = std.mem.asBytes(&item);
            const hash1 = std.hash.Wyhash.hash(0, bytes);
            const hash2 = std.hash.Wyhash.hash(1, bytes);
            return (@as(u128, hash1)) | (@as(u128, hash2) << 64);
        }

        pub fn expectedFpp(self: *const Self) f64 {
            return expectedFalsePositiveProbability(self.num_items, self.num_bits, self.num_hash_functions);
        }

        pub fn approximateElementCount(self: *const Self) u64 {
            return self.num_items;
        }

        pub fn bitSize(self: *const Self) u64 {
            return self.num_bits;
        }

        pub fn isCompatible(self: *const Self, other: *const Self) bool {
            return self.num_hash_functions == other.num_hash_functions and
                self.num_bits == other.num_bits;
        }

        pub fn putAll(self: *Self, other: *const Self) !void {
            if (!self.isCompatible(other)) return error.IncompatibleBloomFilters;

            self.num_items += other.num_items;
            for (self.bit_array, 0..) |*word, i| {
                word.* |= other.bit_array[i];
            }
        }
    };
}

fn optimalNumOfBits(expected_insertions: usize, fpp: f64) u64 {
    if (fpp == 0.0) {
        return std.math.maxInt(u64);
    }
    const n: f64 = @floatFromInt(expected_insertions);
    const num_bits = -n * @log(fpp) / (std.math.ln2 * std.math.ln2);
    return @intFromFloat(@max(1.0, @ceil(num_bits)));
}

fn optimalNumOfHashFunctions(expected_insertions: usize, num_bits: u64) u32 {
    const m: f64 = @floatFromInt(num_bits);
    const n: f64 = @floatFromInt(expected_insertions);
    const k = @max(1.0, @round((m / n) * std.math.ln2));
    return @intFromFloat(k);
}

fn expectedFalsePositiveProbability(insertions: u64, num_bits: u64, num_hash_functions: u32) f64 {
    if (insertions == 0) return 0.0;
    const m: f64 = @floatFromInt(num_bits);
    const k: f64 = @floatFromInt(num_hash_functions);
    const n: f64 = @floatFromInt(insertions);
    return std.math.pow(f64, 1.0 - std.math.exp(-k * n / m), k);
}



test "BloomFilter: create with expected insertions and fpp" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf.deinit();

    try std.testing.expect(bf.num_bits > 0);
    try std.testing.expect(bf.num_hash_functions > 0);
    try std.testing.expectEqual(@as(u64, 0), bf.num_items);
}

test "BloomFilter: put and mightContain" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf.deinit();

    _ = bf.put(42);
    _ = bf.put(100);
    _ = bf.put(255);

    try std.testing.expect(bf.mightContain(42));
    try std.testing.expect(bf.mightContain(100));
    try std.testing.expect(bf.mightContain(255));
    try std.testing.expectEqual(@as(u64, 3), bf.approximateElementCount());
}

test "BloomFilter: does not contain" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf.deinit();

    _ = bf.put(42);

    try std.testing.expect(!bf.mightContain(43));
    try std.testing.expect(!bf.mightContain(100));
}

test "BloomFilter: string insertion and lookup" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter([]const u8).create(allocator, 1000, 0.01);
    defer bf.deinit();

    const items = [_][]const u8{ "hello", "world", "bloom", "filter" };

    for (items) |item| {
        _ = bf.put(item);
    }

    for (items) |item| {
        try std.testing.expect(bf.mightContain(item));
    }

    try std.testing.expect(!bf.mightContain("nothere"));
    try std.testing.expect(!bf.mightContain("missing"));
}

test "BloomFilter: expectedFpp" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u32).create(allocator, 100, 0.01);
    defer bf.deinit();

    for (0..50) |i| {
        _ = bf.put(@intCast(i));
    }

    const estimated_fpp = bf.expectedFpp();
    try std.testing.expect(estimated_fpp >= 0.0);
    try std.testing.expect(estimated_fpp < 0.1);
}

test "BloomFilter: large number of insertions" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u64).create(allocator, 10000, 0.01);
    defer bf.deinit();

    for (0..5000) |i| {
        _ = bf.put(i);
    }

    for (0..5000) |i| {
        try std.testing.expect(bf.mightContain(i));
    }

    var false_positives: usize = 0;
    for (5000..10000) |i| {
        if (bf.mightContain(i)) {
            false_positives += 1;
        }
    }

    const fpr: f64 = @as(f64, @floatFromInt(false_positives)) / 5000.0;
    try std.testing.expect(fpr < 0.05);
}

test "BloomFilter: duplicate insertions" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf.deinit();

    const changed1 = bf.put(42);
    const changed2 = bf.put(42);
    const changed3 = bf.put(42);

    try std.testing.expect(changed1);
    try std.testing.expect(!changed2); // Should not change
    try std.testing.expect(!changed3); // Should not change
    try std.testing.expect(bf.mightContain(42));
}

test "BloomFilter: putAll compatibility" {
    const allocator = std.testing.allocator;

    var bf1 = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf1.deinit();

    var bf2 = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf2.deinit();

    _ = bf1.put(1);
    _ = bf1.put(2);
    _ = bf2.put(3);
    _ = bf2.put(4);

    try bf1.putAll(&bf2);

    try std.testing.expect(bf1.mightContain(1));
    try std.testing.expect(bf1.mightContain(2));
    try std.testing.expect(bf1.mightContain(3));
    try std.testing.expect(bf1.mightContain(4));
}

test "BloomFilter: isCompatible" {
    const allocator = std.testing.allocator;

    var bf1 = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf1.deinit();

    var bf2 = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf2.deinit();

    var bf3 = try BloomFilter(u32).create(allocator, 2000, 0.01);
    defer bf3.deinit();

    try std.testing.expect(bf1.isCompatible(&bf2));
    try std.testing.expect(!bf1.isCompatible(&bf3));
}

test "BloomFilter: error cases" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidExpectedInsertions, BloomFilter(u32).create(allocator, 0, 0.01));
    try std.testing.expectError(error.InvalidFalsePositiveProbability, BloomFilter(u32).create(allocator, 100, 0.0));
    try std.testing.expectError(error.InvalidFalsePositiveProbability, BloomFilter(u32).create(allocator, 100, 1.0));
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("\n=== Bloom Filter Demo (Guava-style) ===\n\n", .{});

    var bf = try BloomFilter(u32).create(allocator, 1000, 0.01);
    defer bf.deinit();

    std.debug.print("Created Bloom Filter:\n", .{});
    std.debug.print("  Bits: {d}\n", .{bf.bitSize()});
    std.debug.print("  Hash functions: {d}\n", .{bf.num_hash_functions});
    std.debug.print("  Expected false positive rate: 1%\n\n", .{});

    const numbers = [_]u32{ 42, 123, 456, 789, 1024 };

    std.debug.print("Inserting numbers: ", .{});
    for (numbers) |num| {
        const changed = bf.put(num);
        std.debug.print("{d}({}) ", .{ num, changed });
    }
    std.debug.print("\n\n", .{});

    std.debug.print("Checking membership:\n", .{});
    for (numbers) |num| {
        std.debug.print("  {d}: {}\n", .{ num, bf.mightContain(num) });
    }

    std.debug.print("\nChecking non-members:\n", .{});
    const non_members = [_]u32{ 1, 2, 3, 99, 999 };
    for (non_members) |num| {
        std.debug.print("  {d}: {}\n", .{ num, bf.mightContain(num) });
    }

    std.debug.print("\nExpected FPP: {d:.4}%\n", .{bf.expectedFpp() * 100});
    std.debug.print("Approximate element count: {d}\n", .{bf.approximateElementCount()});

    std.debug.print("\n=== String Bloom Filter Demo ===\n\n", .{});

    var string_bf = try BloomFilter([]const u8).create(allocator, 100, 0.01);
    defer string_bf.deinit();

    const words = [_][]const u8{ "alice", "bob", "charlie", "david", "eve" };

    std.debug.print("Inserting names: ", .{});
    for (words) |word| {
        _ = string_bf.put(word);
        std.debug.print("{s} ", .{word});
    }
    std.debug.print("\n\n", .{});

    std.debug.print("Checking membership:\n", .{});
    const test_words = [_][]const u8{ "alice", "bob", "frank", "eve", "mallory" };
    for (test_words) |word| {
        std.debug.print("  {s}: {}\n", .{ word, string_bf.mightContain(word) });
    }

    std.debug.print("\n=== Combining Bloom Filters ===\n\n", .{});

    var bf1 = try BloomFilter(u32).create(allocator, 100, 0.01);
    defer bf1.deinit();
    var bf2 = try BloomFilter(u32).create(allocator, 100, 0.01);
    defer bf2.deinit();

    _ = bf1.put(1);
    _ = bf1.put(2);
    _ = bf2.put(3);
    _ = bf2.put(4);

    std.debug.print("BF1 contains: 1, 2\n", .{});
    std.debug.print("BF2 contains: 3, 4\n", .{});
    std.debug.print("Are compatible: {}\n\n", .{bf1.isCompatible(&bf2)});

    try bf1.putAll(&bf2);
    std.debug.print("After putAll, BF1 contains:\n", .{});
    std.debug.print("  1: {}\n", .{bf1.mightContain(1)});
    std.debug.print("  2: {}\n", .{bf1.mightContain(2)});
    std.debug.print("  3: {}\n", .{bf1.mightContain(3)});
    std.debug.print("  4: {}\n", .{bf1.mightContain(4)});
}
