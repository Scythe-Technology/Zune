export type JsonEncoder = {
    --[[
        Encodes value to JSON
    ]]
    encode : (value: any) -> string,
    --[[
        Decodes JSON
    ]]
    decode : (json: string) -> any,
};
export type TomlEncoder = {
    --[[
        Encodes table to TOML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes TOML
    ]]
    decode : (toml: string) -> {[string]: any},
};
export type YamlEncoder = {
    --[[
        Encodes table to YAML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes YAML
    ]]
    decode : (yaml: string) -> {[string]: any},
};
export type Base64Encoder = {
    --[[
        Encodes table to BASE64
    ]]
    encode : (value: string) -> string,
    --[[
        Decodes BASE64
    ]]
    decode : (base64: string) -> string,
};

export type GenericCompressionOptions = {
    --[[
        The compression level.
    ]]
    level : number?,
};
export type GenericCompressor = {
    --[[
        Compresses a string.
    ]]
    compress :
        & ((raw: string, options: GenericCompressionOptions?) -> string)
        & ((raw: buffer, options: GenericCompressionOptions?) -> buffer),
    --[[
        Decompresses a string.
    ]]
    decompress :
        & (compressed: string) -> string
        & (compressed: buffer) -> buffer,
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
    BASE64 encoder and decoder.
]]
serde.base64 = (nil :: any) :: Base64Encoder;

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
