const std = @import("std");
const assert = @import("std").debug.assert;

const AllocationError = error{ FailedToGetPageSize, FailedToMapMemory };
const MemoryFreeError = error{ AlreadyFree, FailedToUnmapMemory };

pub const Allocator = struct {
    head: ?*Map,

    pub fn init() Allocator {
        return Allocator{ .head = null };
    }

    /// Todo: Return an error.
    pub fn alloc(self: *Allocator, size: usize) AllocationError!*anyopaque {
        if (self.head == null) {
            self.head = try Map.init(size, null, null);
        }

        // Todo: Allocate memory.
        return self.head.?.head.get_user_ptr();
    }

    pub fn free(self: *Allocator, ptr: *anyopaque) MemoryFreeError!void {
        _ = self;

        const chunk_ptr: *Chunk = Chunk.dereference_user_ptr(ptr);
        if (chunk_ptr.isFree) {
            return MemoryFreeError.FailedToUnmapMemory;
        }
        chunk_ptr.isFree = true;
        // Todo: Free up the chunk.
    }
};

/// Represents a single memory mapping.
/// This can form a doubly linked list to other memory maps.
const Map = struct {
    /// The size of the memory map.
    size: usize,
    /// The head chunk.
    head: *Chunk,
    /// The next memory map.
    next: *Map,
    /// The previous memory map.
    prev: *Map,

    /// Map the required memory.
    pub fn init(requested_size: usize, next: ?*Map, prev: ?*Map) AllocationError!*Map {
        // Calculate the number of pages required.
        const required_size = requested_size + @sizeOf(Map) + @sizeOf(Chunk);
        var pages: usize = required_size / std.heap.page_size_max;
        if (pages == 0) {
            pages = 1;
        } else if (required_size % std.heap.page_size_max > 0) {
            pages += 1;
        }
        const new_size: usize = pages * std.heap.page_size_max;

        const result: usize = std.os.linux.mmap(
            null,
            new_size,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{
                .TYPE = std.os.linux.MAP_TYPE.PRIVATE,
                .ANONYMOUS = true,
            },
            -1,
            0,
        );
        if (result == std.math.maxInt(usize)) {
            // Todo: Handle errno.
            // const errno = std.posix.errno(result);
            return AllocationError.FailedToMapMemory;
        }

        // Create a new head chunk.
        const new_chunk: *Chunk = @ptrFromInt(result + @sizeOf(Map));
        new_chunk.size = new_size - @sizeOf(Map) - @sizeOf(Chunk);
        new_chunk.isFree = false;
        new_chunk.next = new_chunk;
        new_chunk.prev = new_chunk;

        var buffer: [256]u8 = undefined;
        const res = new_chunk.to_string(&buffer);
        if (res) |msg| {
            std.log.err("{s}\n", .{msg});
        } else |err| {
            std.log.err("Failed to log chunk: {}\n", .{err});
        }

        // Create new map metadata.
        const new_map: *Map = @ptrFromInt(result);
        new_map.size = new_size;
        new_map.head = new_chunk;
        new_map.next = next orelse new_map;
        new_map.prev = prev orelse new_map;

        return new_map;
    }

    /// Unmap the memory.
    pub fn deinit(self: *Map) AllocationError!void {
        const result: usize = std.os.linux.munmap(self, self.size);
        if (result == std.math.maxInt(usize)) {
            // Todo: Handle errno.
            return MemoryFreeError.FailedToUnmapMemory;
        }
        // Remove from the doubly linked list.
        if (self.next != self) {
            self.next.prev = self.prev;
        }
        if (self.prev != self) {
            self.prev.next = self.next;
        }
    }

    pub fn alloc(self: *Map) AllocationError!void {
        _ = self;
    }
};

/// Represents a single chunked memory allocation.
/// This can form a doubly linked list to other chunks.
const Chunk = struct {
    /// The space available to the user. This does not include the struct itself.
    size: usize,
    /// Whether the chunk is free for allocation.
    isFree: bool,
    /// The parent map. Required in order to free the map.
    parent: *Map,
    /// The next chunk.
    next: *Chunk,
    /// The previous chunk.
    prev: *Chunk,

    /// Get a pointer to the user space associated with this chunk.
    pub fn get_user_ptr(self: *Chunk) *anyopaque {
        return @ptrCast(@as([*]u8, @ptrCast(self)) + @sizeOf(Chunk));
    }

    /// Get a pointer to chunk metadata from a user space pointer.
    pub fn dereference_user_ptr(ptr: *anyopaque) *Chunk {
        //const byte_ptr: [*]u8 = @ptrCast(ptr);
        const new_ptr: [*]u8 = @as([*]u8, @ptrCast(ptr)) - @sizeOf(Chunk);
        return @ptrCast(@alignCast(new_ptr));
    }

    /// Free up this chunk, coalescing with any adjecent chunks.
    pub fn free(self: *Chunk) MemoryFreeError!void {
        _ = self;
    }

    /// Populate the given buffer with chunk metadata.
    pub fn to_string(self: *const Chunk, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(
            buf,
            "{*}, size = {}, isFree = {}, next = {*}, prev = {*}",
            .{ self, self.size, self.isFree, self.next, self.prev },
        );
    }

    /// 
    fn coalesce(self: *Chunk) void {
        if (self.prev.isFree) {
            self.prev.size += self.size + @sizeOf(Chunk);
            self.prev.next = self.next;
            self = self.prev;
        }
        if (self.next.isFree) {
            self.size += self.next.size + @sizeOf(Chunk);
            self.next = self.next.next;
        }
    }
};
