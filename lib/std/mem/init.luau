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
function mem.reverse(target: buffer, offset: number, count: number?): ()
    local len = if (count) then count else buffer.len(target) - offset;
    local half = len // 2;
    local m1 = len - 1;
    for i = 0, half - 1 do
        local a = offset + i
        local b = offset + m1 - i
        local temp = buffer.readu8(target, a)
        buffer.writeu8(target, a, buffer.readu8(target, b))
        buffer.writeu8(target, b, temp)
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

--[=[
    Compares two slices of buffers.

    ```luau
    local a = buffer.fromstring("Hello")
    local b = buffer.fromstring("World")
    print(mem.eqlSlice(a, 0, b, 0, 5)) -- false
    ```

    @param a The first buffer.
    @param offset1 The offset to start comparing from for `a`.
    @param b The second buffer.
    @param offset2 The offset to start comparing from for `b`.
    @param count The number of bytes to compare.
    @return `boolean` Whether the slices are equal.
]=]
function mem.eqlSlice(
    a: buffer, offset1: number,
    b: buffer, offset2: number, count: number?
): boolean
    local len = 0;
    if (count) then
        len = count;
    else
        local lenA = buffer.len(a) - offset1;
        local lenB = buffer.len(b) - offset2;
        if (lenA ~= lenB) then
            return false;
        end
        len = lenA;
    end
    if (len == 0) then
        return true;
    end
    if (len > 3) then
        -- fast path: chunk (len >= 4)
        for i = 0, (((len - 1)//4) - 1) * 4, 4 do
            if (buffer.readu32(a, offset1 + i) ~= buffer.readu32(b, offset2 + i)) then
                return false;
            end
        end
        -- eql overlapped
        return buffer.readu32(a, offset1 + len - 4) == buffer.readu32(b, offset2 + len - 4);
    else
        -- slow path: byte by byte (len < 4)
        for i = 0, len - 1, 1 do
            if (buffer.readu8(a, offset1 + i) ~= buffer.readu8(b, offset2 + i)) then
                return false;
            end
        end
    end
    return true;
end

--[=[
    Compares two buffers.

    ```luau
    local a = buffer.fromstring("Hello")
    local b = buffer.fromstring("World")
    print(mem.eql(a, b)) -- false
    ```

    @param a The first buffer.
    @param b The second buffer.
    @return `boolean` Whether the buffers are equal.
]=]
function mem.eql(a: buffer, b: buffer): boolean
    return mem.eqlSlice(a, 0, b, 0);
end

--[=[
    Checks if a buffer starts with a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.startsWith(a, buffer.fromstring("He"))) -- true
    ```

    @param haystack The buffer to check.
    @param needle The slice to check for.
    @return `boolean` Whether the buffer starts with the slice.
]=]
function mem.startsWith(haystack: buffer, needle: buffer): boolean
    local len = buffer.len(haystack);
    local needle_len = buffer.len(needle);
    if (needle_len == 0) then
        return true;
    end
    if (len < needle_len) then
        return false;
    end
    return mem.eqlSlice(haystack, 0, needle, 0, needle_len);
end

--[=[
    Checks if a buffer ends with a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.endsWith(a, buffer.fromstring("lo"))) -- true
    ```

    @param haystack The buffer to check.
    @param needle The slice to check for.
    @return `boolean` Whether the buffer ends with the slice.
]=]
function mem.endsWith(haystack: buffer, needle: buffer): boolean
    local len = buffer.len(haystack);
    local needle_len = buffer.len(needle);
    if (needle_len == 0) then
        return true;
    end
    if (len < needle_len) then
        return false;
    end
    return mem.eqlSlice(
        haystack, len - needle_len,
        needle, 0, needle_len
    );
end

--[=[
    Finds the first index of a character in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.indexOfChar(a, 101)) -- 1
    ```

    @param haystack The buffer to search.
    @param value The character to search for.
    @return `number?` The index of the character, or `nil` if not found.
]=]
function mem.indexOfCharAt(haystack: buffer, offset: number, value: number): number?
    local len = buffer.len(haystack);
    if (len == 0) then
        return nil;
    end
    for i = offset, len - 1, 1 do
        if (buffer.readu8(haystack, i) == value) then
            return i;
        end
    end
    return nil;
end

--[=[
    Finds the first index of a buffer in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.indexOf(a, buffer.fromstring("ll"))) -- 2
    ```

    @param haystack The buffer to search.
    @param needle The slice to search for.
    @return `number?` The index of the slice, or `nil` if not found.
]=]
function mem.indexOfAt(haystack: buffer, offset: number, needle: buffer): number?
    local len = buffer.len(haystack);
    local needle_len = buffer.len(needle);
    if (needle_len == 0) then
        return offset;
    end
    if (len == 0) then
        return nil;
    end
    for i = offset, len - needle_len, 1 do
        if (mem.eqlSlice(haystack, i, needle, 0, needle_len)) then
            return i;
        end
    end
    return nil;
end

