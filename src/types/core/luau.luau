export type CompileOptions = {
    debug_level : number?,
    optimization_level : number?,
    coverage_level : number?,
}

export type LoadOptions = {
    env : {[any]: any}?,
    chunkName : string?,
    nativeCodeGen : boolean?,
}

local luau = {}

--[[
    Compiles Luau source code.
    
    @param source The source code to compile.
    @param options The options for the compilation.
    @return boolean Whether the operation was successful.
    @return string The compiled code, or an error.
]]
luau.compile = (nil :: any) :: (source: string, options: CompileOptions?) -> (boolean, string);

--[[
    Loads Luau source code.

    *Notes:*
    - `nativeCodeGen` will be disabled if `env` field is not a regular table (non-metatable).
    - If `env` is not provided, it will default to the global environment.
        - If the global environment is an unsafe environment, `nativeCodeGen` will not work.
    - If `chunkName` is not provided, it will default to `(load)`.

    @param source The source code to load.
    @param options The options for the load.
    @return (...any) -> ...any The loaded function.
]]
luau.load = (nil :: any) :: (source: string, options: LoadOptions?) -> ((...any) -> ...any);

return luau;
