const std = @import("std");
const Allocator = std.mem.Allocator;

// AVL Tree:
// - Height = log_2 (N), where N = total number of nodes in tree
// - Difference in height between the two subtrees is not greater than one
// - Following the left or right pointer reduces the search space in half

pub const Node = struct {
    data: i32,
    height: i32 = 1,
    left: ?*Node = null,
    right: ?*Node = null,
};

pub const AVLTree = struct {
    root: ?*Node = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) AVLTree {
        return .{ .allocator = allocator };
    }

    fn getHeight(node: ?*Node) i32 {
        return if (node) |n| n.height else 0;
    }

    fn updateHeight(node: *Node) void {
        const leftH = getHeight(node.left);
        const rightH = getHeight(node.right);
        node.height = @max(leftH, rightH) + 1;
    }

    fn getBalance(node: ?*Node) i32 {
        if (node) |n| {
            return getHeight(n.left) - getHeight(n.right);
        }
        return 0;
    }

    fn rightRotate(y: *Node) *Node {
        const x = y.left.?;
        const T2 = x.right;

        x.right = y;
        y.left = T2;

        updateHeight(y);
        updateHeight(x);

        return x;
    }

    fn leftRotate(x: *Node) *Node {
        const y = x.right.?;
        const T2 = y.left;

        y.left = x;
        x.right = T2;

        updateHeight(x);
        updateHeight(y);

        return y;
    }

    pub fn insert(self: *AVLTree, value: i32) !void {
        self.root = try self.insertRecursive(self.root, value);
    }

    fn insertRecursive(self: *AVLTree, node: ?*Node, value: i32) !*Node {
        const current = node orelse {
            const newNode = try self.allocator.create(Node);
            newNode.* = .{ .data = value };
            return newNode;
        };

        if (value < current.data) {
            current.left = try self.insertRecursive(current.left, value);
        } else if (value > current.data) {
            current.right = try self.insertRecursive(current.right, value);
        } else {
            return current;
        }

        updateHeight(current);

        const balance = getBalance(current);

        // Left Left Case
        if (balance > 1 and value < current.left.?.data) {
            return rightRotate(current);
        }

        // Right Right Case
        if (balance < -1 and value > current.right.?.data) {
            return leftRotate(current);
        }

        // Left Right Case
        if (balance > 1 and value > current.left.?.data) {
            current.left = leftRotate(current.left.?);
            return rightRotate(current);
        }

        // Right Left Case
        if (balance < -1 and value < current.right.?.data) {
            current.right = rightRotate(current.right.?);
            return leftRotate(current);
        }

        return current;
    }

    fn getMinValueNode(node: *Node) *Node {
        var current = node;
        while (current.left) |left| {
            current = left;
        }
        return current;
    }

    pub fn delete(self: *AVLTree, value: i32) void {
        self.root = self.deleteRecursive(self.root, value);
    }

    fn deleteRecursive(self: *AVLTree, node: ?*Node, value: i32) ?*Node {
        const current = node orelse return null;

        if (value < current.data) {
            current.left = self.deleteRecursive(current.left, value);
        } else if (value > current.data) {
            current.right = self.deleteRecursive(current.right, value);
        } else {
            if (current.left == null) {
                const temp = current.right;
                self.allocator.destroy(current);
                return temp;
            } else if (current.right == null) {
                const temp = current.left;
                self.allocator.destroy(current);
                return temp;
            }

            // Node with two children: Get inorder successor (smallest in right subtree)
            const temp = getMinValueNode(current.right.?);
            current.data = temp.data; // Copy successor's data
            current.right = self.deleteRecursive(current.right, temp.data);
        }

        updateHeight(current);

        const balance = getBalance(current);

        // Left Left Case
        if (balance > 1 and getBalance(current.left) >= 0) {
            return rightRotate(current);
        }

        // Left Right Case
        if (balance > 1 and getBalance(current.left) < 0) {
            current.left = leftRotate(current.left.?);
            return rightRotate(current);
        }

        // Right Right Case
        if (balance < -1 and getBalance(current.right) <= 0) {
            return leftRotate(current);
        }

        // Right Left Case
        if (balance < -1 and getBalance(current.right) > 0) {
            current.right = rightRotate(current.right.?);
            return leftRotate(current);
        }

        return current;
    }

    pub fn search(self: *const AVLTree, value: i32) ?*Node {
        var current = self.root;
        while (current) |node| {
            if (value == node.data) return node;
            current = if (value < node.data) node.left else node.right;
        }
        return null;
    }

    pub fn print(self: *const AVLTree) void {
        if (self.root == null) {
            std.debug.print("Empty tree\n", .{});
            return;
        }
        self.printHelper(self.root, 0);
    }

    fn printHelper(self: *const AVLTree, node: ?*Node, depth: usize) void {
        if (node) |n| {
            self.printHelper(n.right, depth + 1);
            for (0..depth) |_| {
                std.debug.print("      ", .{});
            }
            std.debug.print("{d}(h:{d})\n", .{ n.data, n.height });
            self.printHelper(n.left, depth + 1);
        }
    }

    pub fn deinit(self: *AVLTree) void {
        self.destroyRecursive(self.root);
        self.root = null;
    }

    fn destroyRecursive(self: *AVLTree, node: ?*Node) void {
        if (node) |n| {
            self.destroyRecursive(n.left);
            self.destroyRecursive(n.right);
            self.allocator.destroy(n);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var avl = AVLTree.init(allocator);
    defer avl.deinit();

    std.debug.print("=== AVL TREE DEMONSTRATION ===\n", .{});

    const inserts = [_]i32{ 10, 20, 30 };
    for (inserts) |val| {
        std.debug.print("\n>>> Inserting {d}\n", .{val});
        try avl.insert(val);
        avl.print();
    }

    std.debug.print("\n>>> Inserting 25\n", .{});
    try avl.insert(25);
    avl.print();

    std.debug.print("\n>>> Inserting 5\n", .{});
    try avl.insert(5);
    avl.print();

    std.debug.print("\n>>> Deleting 10\n", .{});
    avl.delete(10);
    avl.print();

    std.debug.print("\n>>> Searching for 25...\n", .{});
    if (avl.search(25)) |n| {
        std.debug.print("Found! Node data: {d}, Node height: {d}\n", .{ n.data, n.height });
    } else {
        std.debug.print("Not found.\n", .{});
    }
}
