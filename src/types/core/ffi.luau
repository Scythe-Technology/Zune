export type Library = {
    close : (self: Library) -> (),
    [string]: (...any) -> any,
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

ffi.sizeOf = (nil :: any) :: (type: number) -> number;
ffi.alignOf = (nil :: any) :: any; -- TODO: Implement alignOf
ffi.eqlPtr = (nil :: any) :: (a: buffer, b: buffer) -> boolean;

ffi.intFromPtr = (nil :: any) :: (ptr: buffer, src: buffer) -> number;
ffi.valueFromPtr = (nil :: any) :: (ptr: buffer, type: number) -> any;

ffi.writeIntoPtr = (nil :: any) :: (destPtr: buffer, destOffset: number, src: buffer, srcOffset: number, size: number) -> ();

type LibraryDefinition = {
    returns: number,
    args: {number}
};

ffi.dlopen = (nil :: any) :: (path: string, { [string] : LibraryDefinition }) -> Library;

return ffi;
