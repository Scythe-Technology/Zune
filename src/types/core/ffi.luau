export type Library = {
    close : (self: Library) -> (),
    [string]: (...any) -> any,
};

export type Structure = {
    size : (self: Structure) -> number,
    alignment : (self: Structure) -> number,
    offset : (self: Structure, field: string) -> number,
    new : (self: Structure, fields: {{ [string]: buffer | number }}) -> buffer,
};

export type Closure = {
    ptr : Pointer,
    callback : (...any) -> any,
}

export type FunctionDefinition = {
    returns : Structure | number,
    args : { Structure | number }
};

export type Pointer = {
    release : (self: Pointer) -> Pointer,
    retain : (self: Pointer) -> Pointer,
    drop : (self: Pointer) -> (),
    offset : (self: Pointer, offset: number) -> Pointer,
    read : (self: Pointer, srcOffset: number, dest: buffer, destOffset: number, count: number) -> buffer,
    write : (self: Pointer, destOffset: number, src: buffer, srcOffset: number, count: number) -> (),
    readi8 : (self: Pointer, offset: number?) -> number,
    readu8 : (self: Pointer, offset: number?) -> number,
    readi16 : (self: Pointer, offset: number?) -> number,
    readu16 : (self: Pointer, offset: number?) -> number,
    readi32 : (self: Pointer, offset: number?) -> number,
    readu32 : (self: Pointer, offset: number?) -> number,
    readi64 : (self: Pointer, offset: number?) -> buffer,
    readu64 : (self: Pointer, offset: number?) -> buffer,
    readf32 : (self: Pointer, offset: number?) -> number,
    readf64 : (self: Pointer, offset: number?) -> number,
    readPtr : (self: Pointer, offset: number?) -> Pointer,
    writei8 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writeu8 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writei16 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writeu16 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writei32 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writeu32 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writei64 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writeu64 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writef32 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writef64 : (self: Pointer, offset: number, value: number | buffer) -> (),
    writePtr : (self: Pointer, offset: number, value: Pointer) -> (),
    isNull : (self: Pointer) -> boolean,
    setSize : (self: Pointer, size: number) -> (),
    span : (self: Pointer, offset: number?) -> buffer,

};

local ffi = {}

ffi.supported = (nil :: any) :: boolean;

ffi.prefix = (nil :: any) :: string;
ffi.suffix = (nil :: any) :: string;

ffi.types = (nil :: any) :: {
    void : number,
    i8 : number,
    u8 : number,
    i16 : number,
    u16 : number,
    i32 : number,
    u32 : number,
    i64 : number,
    u64 : number,
    float : number,
    double : number,
    pointer : number,
};

ffi.sizeOf = (nil :: any) :: (type: Structure | number) -> number;
ffi.alignOf = (nil :: any) :: (type: Structure | number) -> number;

ffi.createPtr = (nil :: any) :: (src: buffer) -> Pointer;
ffi.getRef = (nil :: any) :: (src: Pointer) -> Pointer;

ffi.alloc = (nil :: any) :: (size: number) -> Pointer;
ffi.free = (nil :: any) :: (src: Pointer) -> ();
ffi.dupe = (nil :: any) :: (src: buffer | Pointer) -> Pointer;
ffi.len = (nil :: any) :: (src: buffer | Pointer) -> number?;
ffi.copy = (nil :: any) :: (dest: buffer | Pointer, destOffset: number, src: buffer | Pointer, srcOffset: number, count: number) -> ();

ffi.struct = (nil :: any) :: (fields: {{ [string]: Structure | number }}) -> Structure;
ffi.call = (nil :: any) :: (definition: FunctionDefinition, srcPtr: Pointer, ...any) -> any;
ffi.closure = (nil :: any) :: (definition: FunctionDefinition, handler: (...any) -> any) -> Closure;
ffi.dlopen = (nil :: any) :: (path: string, { [string] : FunctionDefinition }) -> Library;

return ffi;
