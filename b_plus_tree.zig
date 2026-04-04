const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn BPlusTree(comptime Key: type, comptime Value: type, comptime max_keys: usize) type {
    if (max_keys < 3) @compileError("B+ tree order must allow at least 3 keys per node");

    return struct {
        const Self = @This();
        const min_keys: usize = max_keys / 2;
        const min_children: usize = min_keys + 1;
        const nodes_per_page: usize = 64;

        pub const Entry = struct {
            key: Key,
            value: Value,
        };

        const Node = struct {
            is_leaf: bool,
            keys: std.ArrayListUnmanaged(Key) = .{},
            values: std.ArrayListUnmanaged(Value) = .{},
            children: std.ArrayListUnmanaged(*Node) = .{},
            next: ?*Node = null,
            free_next: ?*Node = null,
        };

        pub const PageStats = struct {
            pages: usize,
            free_nodes: usize,
            nodes_per_page: usize,
        };

        pub const PageStore = struct {
            allocator: Allocator,
            pages: std.ArrayListUnmanaged([]Node) = .{},
            free_list: ?*Node = null,

            pub fn init(allocator: Allocator) PageStore {
                return .{ .allocator = allocator };
            }

            pub fn deinit(self: *PageStore) void {
                for (self.pages.items) |page| {
                    self.allocator.free(page);
                }
                self.pages.deinit(self.allocator);
                self.free_list = null;
            }

            fn pushFreeList(self: *PageStore, node: *Node) void {
                node.free_next = self.free_list;
                self.free_list = node;
            }

            fn allocatePage(self: *PageStore) !void {
                const page = try self.allocator.alloc(Node, nodes_per_page);
                errdefer self.allocator.free(page);

                try self.pages.append(self.allocator, page);
                for (page) |*slot| {
                    slot.* = .{ .is_leaf = true };
                    self.pushFreeList(slot);
                }
            }

            pub fn acquire(self: *PageStore, is_leaf: bool) !*Node {
                if (self.free_list == null) {
                    try self.allocatePage();
                }

                const node = self.free_list orelse return error.OutOfMemory;
                self.free_list = node.free_next;
                node.* = .{ .is_leaf = is_leaf };
                return node;
            }

            pub fn release(self: *PageStore, node: *Node) void {
                node.keys.deinit(self.allocator);
                node.values.deinit(self.allocator);
                node.children.deinit(self.allocator);
                node.next = null;
                node.is_leaf = true;
                self.pushFreeList(node);
            }

            pub fn stats(self: *const PageStore) PageStats {
                var free_count: usize = 0;
                var current = self.free_list;
                while (current) |node| {
                    free_count += 1;
                    current = node.free_next;
                }

                return .{
                    .pages = self.pages.items.len,
                    .free_nodes = free_count,
                    .nodes_per_page = nodes_per_page,
                };
            }
        };

        pub const ValidationError = error{
            InvalidStructure,
            InvalidOrdering,
        };

        pub const Iterator = struct {
            current: ?*Node,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.current) |node| {
                    if (self.index >= node.keys.items.len) {
                        self.current = node.next;
                        self.index = 0;
                        continue;
                    }

                    if (self.index < node.keys.items.len) {
                        const entry = Entry{
                            .key = node.keys.items[self.index],
                            .value = node.values.items[self.index],
                        };
                        self.index += 1;
                        return entry;
                    }
                }

                return null;
            }
        };

        pub const RangeIterator = struct {
            iter: Iterator,
            end_key: Key,
            finished: bool = false,

            pub fn next(self: *RangeIterator) ?Entry {
                if (self.finished) return null;

                if (self.iter.next()) |entry| {
                    if (entry.key > self.end_key) {
                        self.finished = true;
                        return null;
                    }
                    return entry;
                }

                self.finished = true;
                return null;
            }
        };

        root: ?*Node = null,
        storage: PageStore,

        pub fn init(allocator: Allocator) Self {
            return .{ .storage = PageStore.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.destroyNode(self.root);
            self.root = null;
            self.storage.deinit();
        }

        fn destroyNode(self: *Self, node: ?*Node) void {
            if (node) |n| {
                if (!n.is_leaf) {
                    for (n.children.items) |child| {
                        self.destroyNode(child);
                    }
                }

                self.storage.release(n);
            }
        }

        fn createNode(self: *Self, is_leaf: bool) !*Node {
            return try self.storage.acquire(is_leaf);
        }

        fn firstKeyOfNode(node: *const Node) Key {
            if (node.is_leaf) return node.keys.items[0];
            return firstKeyOfNode(node.children.items[0]);
        }

        fn syncInternalKeys(self: *Self, node: *Node) !void {
            if (node.is_leaf) return;

            node.keys.clearRetainingCapacity();
            if (node.children.items.len <= 1) {
                return;
            }

            try node.keys.ensureTotalCapacity(self.storage.allocator, node.children.items.len - 1);
            for (node.children.items[1..]) |child| {
                try node.keys.append(self.storage.allocator, firstKeyOfNode(child));
            }
        }

        fn lowerBound(keys: []const Key, key: Key) usize {
            var index: usize = 0;
            while (index < keys.len and keys[index] < key) {
                index += 1;
            }
            return index;
        }

        fn childIndex(keys: []const Key, key: Key) usize {
            var index: usize = 0;
            while (index < keys.len and !(key < keys[index])) {
                index += 1;
            }
            return index;
        }

        fn findLeaf(self: *const Self, key: Key) ?*Node {
            var current = self.root orelse return null;

            while (!current.is_leaf) {
                const child_index = childIndex(current.keys.items, key);
                current = current.children.items[child_index];
            }

            return current;
        }

        fn leftmostLeaf(self: *const Self) ?*Node {
            var current = self.root orelse return null;

            while (!current.is_leaf) {
                current = current.children.items[0];
            }

            return current;
        }

        fn insertRecursive(self: *Self, node: *Node, key: Key, value: Value) !?*Node {
            if (node.is_leaf) {
                const index = lowerBound(node.keys.items, key);
                if (index < node.keys.items.len and node.keys.items[index] == key) {
                    node.values.items[index] = value;
                    return null;
                }

                try node.keys.insert(self.storage.allocator, index, key);
                try node.values.insert(self.storage.allocator, index, value);

                if (node.keys.items.len <= max_keys) {
                    return null;
                }

                return try self.splitLeaf(node);
            }

            const child_index = childIndex(node.keys.items, key);
            const child = node.children.items[child_index];
            if (try self.insertRecursive(child, key, value)) |right_child| {
                try node.children.insert(self.storage.allocator, child_index + 1, right_child);
                try self.syncInternalKeys(node);

                if (node.keys.items.len > max_keys) {
                    return try self.splitInternal(node);
                }
            }

            return null;
        }

        fn splitLeaf(self: *Self, node: *Node) !*Node {
            const right = try self.createNode(true);

            const total_keys = node.keys.items.len;
            const left_count = total_keys / 2;

            const old_keys = node.keys.items;
            const old_values = node.values.items;

            try right.keys.ensureTotalCapacity(self.storage.allocator, total_keys - left_count);
            try right.values.ensureTotalCapacity(self.storage.allocator, total_keys - left_count);
            for (old_keys[left_count..]) |item| {
                try right.keys.append(self.storage.allocator, item);
            }
            for (old_values[left_count..]) |item| {
                try right.values.append(self.storage.allocator, item);
            }

            node.keys.items = old_keys[0..left_count];
            node.values.items = old_values[0..left_count];

            right.next = node.next;
            node.next = right;

            return right;
        }

        fn splitInternal(self: *Self, node: *Node) !*Node {
            const right = try self.createNode(false);

            const total_children = node.children.items.len;
            const left_child_count = total_children / 2;

            const old_children = node.children.items;

            try right.children.ensureTotalCapacity(self.storage.allocator, total_children - left_child_count);
            for (old_children[left_child_count..]) |child| {
                try right.children.append(self.storage.allocator, child);
            }

            node.children.items = old_children[0..left_child_count];

            try self.syncInternalKeys(node);
            try self.syncInternalKeys(right);

            return right;
        }

        const DeleteOutcome = struct {
            removed: bool,
            underflow: bool,
        };

        fn canBorrowLeaf(node: *const Node) bool {
            return node.keys.items.len > min_keys;
        }

        fn canBorrowInternal(node: *const Node) bool {
            return node.children.items.len > min_children;
        }

        fn deleteRecursive(self: *Self, node: *Node, key: Key, is_root: bool) !DeleteOutcome {
            if (node.is_leaf) {
                const index = lowerBound(node.keys.items, key);
                if (index >= node.keys.items.len or node.keys.items[index] != key) {
                    return .{ .removed = false, .underflow = false };
                }

                _ = node.keys.orderedRemove(index);
                _ = node.values.orderedRemove(index);

                return .{
                    .removed = true,
                    .underflow = !is_root and node.keys.items.len < min_keys,
                };
            }

            const child_index = childIndex(node.keys.items, key);
            const child = node.children.items[child_index];
            const outcome = try self.deleteRecursive(child, key, false);
            if (!outcome.removed) {
                return outcome;
            }

            if (outcome.underflow) {
                try self.rebalanceChild(node, child_index);
            }

            try self.syncInternalKeys(node);
            return .{
                .removed = true,
                .underflow = !is_root and node.children.items.len < min_children,
            };
        }

        fn rebalanceChild(self: *Self, parent: *Node, child_index: usize) !void {
            if (child_index > 0) {
                const left = parent.children.items[child_index - 1];
                const child = parent.children.items[child_index];
                if (child.is_leaf) {
                    if (canBorrowLeaf(left)) {
                        const borrowed_key = left.keys.items[left.keys.items.len - 1];
                        const borrowed_value = left.values.items[left.values.items.len - 1];
                        left.keys.items.len -= 1;
                        left.values.items.len -= 1;
                        try child.keys.insert(self.storage.allocator, 0, borrowed_key);
                        try child.values.insert(self.storage.allocator, 0, borrowed_value);
                        try self.syncInternalKeys(parent);
                        return;
                    }

                    try self.mergeLeafIntoLeft(parent, child_index);
                    return;
                }

                if (canBorrowInternal(left)) {
                    const borrowed_child = left.children.items[left.children.items.len - 1];
                    left.children.items.len -= 1;
                    try child.children.insert(self.storage.allocator, 0, borrowed_child);
                    try self.syncInternalKeys(left);
                    try self.syncInternalKeys(child);
                    try self.syncInternalKeys(parent);
                    return;
                }

                try self.mergeInternalIntoLeft(parent, child_index);
                return;
            }

            if (parent.children.items.len <= 1) {
                return;
            }

            const child = parent.children.items[child_index];
            const right = parent.children.items[child_index + 1];
            if (child.is_leaf) {
                if (canBorrowLeaf(right)) {
                    const borrowed_key = right.keys.orderedRemove(0);
                    const borrowed_value = right.values.orderedRemove(0);
                    try child.keys.append(self.storage.allocator, borrowed_key);
                    try child.values.append(self.storage.allocator, borrowed_value);
                    try self.syncInternalKeys(parent);
                    return;
                }

                try self.mergeLeafWithRight(parent, child_index);
                return;
            }

            if (canBorrowInternal(right)) {
                const borrowed_child = right.children.orderedRemove(0);
                try child.children.append(self.storage.allocator, borrowed_child);
                try self.syncInternalKeys(right);
                try self.syncInternalKeys(child);
                try self.syncInternalKeys(parent);
                return;
            }

            try self.mergeInternalWithRight(parent, child_index);
        }

        fn mergeLeafIntoLeft(self: *Self, parent: *Node, child_index: usize) !void {
            const left = parent.children.items[child_index - 1];
            const right = parent.children.items[child_index];

            try left.keys.ensureTotalCapacity(self.storage.allocator, left.keys.items.len + right.keys.items.len);
            try left.values.ensureTotalCapacity(self.storage.allocator, left.values.items.len + right.values.items.len);

            for (right.keys.items) |item| {
                try left.keys.append(self.storage.allocator, item);
            }
            for (right.values.items) |item| {
                try left.values.append(self.storage.allocator, item);
            }

            left.next = right.next;
            _ = parent.children.orderedRemove(child_index);
            self.storage.release(right);
            try self.syncInternalKeys(parent);
        }

        fn mergeLeafWithRight(self: *Self, parent: *Node, child_index: usize) !void {
            const left = parent.children.items[child_index];
            const right = parent.children.items[child_index + 1];

            try left.keys.ensureTotalCapacity(self.storage.allocator, left.keys.items.len + right.keys.items.len);
            try left.values.ensureTotalCapacity(self.storage.allocator, left.values.items.len + right.values.items.len);

            for (right.keys.items) |item| {
                try left.keys.append(self.storage.allocator, item);
            }
            for (right.values.items) |item| {
                try left.values.append(self.storage.allocator, item);
            }

            left.next = right.next;
            _ = parent.children.orderedRemove(child_index + 1);
            self.storage.release(right);
            try self.syncInternalKeys(parent);
        }

        fn mergeInternalIntoLeft(self: *Self, parent: *Node, child_index: usize) !void {
            const left = parent.children.items[child_index - 1];
            const right = parent.children.items[child_index];

            try left.children.ensureTotalCapacity(self.storage.allocator, left.children.items.len + right.children.items.len);
            for (right.children.items) |child| {
                try left.children.append(self.storage.allocator, child);
            }

            _ = parent.children.orderedRemove(child_index);
            self.storage.release(right);

            try self.syncInternalKeys(left);
            try self.syncInternalKeys(parent);
        }

        fn mergeInternalWithRight(self: *Self, parent: *Node, child_index: usize) !void {
            const left = parent.children.items[child_index];
            const right = parent.children.items[child_index + 1];

            try left.children.ensureTotalCapacity(self.storage.allocator, left.children.items.len + right.children.items.len);
            for (right.children.items) |child| {
                try left.children.append(self.storage.allocator, child);
            }

            _ = parent.children.orderedRemove(child_index + 1);
            self.storage.release(right);

            try self.syncInternalKeys(left);
            try self.syncInternalKeys(parent);
        }

        pub fn delete(self: *Self, key: Key) !bool {
            const root = self.root orelse return false;
            const outcome = try self.deleteRecursive(root, key, true);
            if (!outcome.removed) {
                return false;
            }

            if (self.root) |current_root| {
                if (!current_root.is_leaf and current_root.children.items.len == 1) {
                    const child = current_root.children.items[0];
                    self.storage.release(current_root);
                    self.root = child;
                } else if (current_root.is_leaf and current_root.keys.items.len == 0) {
                    self.storage.release(current_root);
                    self.root = null;
                }
            }

            return true;
        }

        pub fn remove(self: *Self, key: Key) !bool {
            return self.delete(key);
        }

        pub fn pageStats(self: *const Self) PageStats {
            return self.storage.stats();
        }

        pub fn put(self: *Self, key: Key, value: Value) !void {
            if (self.root == null) {
                const root = try self.createNode(true);
                try root.keys.append(self.storage.allocator, key);
                try root.values.append(self.storage.allocator, value);
                self.root = root;
                return;
            }

            const root = self.root.?;
            if (try self.insertRecursive(root, key, value)) |right_child| {
                const new_root = try self.createNode(false);
                try new_root.children.append(self.storage.allocator, root);
                try new_root.children.append(self.storage.allocator, right_child);
                try self.syncInternalKeys(new_root);
                self.root = new_root;
            }
        }

        pub fn insert(self: *Self, key: Key, value: Value) !void {
            try self.put(key, value);
        }

        pub fn get(self: *const Self, key: Key) ?Value {
            const leaf = self.findLeaf(key) orelse return null;
            const index = lowerBound(leaf.keys.items, key);
            if (index < leaf.keys.items.len and leaf.keys.items[index] == key) {
                return leaf.values.items[index];
            }

            return null;
        }

        pub fn lookup(self: *const Self, key: Key) ?Value {
            return self.get(key);
        }

        pub fn contains(self: *const Self, key: Key) bool {
            return self.get(key) != null;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .current = self.leftmostLeaf() };
        }

        pub fn iteratorFrom(self: *const Self, key: Key) Iterator {
            const leaf = self.findLeaf(key) orelse return .{ .current = null };
            return .{
                .current = leaf,
                .index = lowerBound(leaf.keys.items, key),
            };
        }

        pub fn rangeIterator(self: *const Self, start_key: Key, end_key: Key) RangeIterator {
            return .{
                .iter = self.iteratorFrom(start_key),
                .end_key = end_key,
            };
        }

        pub fn validate(self: *const Self) !void {
            if (self.root) |root| {
                var leaf_depth: ?usize = null;
                var previous_key: ?Key = null;
                try self.validateNode(root, true, 0, &leaf_depth, &previous_key);
            }
        }

        fn validateNode(
            self: *const Self,
            node: *const Node,
            is_root: bool,
            depth: usize,
            leaf_depth: *?usize,
            previous_key: *?Key,
        ) !void {
            if (node.keys.items.len > max_keys) {
                return error.InvalidStructure;
            }

            if (node.is_leaf) {
                if (!is_root and node.keys.items.len < min_keys) {
                    return error.InvalidStructure;
                }
            } else if (!is_root and node.children.items.len < min_children) {
                return error.InvalidStructure;
            }

            if (node.is_leaf) {
                if (node.values.items.len != node.keys.items.len) {
                    return error.InvalidStructure;
                }

                if (leaf_depth.*) |expected_depth| {
                    if (expected_depth != depth) return error.InvalidStructure;
                } else {
                    leaf_depth.* = depth;
                }

                var index: usize = 0;
                while (index < node.keys.items.len) : (index += 1) {
                    if (index > 0 and !(node.keys.items[index - 1] < node.keys.items[index])) {
                        return error.InvalidOrdering;
                    }

                    if (previous_key.*) |prev| {
                        if (!(prev < node.keys.items[index])) {
                            return error.InvalidOrdering;
                        }
                    }

                    previous_key.* = node.keys.items[index];
                }

                return;
            }

            if (node.children.items.len != node.keys.items.len + 1) {
                return error.InvalidStructure;
            }

            var index: usize = 0;
            while (index < node.keys.items.len) : (index += 1) {
                if (index > 0 and !(node.keys.items[index - 1] < node.keys.items[index])) {
                    return error.InvalidOrdering;
                }
            }

            for (node.children.items) |child| {
                try self.validateNode(child, false, depth + 1, leaf_depth, previous_key);
            }
        }
    };
}

