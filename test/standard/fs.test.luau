--!strict
local TEMP_DIR = _G.__test_tempdir::string;

local fs = zune.fs;
local task = zune.task;
local process = zune.process;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

assert(fs.isDir(TEMP_DIR), `TEMP_DIR is not a directory, {TEMP_DIR}`);

local function warn(message: string)
    print("\27[33m" .. message .. "\27[0m");
end

describe("Binary", function()
    local binaryData = buffer.fromstring("Some binary\n");
    test("WriteFile", function()
        fs.writeFile(TEMP_DIR .. "/sample", binaryData);

        expect(function()
            fs.writeFile(TEMP_DIR .. "/unknown/sample", binaryData);
        end).toThrow("FileNotFound");
    end)

    test("ReadFile", function()
        local result = fs.readFile(TEMP_DIR .. "/sample", true);
        expect(result).toBe(expect.any("buffer"));
        expect(buffer.tostring(result::buffer)).toBe(buffer.tostring(binaryData));

        local result2 = fs.readFile(TEMP_DIR .. "/sample");
        expect(result2).toBe(expect.any("string"));
        expect(result2).toBe(buffer.tostring(binaryData));

        expect(function()
            fs.readFile(TEMP_DIR .. "/unknown/sample", true);
        end).toThrow("FileNotFound");

        expect(function()
            fs.readFile(TEMP_DIR .. "/unknown/sample");
        end).toThrow("FileNotFound");
    end)

    test("IsFile", function()
        expect(fs.isFile(TEMP_DIR .. "/sample")).toBeTruthy();
        expect(fs.isDir(TEMP_DIR .. "/sample")).toBeFalsy();
        expect(fs.isFile(TEMP_DIR .. "/unknown/sample")).toBeFalsy();
    end)

    test("RemoveFile", function()
        fs.removeFile(TEMP_DIR .. "/sample");

        expect(function()
            fs.removeFile(TEMP_DIR .. "/unknown/sample")
        end).toThrow("FileNotFound");
    end)
end)

assert(not fs.isFile(TEMP_DIR .. "/sample"), "File should be removed");
assert(not fs.isFile(TEMP_DIR .. "/sample.txt"), "File should not exist");

describe("Text", function()
    local textData = "Some text\n";
    test("WriteFile", function()
        fs.writeFile(TEMP_DIR .. "/sample.txt", textData);

        expect(function()
            fs.writeFile(TEMP_DIR .. "/unknown/sample.txt", textData);
        end).toThrow("FileNotFound");
    end)

    test("ReadFile", function()
        local result = fs.readFile(TEMP_DIR .. "/sample.txt", true);
        expect(result).toBe(expect.any("buffer"));
        expect(buffer.tostring(result::buffer)).toBe(textData);

        local result2 = fs.readFile(TEMP_DIR .. "/sample.txt");
        expect(result2).toBe(expect.any("string"));
        expect(result2).toBe(textData);

        expect(function()
            fs.readFile(TEMP_DIR .. "/unknown/sample.txt", true);
        end).toThrow("FileNotFound");

        expect(function()
            fs.readFile(TEMP_DIR .. "/unknown/sample.txt");
        end).toThrow("FileNotFound");
    end)

    test("IsFile", function()
        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
        expect(fs.isDir(TEMP_DIR .. "/sample.txt")).toBeFalsy();
        expect(fs.isFile(TEMP_DIR .. "/unknown/sample.txt")).toBeFalsy();
    end)

    test("RemoveFile", function()
        fs.removeFile(TEMP_DIR .. "/sample.txt");

        expect(function()
            fs.removeFile(TEMP_DIR .. "/unknown/sample.txt")
        end).toThrow("FileNotFound");
    end)
end)