--[=[
    Finds the last index of a character in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.lastIndexOfChar(a, 101)) -- 1
    ```

    @param haystack The buffer to search.
    @param value The character to search for.
    @return `number?` The index of the character, or `nil` if not found.
]=]
function mem.lastIndexOfCharAt(haystack: buffer, offset: number, value: number): number?
    local len = buffer.len(haystack);
    if (len == 0) then
        return nil;
    end
    for i = len - 1, offset, -1 do
        if (buffer.readu8(haystack, i) == value) then
            return i;
        end
    end
    return nil;
end

--[=[
    Finds the last index of a buffer in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.lastIndexOf(a, buffer.fromstring("ll"))) -- 2
    ```

    @param haystack The buffer to search.
    @param needle The slice to search for.
    @return `number?` The index of the slice, or `nil` if not found.
]=]
function mem.lastIndexOfAt(haystack: buffer, offset: number, needle: buffer): number?
    local len = buffer.len(haystack);
    local needle_len = buffer.len(needle);
    if (needle_len == 0) then
        return len;
    end
    if (len == 0) then
        return nil;
    end
    local max = len - needle_len;
    for i = max, offset, -1 do
        if (mem.eqlSlice(haystack, i, needle, 0, needle_len)) then
            return i;
        end
    end
    return nil;
end

--[=[
    Finds the first index of a character in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.indexOfChar(a, 101)) -- 1
    ```

    @param haystack The buffer to search.
    @param value The character to search for.
    @return `number?` The index of the character, or `nil` if not found.
]=]
function mem.indexOfChar(haystack: buffer, char: number): number?
    return mem.indexOfCharAt(haystack, 0, char);
end

--[=[
    Finds the first index of a buffer in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.indexOf(a, buffer.fromstring("ll"))) -- 2
    ```

    @param haystack The buffer to search.
    @param needle The slice to search for.
    @return `number?` The index of the slice, or `nil` if not found.
]=]
function mem.indexOf(haystack: buffer, needle: buffer): number?
    return mem.indexOfAt(haystack, 0, needle);
end

--[=[
    Finds the last index of a character in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.lastIndexOfChar(a, 101)) -- 1
    ```

    @param haystack The buffer to search.
    @param value The character to search for.
    @return `number?` The index of the character, or `nil` if not found.
]=]
function mem.lastIndexOfChar(haystack: buffer, char: number): number?
    return mem.lastIndexOfCharAt(haystack, 0, char);
end

--[=[
    Finds the last index of a buffer in a buffer.

    ```luau
    local a = buffer.fromstring("Hello")
    print(mem.lastIndexOf(a, buffer.fromstring("ll"))) -- 2
    ```

    @param haystack The buffer to search.
    @param needle The slice to search for.
    @return `number?` The index of the slice, or `nil` if not found.
]=]
function mem.lastIndexOf(haystack: buffer, needle: buffer): number?
    return mem.lastIndexOfAt(haystack, 0, needle);
end

--[=[
    Trims a buffer from the left.

    ```luau
    local a = buffer.fromstring("  Hello  ")
    print(buffer.tostring(mem.trimLeft(a, buffer.fromstring(" ")))) -- "Hello  "
    ```

    @param target The buffer to trim.
    @param chars The characters to trim.
    @return `buffer` The trimmed buffer.
]=]
function mem.trimLeft(target: buffer, chars: buffer): buffer
    local front = 0;
    local len = buffer.len(target);
    while (front < len) do
        if (mem.indexOfCharAt(chars, 0, buffer.readu8(target, front)) == nil) then
            break;
        end
        front += 1;
    end
    return mem.sliceOwned(target, front, len - front);
end

--[=[
    Trims a buffer from the right.

    ```luau
    local a = buffer.fromstring("  Hello  ")
    print(buffer.tostring(mem.trimRight(a, buffer.fromstring(" ")))) -- "  Hello"
    ```

    @param target The buffer to trim.
    @param chars The characters to trim.
    @return `buffer` The trimmed buffer.
]=]
function mem.trimRight(target: buffer, chars: buffer): buffer
    local len = buffer.len(target);
    local back = len;
    while (back > 0) do
        if (mem.indexOfCharAt(chars, 0, buffer.readu8(target, back - 1)) == nil) then
            break;
        end
        back -= 1;
    end
    return mem.sliceOwned(target, 0, back);
end

--[=[
    Trims a buffer from both sides.

    ```luau
    local a = buffer.fromstring("  Hello  ")
    print(buffer.tostring(mem.trim(a, buffer.fromstring(" ")))) -- "Hello"
    ```

    @param target The buffer to trim.
    @param chars The characters to trim.
    @return `buffer` The trimmed buffer.
]=]
function mem.trim(target: buffer, chars: buffer): buffer
    local len = buffer.len(target);
    local front = 0;
    local back = len;
    while (front < back) do
        if (mem.indexOfCharAt(chars, 0, buffer.readu8(target, front)) == nil) then
            break;
        end
        front += 1;
    end
    while (back > front) do
        if (mem.indexOfCharAt(chars, 0, buffer.readu8(target, back - 1)) == nil) then
            break;
        end
        back -= 1;
    end
    return mem.sliceOwned(target, front, back - front);
end

return mem;
