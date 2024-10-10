--!strict
local task = require("@zcore/task");

local testing = {
    running = true,
    _COUNT = 0,
    _FAILED = 0,
    _START = nil::number?,
};
local scope_stack = {}::{string};
local fn_defer = {}::{()->()};

local GLOBAL = getfenv();

local scheduler_droptasks = GLOBAL.scheduler_droptasks :: () -> ();
local declare_safeEnv = GLOBAL.declare_safeEnv :: () -> ();

declare_safeEnv();

-- TODO: probably should make this configurable
local USE_PLAIN = false;
local L = if (USE_PLAIN) then "|" else "│";
local CL = if (USE_PLAIN) then "--" else "└─";
local CL2 = if (USE_PLAIN) then "|-" else "└─";

function testing.describe(name, fn)
    table.insert(scope_stack, name);
    local ok, err = pcall(fn);
    table.remove(scope_stack);
    if (not ok) then
        testing._FAILED += 1;
        print(`\x1b[1;33mdescribe(\"{name}\", ...) is not suppose to error:\x1b[0m\n    \x1b[1;31m{err}\x1b[0m`);
    end
end

local function hasSomething(name : string?) : boolean
    return type(name) == "string" and #name > 1;
end

function testing.defer(fn: () -> ())
    assert(type(fn) == "function", `testing.defer expected function (got {type(fn)})`);
    table.insert(fn_defer, fn);
end

local function secondstoMs(seconds : number) : number
    return (seconds * 1000) // 1;
end

