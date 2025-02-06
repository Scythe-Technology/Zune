--!strict
--!native
--!optimize 2

local mem = {};

--[=[
    Copies a slice of a buffer into a buffer.

    ```luau
    local b = buffer.fromstring("Hello")
    local slice = mem.sliceOwned(b, 2, 2)
    print(buffer.tostring(slice)) -- "ll"
    ```

    @param target The buffer to copy from.
    @param offset The first byte to copy.
    @param count The number of bytes to copy.
    @return `buffer` The new buffer.
]=]
function mem.sliceOwned(target: buffer, offset: number, count: number?): buffer
    local len = if (count) then count else buffer.len(target) - offset;
    local buf = buffer.create(len);
    buffer.copy(buf, 0, target, offset, count);
    return buf;
end

--[=[
    Reverses the bytes in a buffer in place.

    ```luau
    local b = buffer.fromstring("Hello")
    mem.reverse(b, 0, 5)
    print(buffer.tostring(b)) -- "olleH"
    ```

    @param target The buffer to reverse.
    @param offset The offset to start reversing from.
    @param count The number of bytes to reverse.
]=]
function mem.reverse(target: buffer, offset: number, count: number): ()
    local half = count // 2;
    local m1 = count - 1;
    for i = 0, half - 1 do
        local a = offset + i
        local b = offset + m1 - i
        local temp_a = buffer.readu8(target, a);
        local temp_b = buffer.readu8(target, b);
        buffer.writeu8(target, a, temp_b);
        buffer.writeu8(target, b, temp_a);
    end
end

--[=[
    Joins multiple buffers into a new buffer.

    ```luau
    local b = {
        buffer.fromstring("Hello"),
        buffer.fromstring("World!")
    }
    local joined = mem.joinOwned(buffer.fromstring(", "), b)
    print(buffer.tostring(joined)) -- "Hello, World!"
    ```

    @param separator The buffer to join the buffers with.
    @param buffers The buffers to join.
    @return `buffer` The new buffer.
]=]
function mem.joinOwned(separator: buffer?, buffers: {buffer}): buffer
    local size = 0;
    local buffers_len = #buffers;
    for i = 1, buffers_len, 1 do
        size += buffer.len(buffers[i]);
    end
    local separator_len = 0;
    if (separator) then
        separator_len = buffer.len(separator);
        if (buffers_len > 1) then
            size += (buffers_len - 1) * separator_len;
        end
    end
    local buf = buffer.create(size);
    local offset = 0;
    for i = 1, buffers_len, 1 do
        local b = buffers[i];
        local len = buffer.len(b);
        buffer.copy(buf, offset, b, 0, len);
        offset += len;
        if (separator_len > 0 and i < buffers_len) then
            buffer.copy(buf, offset, separator::buffer, 0, separator_len);
            offset += separator_len;
        end
    end
    return buf;
end

return mem;
