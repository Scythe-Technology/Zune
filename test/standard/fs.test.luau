--!strict
local TEMP_DIR = _G.__test_tempdir::string;

local fs = require("@zcore/fs");
local process = require("@zcore/process");
local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

assert(fs.isDir(TEMP_DIR), `TEMP_DIR is not a directory, {TEMP_DIR}`);

describe("Binary", function()
    local binaryData = buffer.fromstring("Some binary\n");
    test("WriteFile", function()
        local success, result = fs.writeFile(TEMP_DIR .. "/sample", binaryData);
        expect(success).toBeTruthy();
        expect(result).toBeNil();

        local successBad, resultBad = fs.writeFile(TEMP_DIR .. "/unknown/sample", binaryData);
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
    end)

    test("ReadFile", function()
        local success, result = fs.readFile(TEMP_DIR .. "/sample", true);
        expect(success).toBeTruthy();
        expect(result).toBe(expect.any("buffer"));
        expect(buffer.tostring(result::buffer)).toBe(buffer.tostring(binaryData));

        local success2, result2 = fs.readFile(TEMP_DIR .. "/sample");
        expect(success2).toBeTruthy();
        expect(result2).toBe(expect.any("string"));
        expect(result2).toBe(buffer.tostring(binaryData));

        local successBad, resultBad = fs.readFile(TEMP_DIR .. "/unknown/sample", true);
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");

        local successBad2, resultBad2 = fs.readFile(TEMP_DIR .. "/unknown/sample");
        expect(successBad2).toBeFalsy();
        expect(resultBad2).toBe("FileNotFound");
    end)

    test("IsFile", function()
        expect(fs.isFile(TEMP_DIR .. "/sample")).toBeTruthy();
        expect(fs.isDir(TEMP_DIR .. "/sample")).toBeFalsy();
        expect(fs.isFile(TEMP_DIR .. "/unknown/sample")).toBeFalsy();
    end)

    test("RemoveFile", function()
        local success, result = fs.removeFile(TEMP_DIR .. "/sample");
        expect(success).toBeTruthy();
        expect(result).toBeNil();

        local successBad, resultBad = fs.removeFile(TEMP_DIR .. "/unknown/sample");
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
    end)
end)

assert(not fs.isFile(TEMP_DIR .. "/sample"), "File should be removed");
assert(not fs.isFile(TEMP_DIR .. "/sample.txt"), "File should not exist");

describe("Text", function()
    local textData = "Some text\n";
    test("WriteFile", function()
        local success, result = fs.writeFile(TEMP_DIR .. "/sample.txt", textData);
        expect(success).toBeTruthy();
        expect(result).toBeNil();

        local successBad, resultBad = fs.writeFile(TEMP_DIR .. "/unknown/sample.txt", textData);
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
    end)

    test("ReadFile", function()
        local success, result = fs.readFile(TEMP_DIR .. "/sample.txt", true);
        expect(success).toBeTruthy();
        expect(result).toBe(expect.any("buffer"));
        expect(buffer.tostring(result::buffer)).toBe(textData);

        local success2, result2 = fs.readFile(TEMP_DIR .. "/sample.txt");
        expect(success2).toBeTruthy();
        expect(result2).toBe(expect.any("string"));
        expect(result2).toBe(textData);

        local successBad, resultBad = fs.readFile(TEMP_DIR .. "/unknown/sample.txt", true);
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");

        local successBad2, resultBad2 = fs.readFile(TEMP_DIR .. "/unknown/sample.txt");
        expect(successBad2).toBeFalsy();
        expect(resultBad2).toBe("FileNotFound");
    end)

    test("IsFile", function()
        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
        expect(fs.isDir(TEMP_DIR .. "/sample.txt")).toBeFalsy();
        expect(fs.isFile(TEMP_DIR .. "/unknown/sample.txt")).toBeFalsy();
    end)

    test("RemoveFile", function()
        local success, result = fs.removeFile(TEMP_DIR .. "/sample.txt");
        expect(success).toBeTruthy();
        expect(result).toBeNil();

        local successBad, resultBad = fs.removeFile(TEMP_DIR .. "/unknown/sample.txt");
        expect(not successBad).toBeTruthy();
        expect(resultBad).toBe("FileNotFound");
    end)
end)