describe("Dir", function()
    test("WriteDir", function()
        fs.writeDir(TEMP_DIR .. "/foo");

        -- Recursive
        fs.writeDir(TEMP_DIR .. "/foo/bar/luau", true);

        expect(function()
            fs.writeDir(TEMP_DIR .. "/unknown/foo");
        end).toThrow("FileNotFound");
    end)

    test("ReadDir", function()
        local result = fs.readDir(TEMP_DIR .. "/");
        expect(result).toBe(expect.any("table"));
        expect(result).toBe(expect.similar({"foo"}));
        
        local result2 = fs.readDir(TEMP_DIR);
        expect(result2).toBe(expect.any("table"));
        expect(result2).toHaveLength(1);
        expect(result2).toBe(expect.similar({"foo"}));

        local result3 = fs.readDir(TEMP_DIR .. "/foo/bar/luau");
        expect(result3).toBe(expect.any("table"));
        expect(result3).toBe(expect.similar({}));

        expect(function()
            fs.readDir(TEMP_DIR .. "/unknown");
        end).toThrow("FileNotFound");
    end)

    test("IsDir", function()
        expect(fs.isDir(TEMP_DIR .. "/foo")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/foo")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/unknown/foo")).toBeFalsy();
    end)

    test("RemoveDir", function()
        fs.removeDir(TEMP_DIR .. "/foo/bar/luau");
        expect(fs.isDir(TEMP_DIR .. "/foo/bar/luau")).toBeFalsy();

        expect(function()
            fs.removeDir(TEMP_DIR .. "/foo");
        end).toThrow("DirNotEmpty");

        -- Recursive
        fs.removeDir(TEMP_DIR .. "/foo", true);
        expect(fs.isDir(TEMP_DIR .. "/foo")).toBeFalsy();
    end)
end)

test("Metadata", function()
    fs.writeDir(TEMP_DIR .. "/metadata");

    local metadata = fs.metadata(TEMP_DIR .. "/metadata");
    expect(metadata).toBe(expect.any("table"));
    expect(metadata).toBe(expect.similar({
        createdAt = expect.any("number"),
        modifiedAt = expect.any("number"),
        accessedAt = expect.any("number"),
        size = expect.any("number"),
        symlink = false,
        kind = "dir",
        permissions = {
            readOnly = false,
        },
    }));
    expect(fs.removeDir(TEMP_DIR .. "/metadata"));
end)