test "B+ tree inserts, splits, and looks up values" {
    const Tree = BPlusTree(i32, i32, 3);

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.put(10, 100);
    try tree.put(20, 200);
    try tree.put(5, 50);
    try tree.put(6, 60);
    try tree.put(12, 120);
    try tree.put(30, 300);
    try tree.put(7, 70);
    try tree.put(17, 170);

    try std.testing.expectEqual(@as(?i32, 100), tree.get(10));
    try std.testing.expectEqual(@as(?i32, 60), tree.lookup(6));
    try std.testing.expect(tree.contains(30));
    try std.testing.expect(!tree.contains(999));
    try tree.validate();
}

test "B+ tree upserts duplicate keys" {
    const Tree = BPlusTree(i32, i32, 4);

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.insert(42, 1);
    try tree.insert(42, 2);
    try tree.insert(42, 3);

    try std.testing.expectEqual(@as(?i32, 3), tree.get(42));

    var iter = tree.iterator();
    const entry = iter.next().?;
    try std.testing.expectEqual(@as(i32, 42), entry.key);
    try std.testing.expectEqual(@as(i32, 3), entry.value);
    try std.testing.expect(iter.next() == null);
    try tree.validate();
}

test "B+ tree iterates in sorted order and supports range scans" {
    const Tree = BPlusTree(i32, i32, 3);

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const values = [_]i32{ 40, 10, 30, 20, 50, 60, 70, 80 };
    for (values, 0..) |key, index| {
        try tree.put(key, @as(i32, @intCast(index)));
    }

    var iter = tree.iterator();
    var expected_key: i32 = 10;
    while (iter.next()) |entry| {
        try std.testing.expectEqual(expected_key, entry.key);
        expected_key += 10;
    }
    try std.testing.expectEqual(@as(i32, 90), expected_key);

    var range = tree.rangeIterator(25, 65);
    const expected = [_]i32{ 30, 40, 50, 60 };
    var index: usize = 0;
    while (range.next()) |entry| {
        try std.testing.expectEqual(expected[index], entry.key);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
    try tree.validate();
}

test "B+ tree deletes keys, rebalances, and exposes page stats" {
    const Tree = BPlusTree(i32, i32, 4);

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const keys = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    for (keys) |key| {
        try tree.put(key, key * 10);
    }

    const stats = tree.pageStats();
    try std.testing.expectEqual(@as(usize, 64), stats.nodes_per_page);
    try std.testing.expect(stats.pages >= 1);

    try std.testing.expect(try tree.delete(3));
    try std.testing.expect(try tree.delete(4));
    try std.testing.expect(try tree.delete(5));
    try std.testing.expect(try tree.delete(6));
    try std.testing.expect(!tree.contains(4));
    try std.testing.expectEqual(@as(?i32, null), tree.get(4));
    try tree.validate();
}

test "B+ tree delete collapses the root when empty" {
    const Tree = BPlusTree(i32, i32, 3);

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.put(10, 100);
    try tree.put(20, 200);

    try std.testing.expect(try tree.delete(10));
    try std.testing.expect(try tree.delete(20));
    try std.testing.expect(tree.root == null);
    try tree.validate();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const Tree = BPlusTree(i32, i32, 3);
    var tree = Tree.init(allocator);
    defer tree.deinit();

    try tree.put(10, 100);
    try tree.put(20, 200);
    try tree.put(5, 50);
    try tree.put(6, 60);
    try tree.put(12, 120);

    std.debug.print("B+ tree contents:\n", .{});
    var iter = tree.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{d} -> {d}\n", .{ entry.key, entry.value });
    }
}
