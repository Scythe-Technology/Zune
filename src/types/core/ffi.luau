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

export type LibraryDefinition = {
    returns: Structure | number,
    args: { Structure | number }
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
ffi.eqlPtr = (nil :: any) :: (a: buffer, b: buffer) -> boolean;

ffi.intFromPtr = (nil :: any) :: (ptr: buffer, src: buffer) -> buffer;
ffi.valueFromPtr = (nil :: any) :: (ptr: buffer, type: Structure | number) -> any;
ffi.readFromPtr = (nil :: any) :: (srcPtr: buffer, srcOffset: number, dest: buffer, destOffset: number, size: number) -> ();
ffi.spanFromPtr = (nil :: any) :: (srcPtr: buffer, srcOffset: number) -> buffer;

ffi.writeIntoPtr = (nil :: any) :: (destPtr: buffer, destOffset: number, src: buffer, srcOffset: number, size: number) -> ();

ffi.struct = (nil :: any) :: (fields: {{ [string]: Structure | number }}) -> Structure;
ffi.dlopen = (nil :: any) :: (path: string, { [string] : LibraryDefinition }) -> Library;

return ffi;