test("Move", function()
    fs.writeDir(TEMP_DIR .. "/metadata");
    fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n");
    fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n");

    fs.move(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeFalsy();

    local resultRead = fs.readFile(TEMP_DIR .. "/sample.txt");
    expect(resultRead).toBe("Some text sample\n");

    expect(function()
        fs.move(TEMP_DIR .. "/metadata/sample2.txt", TEMP_DIR .. "/sample.txt");
    end).toThrow("PathAlreadyExists");
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();

    fs.move(TEMP_DIR .. "/metadata/sample2.txt", TEMP_DIR .. "/sample.txt", true);
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample2.txt")).toBeFalsy();

    local resultRead2 = fs.readFile(TEMP_DIR .. "/sample.txt");
    expect(resultRead2).toBe("Some text sample number 2\n");

    fs.removeFile(TEMP_DIR .. "/sample.txt");
    fs.removeDir(TEMP_DIR .. "/metadata");

    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
end)

test("Copy", function()
    fs.writeDir(TEMP_DIR .. "/metadata");
    fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n");
    fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n");

    fs.copy(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeTruthy();

    expect(function()
        fs.copy(TEMP_DIR .. "/metadata/sample3.txt", TEMP_DIR .. "/sample3.txt");
    end).toThrow("FileNotFound");
    expect(fs.isFile(TEMP_DIR .. "/sample3.txt")).toBeFalsy();

    fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    expect(function()
        fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
    end).toThrow("PathAlreadyExists");
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2", true);
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    fs.removeFile(TEMP_DIR .. "/sample.txt");
    fs.removeDir(TEMP_DIR .. "/metadata", true);
    fs.removeDir(TEMP_DIR .. "/metadata2", true);

    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeFalsy();
end)

test("Symlink", function()
    if (process.os ~= "windows") then
        fs.writeDir(TEMP_DIR .. "/metadata");
        fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n");
        fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n");

        fs.symlink(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeTruthy();
        local metadata = fs.metadata(TEMP_DIR .. "/sample.txt");
        expect(metadata).toBe(expect.any("table"));
        expect(metadata).toBe(expect.similar({
            createdAt = expect.any("number"),
            modifiedAt = expect.any("number"),
            accessedAt = expect.any("number"),
            size = expect.any("number"),
            symlink = true,
            kind = "file",
            permissions = {
                readOnly = false,
            },
        }));

        expect(function()
            fs.symlink(TEMP_DIR .. "/metadata/sample3.txt", TEMP_DIR .. "/sample3.txt")
        end).toThrow("FileNotFound");
        expect(fs.isFile(TEMP_DIR .. "/sample3.txt")).toBeFalsy();

        fs.symlink(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();
        local metadata2 = fs.metadata(TEMP_DIR .. "/metadata2");
        expect(metadata2).toBe(expect.any("table"));
        expect(metadata2).toBe(expect.similar({
            createdAt = expect.any("number"),
            modifiedAt = expect.any("number"),
            accessedAt = expect.any("number"),
            size = expect.any("number"),
            symlink = true,
            kind = "dir",
            permissions = {
                readOnly = false,
            },
        }));

        expect(function()
            fs.symlink(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
        end).toThrow("PathAlreadyExists");
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

        fs.removeFile(TEMP_DIR .. "/sample.txt");
        fs.removeDir(TEMP_DIR .. "/metadata", true);
        fs.removeDir(TEMP_DIR .. "/metadata2", true);

        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeFalsy();
    end
end)

describe("File Object/Handle", function()
    local textData = "Some text\n";
    test("Open Unknown File", function()
        expect(function()
            fs.openFile(TEMP_DIR .. "/sample.txt")
        end).toThrow("FileNotFound");
    end)
    
    test("Create File", function()
        local result = fs.createFile(TEMP_DIR .. "/sample.txt");
        expect(result).toBe(expect.type("userdata"));

        expect(result:read()).toBe(""); -- Should have no data

        expect(result:getSize()).toBe(0);

        result:write(textData); -- Write data

        expect(result:getSize()).toBe(#textData);

        result:seekFromEnd(-#textData); -- Go back to amount of textData
        expect(result:getSize()).toBe(#textData); -- Confirm size
        expect(result:read()).toBe(textData); -- Confirm data

        result:sync(); -- Sync data to disk

        result:close(); -- Close file (also syncs data)

        expect(function()
            result:read();
        end).toThrow()
    end)

    test("Create File Execlusive", function()
        expect(function()
            local _ = fs.createFile(TEMP_DIR .. "/sample.txt", {
                exclusive = true,
            });
        end).toThrow("PathAlreadyExists");
    end)

    test("Open File Read Mode", function()
        local result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "r",
        });
        expect(result).toBe(expect.type("userdata"));

        expect(result:getSize()).toBe(#textData);
        expect(result:read()).toBe(textData);
        result:seekTo(0);
        local b = result:read(nil, true);
        expect(b).toBe(expect.type("buffer"));
        expect(buffer.tostring(b)).toBe(textData);

        expect(function()
            result:write("Some text");
        end).toThrow();
    end)

    test("Open File Write Mode", function()
        local result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "w",
        });
        expect(result).toBe(expect.type("userdata"));

        expect(result:getSize()).toBe(#textData);
        result:seekFromEnd();
        result:write("Append text");
        expect(result:getSize()).toBe(#textData + #("Append text"));
        
        expect(function()
            result:read();
        end).toThrow();
        
        result:close();
    end)

    test("Open File Both Mode", function()
        local result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "rw",
        });
        expect(result).toBe(expect.type("userdata"));

        expect(result:read()).toBe(textData .. "Append text");

        result:write("Some text");

        result:close();
    end)

    fs.removeFile(TEMP_DIR .. "/sample.txt");
end)

test("Watch", function()
    if (process.os == "macos") then
        warn("Skipping 'Watch' test on macOS.");
        return; -- Skip on macOS
    end
    local changes = {};
    task.wait(0.5);
    local watcher = fs.watch(TEMP_DIR, function(path, events)
        table.insert(changes, {
            path = path,
            events = events,
        });
    end);

    testing.defer(function()
        watcher:stop();
    end)

    fs.writeFile(TEMP_DIR .. "/sample2.txt", "Some text\n");
    task.wait(0.5);
    fs.removeFile(TEMP_DIR .. "/sample2.txt");
    task.wait(0.5);
    fs.writeDir(TEMP_DIR .. "/foo");
    task.wait(0.5);
    fs.removeDir(TEMP_DIR .. "/foo");
    task.wait(0.5);

    -- TODO: Check tests for windows, tests for windows are inconsistent
    expect(changes).toBe(expect.similar(if (process.os ~= "windows") then {
        {path = "sample2.txt", events = {"created"}},
        {path = "sample2.txt", events = {"modified"}},
        {path = "sample2.txt", events = {"deleted"}},
        {path = "foo", events = {"created"}},
        {path = "foo", events = {"deleted"}},
    } else {
        {path = "sample2.txt", events = {"modified"}},
        {path = "sample2.txt", events = {"deleted"}},
        {path = "foo", events = {"created"}},
        {path = "foo", events = {"deleted"}},
    }));
end)
