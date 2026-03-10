const std = @import("std");
const Allocator = std.mem.Allocator;
// Red Black Trees:
// - balanced binary search tree
// - ensures height is logarithmitc in n
// - All operations run in O(log n) time
// - red-black trees ensure that no simple path from root to leaf is more than twice as long as any other path
//
// Red Black Tree Properties:
// - Every node has a color (red or black)
// - The root is black
// - Every leaf is black
// - If a node is red then both its children are black
// - For each node, all simple paths from the node to descendant leaves contain the same number of black nodes

pub const Color = enum {
    red,
    black,
};

pub const RedBlackNode = struct {
    data: i32,
    left: ?*RedBlackNode = null,
    right: ?*RedBlackNode = null,
    parent: ?*RedBlackNode = null,
    color: Color,
};

pub const RedBlackTree = struct {
    root: ?*RedBlackNode = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) RedBlackTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RedBlackTree) void {
        if (self.root) |r| {
            self.destroyRecursive(r);
        }
        self.root = null;
    }

    fn destroyRecursive(self: *RedBlackTree, node: *RedBlackNode) void {
        if (node.left) |left| self.destroyRecursive(left);
        if (node.right) |right| self.destroyRecursive(right);
        self.allocator.destroy(node);
    }

    pub fn insert(self: *RedBlackTree, value: i32) !void {
        var current = self.root;
        var parent: ?*RedBlackNode = null;
        while (current) |node| {
            parent = node;
            if (value < node.data) {
                current = node.left;
            } else if (value > node.data) {
                current = node.right;
            } else {
                return;
            }
        }

        const newNode = try self.createNewNode(value, .red, parent);

        if (parent) |p| {
            if (p.data < value) {
                p.right = newNode;
            } else {
                p.left = newNode;
            }
        } else {
            self.root = newNode;
        }

        self.fixRedBlackProp(newNode);
    }

    fn fixRedBlackProp(self: *RedBlackTree, new_node: *RedBlackNode) void {
        var current = new_node;

        while (current.parent != null and current.parent.?.color == .red) {
            var p = current.parent.?;
            const g = p.parent.?;

            if (p == g.left) {
                const s = g.right;
                const isBlack = if (s) |u| u.color == .black else true;

                if (!isBlack) {
                    p.color = .black;
                    s.?.color = .black;
                    g.color = .red;
                    current = g; // Bubble up
                } else {
                    if (current == p.right) {
                        current = p;
                        self.leftRotate(current);
                        p = current.parent.?; // Update p after rotation
                    }

                    p.color = .black;
                    g.color = .red;
                    self.rightRotate(g);
                }
            } else {
                const s = g.left;
                const isBlack = if (s) |u| u.color == .black else true;

                if (!isBlack) {
                    // CASE 1: s is RED
                    p.color = .black;
                    s.?.color = .black;
                    g.color = .red;
                    current = g; // Bubble up
                } else {
                    // CASE 2: Triangle (Right-Left)
                    if (current == p.left) {
                        current = p;
                        self.rightRotate(current);
                        p = current.parent.?; // Update p after rotation
                    }

                    // CASE 3: Line (Right-Right)
                    p.color = .black;
                    g.color = .red;
                    self.leftRotate(g);
                }
            }
        }

        if (self.root) |r| {
            r.color = .black;
        }
    }

    fn leftRotate(self: *RedBlackTree, x: *RedBlackNode) void {
        const y = x.right orelse return;

        x.right = y.left;
        if (y.left) |y_left| {
            y_left.parent = x;
        }

        y.parent = x.parent;
        if (x.parent) |x_parent| {
            if (x == x_parent.left) {
                x_parent.left = y;
            } else {
                x_parent.right = y;
            }
        } else {
            self.root = y;
        }

        y.left = x;
        x.parent = y;
    }

    fn rightRotate(self: *RedBlackTree, y: *RedBlackNode) void {
        const x = y.left orelse return;

        y.left = x.right;
        if (x.right) |x_right| {
            x_right.parent = y;
        }

        x.parent = y.parent;
        if (y.parent) |y_parent| {
            if (y == y_parent.left) {
                y_parent.left = x;
            } else {
                y_parent.right = x;
            }
        } else {
            self.root = x;
        }

        x.right = y;
        y.parent = x;
    }

    fn createNewNode(self: *RedBlackTree, value: i32, color: Color, parent: ?*RedBlackNode) !*RedBlackNode {
        const newNode = try self.allocator.create(RedBlackNode);
        newNode.* = .{ .data = value, .color = color, .parent = parent };
        return newNode;
    }

    pub fn print(self: *const RedBlackTree) void {
        if (self.root == null) {
            std.debug.print("Empty tree\n", .{});
            return;
        }
        self.printHelper(self.root, 0);
    }

    fn printHelper(self: *const RedBlackTree, node: ?*RedBlackNode, depth: usize) void {
        if (node) |n| {
            // 1. Go to the rightmost node
            self.printHelper(n.right, depth + 1);

            // 2. Print the current node with indentation based on depth
            for (0..depth) |_| {
                std.debug.print("      ", .{}); // 6 spaces for readability
            }
            const color_char = if (n.color == .red) "R" else "B";
            std.debug.print("{d}({s})\n", .{ n.data, color_char });

            // 3. Go to the leftmost node
            self.printHelper(n.left, depth + 1);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var rb_tree = RedBlackTree.init(allocator);
    defer rb_tree.deinit();

    const values = [_]i32{ 10, 20, 30, 15 };

    for (values) |val| {
        std.debug.print("\n========================\n", .{});
        std.debug.print(" Inserting {d}...\n", .{val});
        std.debug.print("========================\n", .{});

        try rb_tree.insert(val);
        rb_tree.print();
    }

    std.debug.print("Tree created and balanced successfully! Root is: {d}\n", .{rb_tree.root.?.data});
}