describe("Dir", function()
    test("WriteDir", function()
        local success, result = fs.writeDir(TEMP_DIR .. "/foo");
        expect(success).toBeTruthy();
        expect(result).toBeNil();

        -- Recursive
        local success2, result2 = fs.writeDir(TEMP_DIR .. "/foo/bar/luau", true);
        expect(success2).toBeTruthy();
        expect(result2).toBeNil();

        local successBad, resultBad = fs.writeDir(TEMP_DIR .. "/unknown/foo");
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
    end)

    test("ReadDir", function()
        local success, result = fs.readDir(TEMP_DIR .. "/");
        expect(success).toBeTruthy();
        expect(result).toBe(expect.any("table"));
        expect(result).toBe(expect.similar({"foo"}));
        
        local success2, result2 = fs.readDir(TEMP_DIR);
        expect(success2).toBeTruthy();
        expect(result2).toBe(expect.any("table"));
        expect(result2).toHaveLength(1);
        expect(result2).toBe(expect.similar({"foo"}));

        local success3, result3 = fs.readDir(TEMP_DIR .. "/foo/bar/luau");
        expect(success3).toBeTruthy();
        expect(result3).toBe(expect.any("table"));
        expect(result3).toBe(expect.similar({}));

        local successBad, resultBad = fs.readDir(TEMP_DIR .. "/unknown");
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
    end)

    test("IsDir", function()
        expect(fs.isDir(TEMP_DIR .. "/foo")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/foo")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/unknown/foo")).toBeFalsy();
    end)

    test("RemoveDir", function()
        local success, result = fs.removeDir(TEMP_DIR .. "/foo/bar/luau");
        expect(success).toBeTruthy();
        expect(result).toBeNil();
        expect(fs.isDir(TEMP_DIR .. "/foo/bar/luau")).toBeFalsy();

        local successBad, resultBad = fs.removeDir(TEMP_DIR .. "/foo");
        expect(not successBad).toBeTruthy();
        expect(resultBad).toBe("DirNotEmpty");

        -- Recursive
        local success2, result2 = fs.removeDir(TEMP_DIR .. "/foo", true);
        expect(success2).toBeTruthy();
        expect(result2).toBeNil();
        expect(fs.isDir(TEMP_DIR .. "/foo")).toBeFalsy();
    end)
end)

