export type JsonEncoder = {
    --[[
        Encodes table to JSON
    ]]
    encode : (object: any) -> string,
    --[[
        Decodes JSON
    ]]
    decode : (string) -> any,
};
export type TomlEncoder = {
    --[[
        Encodes table to TOML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes TOML
    ]]
    decode : (string) -> {[string]: any},
};
export type YamlEncoder = {
    --[[
        Encodes table to YAML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes YAML
    ]]
    decode : (string) -> {[string]: any},
};

export type GenericCompressionOptions = {
    --[[
        The compression level.
    ]]
    level : number?,
}
export type GenericCompressor = {
    --[[
        Compresses a string.
    ]]
    compress : (raw: string, options: GenericCompressionOptions?) -> string,
    --[[
        Decompresses a string.
    ]]
    decompress : (compressed: string) -> string,
};

local serde = {}

--[[
    JSON encoder and decoder.
]]
serde.json = (nil :: any) :: JsonEncoder;

--[[
    TOML encoder and decoder.
]]
serde.toml = (nil :: any) :: TomlEncoder;

--[[
    YAML encoder and decoder.
]]
serde.yaml = (nil :: any) :: YamlEncoder;

--[[
    GZIP compressor and decompressor.
]]
serde.gzip = (nil :: any) :: GenericCompressor;

--[[
    ZLIB compressor and decompressor.
]]
serde.zlib = (nil :: any) :: GenericCompressor;

--[[
    LZ4 compressor and decompressor.
]]
serde.lz4 = (nil :: any) :: GenericCompressor;

return serde;
