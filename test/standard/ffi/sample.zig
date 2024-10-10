const std = @import("std");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn add_ptr(a_ptr: *i32, b: i32) void {
    a_ptr.* += b;
}

export fn add_ptr_ptr(a_ptr_ptr: **i32, b: i32) void {
    a_ptr_ptr.*.* += b;
}

export fn new_i32() *i32 {
    const ptr = std.heap.page_allocator.create(i32) catch @panic("allocation failed");
    ptr.* = 123;
    return ptr;
}
export fn free_i32(ptr: *i32) void {
    std.heap.page_allocator.destroy(ptr);
}

test add {
    const result = add(1, 2);
    try std.testing.expect(result == 3);
}