function testing.test(name : string, fn: () -> (), timeout : number?)
    testing._COUNT += 1;
    if (not testing._START) then
        testing._START = os.clock();
    end
    local ok, err;
    local stacktrace = {};
    local _time = 0;
    local _time_start = os.clock();
    ok = xpcall(fn, function(e)
        _time = os.clock() - _time_start;
        local lastN = debug.info(1, "n");
        for i = 1, 30 do
            local f, n, l, _ = debug.info(i + 1, "fnls");
            if (not f) then
                break;
            end
            local ln = lastN;
            if (#stacktrace > 0 or hasSomething(n)) then
                lastN = n;
            end
            if (l < 0) then
                continue;
            end
            local context = getfenv(f);
            local _FILE = context._FILE;
            if (type(_FILE) ~= "table") then
                continue;
            end
            table.insert(stacktrace, {
                file = _FILE,
                name = ln,
                line = l,
                source = "",
                address = tostring(f),
            })
        end
        err = e;
    end)
    if (ok) then
        _time = os.clock() - _time_start;
    end
    _time = secondstoMs(_time);

    local scope = if (#scope_stack > 0)
        then `{table.concat(scope_stack, "/")} `
        else "";

    for _, v in fn_defer do
        v();
    end
    table.clear(fn_defer);

    local a = os.clock() + 1.5;
    while (task.count() > 0) do
        task.wait(0.25);
        if (a < os.clock()) then
            break;
        end
    end

    if (ok) then
        if (task.count() == 0) then
            print(` \x1b[1;32mPASS\x1b[0m \x1b[2m{scope}\x1b[0m(\x1b[1m{name}\x1b[0m) \x1b[2m[{_time}ms]\x1b[0m`);
        else
            print(` \x1b[1;33mWARN\x1b[0m \x1b[2m{scope}\x1b[0m(\x1b[1m{name}\x1b[0m) \x1b[2m[{_time}ms]\x1b[0m`);
            print(` \x1b[2m{L}\x1b[0;33m Test Running Tasks Timedout (Possible Leak)\x1b[0m`);
            print(` \x1b[2m{L}    This message is just a warning, but should be noted, that the test has active tasks\x1b[0m`);
            print(` \x1b[2m{L}    in the scheduler for more than 5 seconds.\x1b[0m`);
            print(` \x1b[2m{L}\x1b[0m`);
            local s, d, w, t = task.count("sdwt");
            local show = {};
            if (s> 0) then
                print(` \x1b[2m{L}    "Sleeping" - (Zune Luau), \x1b[0m`);
                print(` \x1b[2m{L}      Active luau task, usually means there is a running task created by luau or zune.\x1b[0m`);
                print(` \x1b[2m{L}      Caused when a sleeping task is still in queue.\x1b[0m`);
                print(` \x1b[2m{L}      From calling 'task.delay'/'task.sleep' or zune backend has requested a delayed resume on a thread\x1b[0m`);
                table.insert(show, `Sleeping Tasks: \x1b[33m{s}\x1b[0m`);
            end
            if (d > 0) then
                print(` \x1b[2m{L}    "Deferred" - (Zune Luau), \x1b[0m`);
                print(` \x1b[2m{L}      Active luau task, usually means there is a running task created by luau or zune.\x1b[0m`);
                print(` \x1b[2m{L}      Caused when a deferred task is still in queue.\x1b[0m`);
                print(` \x1b[2m{L}      From calling 'task.defer' or zune backend has requested a deferred resume on a thread\x1b[0m`);
                table.insert(show, `Deferred Tasks: \x1b[33m{d}\x1b[0m`);
            end
            if (w > 0) then
                print(` \x1b[2m{L}    "Awaiting" - (Zune Backend > Zig), \x1b[0m`);
                print(` \x1b[2m{L}      Active zune awaiting task, usually means there is a running task created by the zune backend.\x1b[0m`);
                print(` \x1b[2m{L}      Caused by a the zune backend waiting for a response from luau\x1b[0m`);
                print(` \x1b[2m{L}      For example, a active task waiting for a response from a zune server "@zcore/net" called in 'request'\x1b[0m`);
                table.insert(show, `Awaiting Tasks: \x1b[33m{w}\x1b[0m`);
            end
            if (t > 0) then
                print(` \x1b[2m{L}    "Internal" - (Zune Backend > Zig)\x1b[0m`);
                print(` \x1b[2m{L}      Active zune core task, usually means there is a running task created by the zune backend.\x1b[0m`);
                print(` \x1b[2m{L}      Caused by undisposed backend tasks.\x1b[0m`);
                print(` \x1b[2m{L}      For example, a open zune server from "@zcore/net"\x1b[0m`);
                table.insert(show, `Internal Tasks: \x1b[33m{t}\x1b[0m`);
            end
            print(` \x1b[2m{L}\x1b[0m`);
            print(` \x1b[2m{L}    If this is a bug, please report it!\x1b[0m`);
            scheduler_droptasks();
            print(` \x1b[2m{L}    \x1b[0;34mAll tasks has been dropped\x1b[0m`);
            for i, v in show do
                if (i ~= #show) then
                    print(` \x1b[2m{L}\x1b[0m  {v}`);
                    continue;
                end
                print(` \x1b[2m{CL}\x1b[0m {v}`);
            end
        end

        return;
    end

    scheduler_droptasks();

    testing._FAILED += 1;

    print(` \x1b[1;31mFAIL\x1b[0m \x1b[2m{scope}\x1b[0m(\x1b[1m{name}\x1b[0m) \x1b[2m[{_time}ms]\x1b[0m`);
    
    if (type(err) ~= "string") then
        return;
    end

    local sz = #stacktrace;
    local errorLines = err:split("\n");
    for _, v in errorLines do
        print(` \x1b[2m{L}\x1b[0m \x1b[31m{v}\x1b[0m`);
    end

    for i, v in stacktrace do
        local last = i == sz;
        local contents = v.file.source;

        local line = contents:split("\n")[v.line];
        local safeLine = line:gsub("\t", "    ");
        local indent : number = #(string.match(safeLine, "^(%s*)") or "");
        local column = #(string.match(line, "^(%s*)") or "");
        local nameHasValue = hasSomething(v.name);
        if (nameHasValue and v.name) then
            local start = safeLine:find(v.name, 1, true);
            if (start) then
                local subColumn = line:find(v.name, 1, true);
                if (subColumn) then
                    column = subColumn;
                    indent = (start - 1) or indent;
                end
            end
        end
        
        print(` \x1b[2m{L}\x1b[0m \x1b[31m{v.file.name}:{v.line}:{column}:\x1b[0m \x1b[2m{v.address:sub(11)}{#v.source > 0 and ` {v.source}` or ""}{nameHasValue and ` called {v.name}` or ""} (test)\x1b[0m`);
        print(` \x1b[2m{L}\x1b[0m \x1b[0m{safeLine}\x1b[0m`);
        print(` \x1b[2m{last and `{CL}` or `{L} `}\x1b[0m{string.rep("\32", indent)}\x1b[31m^\x1b[0m`);
    end

    declare_safeEnv();
end

local function assertExpect(flipped : boolean, value : boolean, fmt : string, ... : any)
    if (flipped) then
        value = not value;
    end
    if (not value) then
        error(string.format(fmt, ...), 4);
    end
end

local Conditional = {};
Conditional.__index = Conditional;

function Conditional.new(name : string, func : (value : any) -> (boolean, string?), any: any?)
    return setmetatable({
        test = func,
        name = name,
        value = any,
    }, Conditional);
end

function Conditional.is(a)
    return type(a) == "table" and getmetatable(a) == Conditional;
end

type Conditional = typeof(Conditional.new("", function(_) return true, "" end));

function Conditional.__call(self : Conditional, ...)
    return self.test(...);
end

function Conditional.__tostring(self : Conditional)
    return self.name;
end

type ConditionState = {
    received : any,
    flipped : boolean,
    shared : {[string] : any},
};

local function flipTag(flipped : boolean)
    return if (flipped) then "not " else ""
end

local READABLE_CONTROL = {
    ['\n'] = "\\n";
    ['\r'] = "\\r";
    ['\t'] = "\\t";
    ['\v'] = "\\v";
    ['\f'] = "\\f";
    ['\b'] = "\\b";
    ['\a'] = "\\a";
    ['\\'] = "\\\\";
    ['"'] = "\\\"";
    ['%'] = string.format("\\x%02X", 37);
};

local function readable(value : any)
    local t = type(value);
    if (t == "string") then
        local safeValue = value:gsub(".", function(char : string)
            local b = char:byte();
            if (b < 32 or b > 126) then
                if (READABLE_CONTROL[char]) then
                    return READABLE_CONTROL[char];
                else
                    return string.format("\\x%02X", b);
                end
            elseif (char == "\\") then
                return "\\\\";
            elseif (READABLE_CONTROL[char]) then
                return READABLE_CONTROL[char];
            end
            return char;
        end)
        return `'{safeValue}'`;
    else
        return tostring(value);
    end
end

local conditionals = {
    toBe = function(self : ConditionState, expected : any)
        if (Conditional.is(expected)) then
            local cond, a, s = expected(self.received);
            if (s) then
                assertExpect(self.flipped, cond, s, flipTag(self.flipped));
            else
                assertExpect(self.flipped, cond, "Expected %s to %sbe %s", a or readable(self.received), flipTag(self.flipped), readable(expected));
            end
        else 
            assertExpect(self.flipped, self.received == expected, "Expected %s to %sbe %s", readable(self.received), flipTag(self.flipped), readable(expected));
        end
    end,
    toBeDefined = function(self : ConditionState)
        assertExpect(self.flipped, self.received ~= nil, "Expected %s to %sbe defined", readable(self.received), flipTag(self.flipped));
    end,
    toBeCloseTo = function(self : ConditionState, expected, precision: number)
        assertExpect(self.flipped, 
            expected == math.huge and self.received == math.huge
            or expected == -math.huge and self.received == -math.huge
            or math.abs(self.received - expected) < (10 ^ -precision)/2
        , "Expected %s to be close to %s", readable(self.received), expected);
    end,
    toBeGreaterThan = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received > expected, "Expected %s to %sbe greater than %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeGreaterThanOrEqual = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received >= expected, "Expected %s to %sbe greater than or equal to %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeLessThan = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received < expected, "Expected %s to %sbe less than %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeLessThanOrEqual = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received <= expected, "Expected %s to %sbe less than or equal to %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeNil = function(self : ConditionState)
        assertExpect(self.flipped, self.received == nil, "Expected %s to %sbe Nil", readable(self.received), flipTag(self.flipped));
    end,
    toBeNan = function(self : ConditionState)
        assertExpect(self.flipped, self.received ~= self.received and type(self.received) == "number", "Expected %s to %sbe NaN", readable(self.received), flipTag(self.flipped));
    end,
    toHaveLength = function(self : ConditionState, expected)
        assertExpect(self.flipped, #self.received == expected, "Expected %s to %shave length %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeFalsy = function(self : ConditionState)
        assertExpect(self.flipped, not self.received, "Expected %s to %sbe falsy", readable(self.received), flipTag(self.flipped));
    end,
    toBeTruthy = function(self : ConditionState)
        assertExpect(self.flipped, self.received, "Expected %s to %sbe truthy", readable(self.received), flipTag(self.flipped));
    end,
    toThrow = function(self : ConditionState, expected : string?)
        assertExpect(false, type(self.received) == "function", "Expected %s to %sbe a function", readable(self.received), flipTag(self.flipped));
        local success, err = pcall(self.received);
        if (expected ~= nil) then
            assertExpect(false, not success, "Expected %s to %sthrow an error", readable(self.received), flipTag(self.flipped));
            local stripped = err:match("^%[string \"[^\"]+\"%]:%d+: (.+)$");
            if (not stripped) then
                error("Expected error message to be in the format of '[string \"<filename>\"]:<line>: <message>'", 2);
            end
            assertExpect(self.flipped, stripped == expected, "Got error %s expected to %sthrow %s", readable(stripped), flipTag(self.flipped), readable(expected));
        else
            assertExpect(self.flipped, not success, "Expected %s to %sthrow an error", readable(self.received), flipTag(self.flipped));
        end
    end,
};

conditionals.toEqual = conditionals.toBe;

local function deepScan(a : any, b : any, state : {[any] : any}) : (boolean, string?, boolean?)
    if (a == b) then
        return true;
    end
    if (Conditional.is(a)) then
        if (a.name ~= "@similar") then
            local result, _, reason = a(b);
            local first = false
            return result, if (reason) then reason:gsub("%%s", ''):gsub("\n", function(c)
                if (not first) then
                    first = true;
                    return `\n{CL2} `;
                end
                return "\n   ";
            end) else "failed condition", true;
        else
            a = a.value;
        end
    end
    if (type(a) ~= type(b)) then
        return false, `not the same type ({type(a)} ~= {type(b)})`, true;
    end
    if (type(a) == "table") then
        if (state[a] == b) then
            return true;
        end
        state[a] = b;
        for key, value in a do
            local result, reason, root = deepScan(value, b[key], state);
            if (not result) then
                return false, if (root) then `[{key}]: {reason}` else `[{key}]{reason}`;
            end
        end
        for key, value in b do
            local result, reason, root = deepScan(a[key], value, state);
            if (not result) then
                return false, if (root) then `[{key}]: {reason}` else `[{key}]{reason}`;
            end
        end
        return true;
    end
    return false, `not the same value ({readable(a)} ~= {readable(b)})`, true;
end

local expect = setmetatable({
    nothing = Conditional.new("nothing", function(value)
        return value == nil;
    end),
    any = function(typename : string)
        if (type(typename) ~= "string") then
            error(`expect.any expected string, got {type(typename)}`, 2);
        end
        return Conditional.new(typename, function(value)
            local t = typeof(value);
            return t == typename, t, `value is supposed to %sbe of type {typename}`;
        end)
    end,
    type = function(typename : string)
        if (type(typename) ~= "string") then
            error(`expect.type expected string, got {type(typename)}`, 2);
        end
        return Conditional.new(typename, function(value)
            local t = typeof(value);
            return t == typename, t, `value is supposed to %sbe of type {typename}`;
        end)
    end,
    similar = function(t : {[any]: any})
        if (type(t) ~= "table") then
            error(`expect.type expected string, got {type(t)}`, 2);
        end
        return Conditional.new("@similar", function(value)
            local result, reason = deepScan(t, value, {});
            return result, nil, `value is supposed to %sbe similar to specified table\n\n<table>{reason}`;
        end, t)
    end
}, {
    __call = function(self: any, value: any)
        local obj = {
            never = {},
        };

        local sharedState = {};
        local normalState = {
            received = value,
            flipped = false,
            shared = sharedState,
        };
        local neverState = {
            received = value,
            flipped = true,
            shared = sharedState,
        };
        for key, func in conditionals::{[string] : (...any) -> ()} do
            obj[key] = function(...)
                func(normalState, ...);
            end
            obj.never[key] = function(...)
                func(neverState, ...);
            end
        end

        return obj;
    end
});

testing.expect = expect;

testing.expected = function(a : any)
    if (not a) then
        error(string.format("Truthy value expected"), 2);
    end
end

testing.expectEqual = function(a : any, b : any)
    if (a ~= b) then
        error(string.format("Expected %s to be equal to %s", readable(a), readable(b)), 2);
    end
end

return testing;
