type HashFn = (str: string) -> string;
type HmacFn = (str: string, key: string) -> string;

type HashAlgorithms<F> = {
    sha1 : F,
    md5 : F,
    blake3 : F,
    sha2 : {
        sha224 : F,
        sha256 : F,
        sha384 : F,
        sha512 : F,
    },
    sha3 : {
        sha3_224 : F,
        sha3_256 : F,
        sha3_384 : F,
        sha3_512 : F,
    },
    blake2 : {
        b128 : F,
        b160 : F,
        b256 : F,
        b512 : F,
        s128 : F,
        s160 : F,
        s224 : F,
        s256 : F,
    },
};

type BcryptPasswordOptions = {
    --- Default: "argon2d"
    algorithm : "bcrypt"?,
    --[[
        Default: 4
        
        Only between 4 and 31
    ]]
    cost : number?,
};

type Argon2PasswordOptions = {
    --- Default: "argon2d"
    algorithm : ("argon2d" | "argon2i" | "argon2id")?,
    --- Default: 2
    timeCost : number?,
    --- Default: 65536
    memoryCost : number?,
};

type PasswordOptions = BcryptPasswordOptions | Argon2PasswordOptions;

type EncryptedAes = {
    cipher : string,
    tag : string,
};

local crypto = {}

--[[
    Hash functions
]]
crypto.hash = (nil :: any) :: HashAlgorithms<HashFn>

--[[
    HMAC functions
]]
crypto.hmac = (nil :: any) :: HashAlgorithms<HmacFn>;

--[[
    Password hashing function
]]
crypto.password = (nil :: any) :: {
    hash: (password: string, options: PasswordOptions?) -> string,
    verify: (password: string, hash: string) -> boolean,
};

--[[
    Cryptographically secure random number generation.
]]
crypto.random = (nil :: any) :: {
    --[[
        Generates a random number (f64), if no arguments are provided, it will generate a number between 0 and 1.
    ]]
    nextNumber : 
        & (() -> number)
        & ((min: number, max: number) -> number),
    --[[
        Generates a random integer (i32), if no arguments are provided,
        
        it will generate a number between the limits of a signed 32-bit integer.
    ]]
    nextInteger : 
        & (() -> number)
        & ((min: number, max: number) -> number),
    
    --[[
        Generates a random boolean.
    ]]
    nextBoolean : () -> boolean,

    --[[
        Writes random bytes to the buffer.
    ]]
    fill : (buffer: buffer, offset: number, length: number) -> (),
};

--[[
    AES encryption and decryption.
]]
crypto.aes = (nil :: any) :: {
    aes128 : {
        encrypt : (data: string | buffer, key: string | buffer, nonce: string | buffer) -> EncryptedAes,
        decrypt : (cipher: string | buffer, tag: string | buffer, key: string | buffer, nonce: string | buffer) -> string,
    },
    aes256 : {
        encrypt : (data: string | buffer, key: string | buffer, nonce: string | buffer) -> EncryptedAes,
        decrypt : (cipher: string | buffer, tag: string | buffer, key: string | buffer, nonce: string | buffer) -> string,
    },
};

return crypto;
