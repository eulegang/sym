const std = @import("std");

pub const Error = error{ InputTooLarge, InvalidId } || std.mem.Allocator.Error;

const Span = struct {
    iteration: usize,
    start: usize,
    end: usize,
};

const Blk = struct {
    const CAPACITY: usize = 0x1000;

    buffer: []u8,
    len: usize,
    next: ?*Blk,

    fn free(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.next) |sub| {
            sub.free(alloc);
            alloc.destroy(sub);
        }

        alloc.free(self.buffer);
    }
};

const SpanBlk = struct {
    const CAPACITY: usize = 32;

    buffer: []Span,
    len: usize,
    next: ?*SpanBlk,

    fn push(self: *@This(), span: Span, alloc: std.mem.Allocator) !void {
        var s = self;
        while (s.next) |sub| {
            s = sub;
        }

        if (s.len < @This().CAPACITY) {
            s.buffer[s.len] = span;
            s.len += 1;
        } else {
            var next = try alloc.create(@This());
            next.buffer[0] = span;
            next.len = 1;
            next.next = null;

            s.next = next;
        }
    }

    fn free(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.next) |sub| {
            sub.free(alloc);
            alloc.destroy(sub);
        }

        alloc.free(self.buffer);
    }
};

pub const Symbols = struct {
    alloc: std.mem.Allocator,
    blk: *Blk,
    spans: *SpanBlk,

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const blk = try alloc.create(Blk);
        blk.buffer = try alloc.alloc(u8, Blk.CAPACITY);
        blk.len = 0;
        blk.next = null;

        const spans = try alloc.create(SpanBlk);
        spans.buffer = try alloc.alloc(Span, SpanBlk.CAPACITY);
        spans.len = 0;
        spans.next = null;

        return @This(){
            .alloc = alloc,
            .blk = blk,
            .spans = spans,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.blk.free(self.alloc);
        self.spans.free(self.alloc);

        self.alloc.destroy(self.blk);
        self.alloc.destroy(self.spans);
    }

    pub fn intern(self: *@This(), name: []const u8) Error!usize {
        if (name.len > Blk.CAPACITY) {
            return Error.InputTooLarge;
        }

        var i: usize = 0;

        var sblk = self.spans;
        var sblk_i: usize = 0;

        var cblk: *Blk = self.blk;
        var cblk_i: usize = 0;

        while (true) {
            while (sblk_i < sblk.len) {
                var span = sblk.buffer[i];

                while (cblk_i < span.iteration) {
                    if (cblk.next) |sub| {
                        cblk_i += 1;
                        cblk = sub;
                    } else {
                        unreachable;
                    }
                }

                if ((span.end - span.start) == name.len) {
                    const content = cblk.buffer[span.start..span.end];

                    if (std.mem.eql(u8, content, name)) {
                        return i;
                    }
                }

                i += 1;
                sblk_i += 1;
            }

            if (sblk.next) |sub| {
                sblk = sub;
                sblk_i = 0;
            } else {
                break;
            }
        }

        while (cblk.next) |sub| {
            cblk = sub;
            cblk_i += 1;
        }

        if (name.len < Blk.CAPACITY - cblk.len) {
            const start = cblk.len;
            const end = cblk.len + name.len;

            @memcpy(cblk.buffer[start..end], name);

            const span = Span{ .start = start, .end = end, .iteration = cblk_i };
            try sblk.push(span, self.alloc);

            cblk.len = end;
        } else {
            const next = try self.alloc.create(Blk);
            next.buffer = try self.alloc.alloc(u8, Blk.CAPACITY);
            next.len = name.len;
            next.next = null;

            @memcpy(next.buffer[0..name.len], name);

            cblk.next = next;
        }

        return i;
    }

    pub fn resolve(self: *@This(), id: usize) Error![]const u8 {
        var jumps: usize = id / SpanBlk.CAPACITY;
        var sblk = self.spans;

        while (jumps > 0) {
            if (sblk.next) |sub| {
                sblk = sub;
            } else {
                return Error.InvalidId;
            }

            jumps -= 1;
        }

        var i = id % SpanBlk.CAPACITY;
        if (i >= sblk.len) {
            return Error.InvalidId;
        }

        var span = sblk.buffer[i];

        var cblk = self.blk;
        jumps = span.iteration;

        while (jumps > 0) {
            if (cblk.next) |sub| {
                cblk = sub;
            } else {
                return Error.InvalidId;
            }

            jumps -= 1;
        }

        return cblk.buffer[span.start..span.end];
    }
};

test "symbols" {
    var alloc = std.testing.allocator_instance.allocator();
    var symbols = try Symbols.init(alloc);
    defer symbols.deinit();

    const hello = try symbols.intern("hello");
    const world = try symbols.intern("world");
    const welt = try symbols.intern("world");

    try std.testing.expectEqualSlices(u8, try symbols.resolve(hello), "hello");
    try std.testing.expectEqualSlices(u8, try symbols.resolve(world), "world");
    try std.testing.expectEqualSlices(u8, try symbols.resolve(welt), "world");

    try std.testing.expectEqual(world, welt);
}
