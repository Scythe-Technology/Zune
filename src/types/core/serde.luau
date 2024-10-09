export type JsonEncodeConfig = {
    --[[
        Pretty print indent level
    ]]
    prettyIndent : number,
};


export type JsonDecodeConfig = {
    --[[
        Preserve null values
    ]]
    preserveNull : boolean,
};

export type JsonEncoder = {
    --[[
        Encodes value to JSON/JSON5

        @param value The value to encode
        @param indent The indent level
        @return `string` The encoded JSON/JSON5
    ]]
    encode : (value: any, config: JsonEncodeConfig?) -> string,
    --[[
        Decodes JSON/JSON5

        @param json The JSON/JSON5 to decode
        @param config The configuration
        @return `any` The decoded value
    ]]
    decode : (json: string, config: JsonDecodeConfig?) -> any,

    --[[
        IndentKind for Pretty Printing
    ]]
    Indents : {
        None : number,
        TwoSpaces : number,
        FourSpaces : number,
        Tabs : number,
    },

    --[[
        Special values
    ]]
    Values : {
        Null : any,
    }
};

export type TomlEncoder = {
    --[[
        Encodes table to TOML

        @param object The table to encode
        @return `string` The encoded TOML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes TOML

        @param toml The TOML to decode
        @return `table` The decoded table
    ]]
    decode : (toml: string) -> {[string]: any},
};

export type YamlEncoder = {
    --[[
        Encodes table to YAML

        @param object The table to encode
        @return `string` The encoded YAML
    ]]
    encode : (object: {[string]: any}) -> string,
    --[[
        Decodes YAML

        @param yaml The YAML to decode
        @return `table` The decoded table
    ]]
    decode : (yaml: string) -> {[string]: any},
};

export type Base64Encoder = {
    --[[
        Encodes table to Base64

        @param value The value to encode
        @return `string` The encoded Base64
    ]]
    encode : (value: string) -> string,
    --[[
        Decodes Base64

        @param base64 The Base64 to decode
        @return `string` The decoded value
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
    JSON5 encoder and decoder.
]]
serde.json5 = (nil :: any) :: JsonEncoder;

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
