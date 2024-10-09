--!strict
local serde = require("@zcore/serde");
local testing = require("@zcore/testing");

local expect = testing.expect;

expect(serde.json).toBe(expect.similar({
    encode = expect.type("function"),
    decode = expect.type("function"),
    Indents = expect.similar({
        None = expect.type("number"),
        TwoSpaces = expect.type("number"),
        FourSpaces = expect.type("number"),
        Tabs = expect.type("number"),
    }),
    Values = expect.similar({
        Null = expect.type("table"),
    }),
}));
expect(serde.json5).toBe(expect.similar({
    encode = expect.type("function"),
    decode = expect.type("function"),
    Indents = expect.similar({
        None = expect.type("number"),
        TwoSpaces = expect.type("number"),
        FourSpaces = expect.type("number"),
        Tabs = expect.type("number"),
    }),
    Values = expect.similar({
        Null = expect.type("table"),
    }),
}));
expect(serde.json5.Values).toBe(serde.json.Values);
expect(serde.json5.Indents).toBe(serde.json.Indents);
expect(serde.toml).toBe(expect.similar({
    encode = expect.type("function"),
    decode = expect.type("function"),
}));
expect(serde.yaml).toBe(expect.similar({
    encode = expect.type("function"),
    decode = expect.type("function"),
}));
expect(serde.gzip).toBe(expect.similar({
    compress = expect.type("function"),
    decompress = expect.type("function"),
}));
expect(serde.zlib).toBe(expect.similar({
    compress = expect.type("function"),
    decompress = expect.type("function"),
}));
expect(serde.lz4).toBe(expect.similar({
    compress = expect.type("function"),
    decompress = expect.type("function"),
}));

require("./json.test");
require("./json5.test");
require("./toml.test");
require("./yaml.test");
require("./gzip.test");
require("./zlib.test");
require("./lz4.test");