test("Metadata", function()
    expect(fs.writeDir(TEMP_DIR .. "/metadata")).toBeTruthy();

    local success, metadata = fs.metadata(TEMP_DIR .. "/metadata");
    expect(success).toBeTruthy();
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
    expect(fs.writeDir(TEMP_DIR .. "/metadata")).toBeTruthy();
    expect(fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n")).toBeTruthy();
    expect(fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n")).toBeTruthy();

    local success, result = fs.move(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
    expect(success).toBeTruthy();
    expect(result).toBeNil();
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeFalsy();

    local successRead, resultRead = fs.readFile(TEMP_DIR .. "/sample.txt");
    expect(successRead).toBeTruthy();
    expect(resultRead).toBe("Some text sample\n");

    local successBad, resultBad = fs.move(TEMP_DIR .. "/metadata/sample2.txt", TEMP_DIR .. "/sample.txt");
    expect(successBad).toBeFalsy();
    expect(resultBad).toBe("PathAlreadyExists");
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();

    local success2, result2 = fs.move(TEMP_DIR .. "/metadata/sample2.txt", TEMP_DIR .. "/sample.txt", true);
    expect(success2).toBeTruthy();
    expect(result2).toBeNil();
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample2.txt")).toBeFalsy();

    local successRead2, resultRead2 = fs.readFile(TEMP_DIR .. "/sample.txt");
    expect(successRead2).toBeTruthy();
    expect(resultRead2).toBe("Some text sample number 2\n");

    expect(fs.removeFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.removeDir(TEMP_DIR .. "/metadata")).toBeTruthy();

    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
end)

test("Copy", function()
    expect(fs.writeDir(TEMP_DIR .. "/metadata")).toBeTruthy();
    expect(fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n")).toBeTruthy();
    expect(fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n")).toBeTruthy();

    local success, result = fs.copy(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
    expect(success).toBeTruthy();
    expect(result).toBeNil();
    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeTruthy();

    local successBad, resultBad = fs.copy(TEMP_DIR .. "/metadata/sample3.txt", TEMP_DIR .. "/sample3.txt");
    expect(successBad).toBeFalsy();
    expect(resultBad).toBe("FileNotFound");
    expect(fs.isFile(TEMP_DIR .. "/sample3.txt")).toBeFalsy();

    local success2, result2 = fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
    expect(success2).toBeTruthy();
    expect(result2).toBeNil();
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    local successBad2, resultBad2 = fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
    expect(successBad2).toBeFalsy();
    expect(resultBad2).toBe("PathAlreadyExists");
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    local success3, result3 = fs.copy(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2", true);
    expect(success3).toBeTruthy();
    expect(result3).toBeNil();
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
    expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

    expect(fs.removeFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
    expect(fs.removeDir(TEMP_DIR .. "/metadata", true)).toBeTruthy();
    expect(fs.removeDir(TEMP_DIR .. "/metadata2", true)).toBeTruthy();

    expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
    expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeFalsy();
end)

test("Symlink", function()
    if (process.os ~= "windows") then
        expect(fs.writeDir(TEMP_DIR .. "/metadata")).toBeTruthy();
        expect(fs.writeFile(TEMP_DIR .. "/metadata/sample.txt", "Some text sample\n")).toBeTruthy();
        expect(fs.writeFile(TEMP_DIR .. "/metadata/sample2.txt", "Some text sample number 2\n")).toBeTruthy();

        local success, result = fs.symlink(TEMP_DIR .. "/metadata/sample.txt", TEMP_DIR .. "/sample.txt");
        expect(success).toBeTruthy();
        expect(result).toBeNil();
        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata/sample.txt")).toBeTruthy();
        local successMeta, metadata = fs.metadata(TEMP_DIR .. "/sample.txt");
        expect(successMeta).toBeTruthy();
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

        local successBad, resultBad = fs.symlink(TEMP_DIR .. "/metadata/sample3.txt", TEMP_DIR .. "/sample3.txt");
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
        expect(fs.isFile(TEMP_DIR .. "/sample3.txt")).toBeFalsy();

        local success2, result2 = fs.symlink(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
        expect(success2).toBeTruthy();
        expect(result2).toBeNil();
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();
        local successMeta2, metadata2 = fs.metadata(TEMP_DIR .. "/metadata2");
        expect(successMeta2).toBeTruthy();
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

        local successBad2, resultBad2 = fs.symlink(TEMP_DIR .. "/metadata", TEMP_DIR .. "/metadata2");
        expect(successBad2).toBeFalsy();
        expect(resultBad2).toBe("PathAlreadyExists");
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample.txt")).toBeTruthy();
        expect(fs.isFile(TEMP_DIR .. "/metadata2/sample2.txt")).toBeTruthy();

        expect(fs.removeFile(TEMP_DIR .. "/sample.txt")).toBeTruthy();
        expect(fs.removeDir(TEMP_DIR .. "/metadata", true)).toBeTruthy();
        expect(fs.removeDir(TEMP_DIR .. "/metadata2", true)).toBeTruthy();

        expect(fs.isFile(TEMP_DIR .. "/sample.txt")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/metadata")).toBeFalsy();
        expect(fs.isDir(TEMP_DIR .. "/metadata2")).toBeFalsy();
    end
end)

describe("File Object/Handle", function()
    local textData = "Some text\n";
    test("Open Unknown File", function()
        local success, result = fs.openFile(TEMP_DIR .. "/sample.txt");
        expect(success).toBeFalsy();
        expect(result).toBe("FileNotFound");
    end)
    
    test("Create File", function()
        local success, result = fs.createFile(TEMP_DIR .. "/sample.txt");
        expect(success).toBeTruthy();
        expect(result).toBe(expect.type("userdata"));
        --[[Type Refinement]] assert(type(result) ~= "string");

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
        end).toThrow("NotOpenForReading");
    end)

    test("Create File Execlusive", function()
        local success, result = fs.createFile(TEMP_DIR .. "/sample.txt", {
            exclusive = true,
        });
        expect(success).toBeFalsy();
        expect(result).toBe("PathAlreadyExists");
    end)

    test("Open File Read Mode", function()
        local success, result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "r",
        });
        expect(success).toBeTruthy();
        expect(result).toBe(expect.type("userdata"));
        --[[Type Refinement]] assert(type(result) ~= "string");

        expect(result:getSize()).toBe(#textData);
        expect(result:read()).toBe(textData);
        result:seekTo(0);
        local b = result:read(nil, true);
        expect(b).toBe(expect.type("buffer"));
        expect(buffer.tostring(b)).toBe(textData);

        expect(function()
            result:write("Some text");
        end).toThrow("NotOpenForWriting");
    end)

    test("Open File Write Mode", function()
        local success, result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "w",
        });
        expect(success).toBeTruthy();
        expect(result).toBe(expect.type("userdata"));
        --[[Type Refinement]] assert(type(result) ~= "string");

        expect(result:getSize()).toBe(#textData);
        result:seekFromEnd();
        result:write("Append text");
        expect(result:getSize()).toBe(#textData + #("Append text"));
        
        expect(function()
            result:read();
        end).toThrow("NotOpenForReading");
        
        result:close();
    end)

    test("Open File Both Mode", function()
        local success, result = fs.openFile(TEMP_DIR .. "/sample.txt", {
            mode = "rw",
        });
        expect(success).toBeTruthy();
        expect(result).toBe(expect.type("userdata"));
        --[[Type Refinement]] assert(type(result) ~= "string");

        expect(result:read()).toBe(textData .. "Append text");

        result:write("Some text");

        result:close();
    end)
end)
