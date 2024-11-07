assert(zune, "Zune is not defined");
assert(type(getmetatable(zune :: any)) == "string", "Zune metatable is not locked");

local success, err = pcall(function()
    zune.fs = {};
end)
assert(not success, "Zune should be readonly");
assert(err:find("readonly"), "Zune should be readonly");
