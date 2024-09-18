export type RegexMatch = {
    --[[
        The captured group.
    ]]
    string : string;
    --[[
        The index of the group.
    ]]
    index : number;
};

export type Regex = {
    --[[
        Match a string.

        @param str String to match
    ]]
    match : (self: Regex, str: string) -> {RegexMatch}?;
    --[[
        Search a string.

        @param str String to search
    ]]
    search : (self: Regex, str: string) -> {RegexMatch}?;
    --[[
        Capture a string.

        *If global is nil, it will default to false.*

        @param str String to capture
        @param global Whether to capture globally
        @return `{{RegexMatch}}`
    ]]
    captures : (self: Regex, str: string, global: boolean?) -> {{RegexMatch}};
    --[[
        Check if a string matches the pattern.

        @param str String to check
    ]]
    isMatch : (self: Regex, str: string) -> boolean;
    --[[
        Format a string.

        @param str String to format
        @param format Format to use
    ]]
    format : (self: Regex, str: string, format: string) -> string;
    --[[
        Replace the first occurrence of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replace : (self: Regex, str: string, replacement: string) -> string;
    --[[
        Replace all occurrences of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replaceAll : (self: Regex, str: string, replacement: string) -> string;
};

local regex = {};

--[[
    Create a new regex object.

    Flags:
      - `i`: Case insensitive
      - `m`: Multiline

    @param pattern Pattern to use
    @param flags Flags to use
]]
regex.new = (nil :: any) :: (pattern: string, flags: string?) -> Regex;

return regex;
