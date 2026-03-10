const std = @import("std");
const Allocator = std.mem.Allocator;

// Binary Search Tree:
// - Top of the tree is called root
// - Binary-Search Tree Property: Let x be a node in a BST. If y is a node in the left subtree of x, then y.data <= x.data. If y is a node in the right subtree of x, then y.data > x.data
// - Height of tree is O(log n) in best case scenrio and O(n) in worst case
// - Search: O(h)
// - Insertion: O(h)

pub const Node = struct {
    data: i32,
    left: ?*Node = null,
    right: ?*Node = null,

    pub fn init(data: i32) Node {
        return Node{
            .data = data,
        };
    }

    pub fn lookup(self: *const Node, value: i32) ?*const Node {
        var current: ?*const Node = self;
        while (current) |node| {
            if (node.data == value) return node;
            current = if (node.data < value) node.right else node.left;
        }
        return null;
    }
};

pub const BinarySearchTree = struct {
    root: ?*Node = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) BinarySearchTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BinarySearchTree) void {
        if (self.root) |r| {
            self.destroyRecursive(r);
        }
        self.root = null;
    }

    fn destroyRecursive(self: *BinarySearchTree, node: *Node) void {
        if (node.left) |left| self.destroyRecursive(left);
        if (node.right) |right| self.destroyRecursive(right);
        self.allocator.destroy(node);
    }

    pub fn insert(self: *BinarySearchTree, value: i32) !void {
        if (self.root) |root_node| {
            try self.insertRecursive(root_node, value);
        } else {
            self.root = try self.createNewNode(value);
        }
    }

    fn createNewNode(self: *BinarySearchTree, value: i32) !*Node {
        const new_node = try self.allocator.create(Node);
        new_node.* = .{ .data = value };
        return new_node;
    }

    fn insertRecursive(self: *BinarySearchTree, current: *Node, value: i32) !void {
        if (value < current.data) {
            if (current.left) |left| {
                try self.insertRecursive(left, value);
            } else {
                current.left = try self.createNewNode(value);
            }
        } else {
            if (current.right) |right| {
                try self.insertRecursive(right, value);
            } else {
                current.right = try self.createNewNode(value);
            }
        }
    }

    pub fn search(self: *const BinarySearchTree, value: i32) ?*const Node {
        if (self.root) |r| {
            return r.lookup(value);
        }
        return null;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var bst = BinarySearchTree.init(allocator);
    defer bst.deinit();

    try bst.insert(50);
    try bst.insert(25);
    try bst.insert(75);

    std.debug.print("Search for 25: {any}\n", .{bst.search(25)});
}
