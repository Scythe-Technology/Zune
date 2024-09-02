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
    ]]
    match : (self: Regex, str: string) -> {RegexMatch}?;
    --[[
        Search a string.
    ]]
    search : (self: Regex, str: string) -> {RegexMatch}?;
    --[[
        Check if a string matches the pattern.
    ]]
    isMatch : (self: Regex, str: string) -> boolean;
    --[[
        Format a string.
    ]]
    format : (self: Regex, str: string, replacement: string) -> string;
    --[[
        Replace the first occurrence of a string.
    ]]
    replace : (self: Regex, str: string, replacement: string) -> string;
    --[[
        Replace all occurrences of a string.
    ]]
    replaceAll : (self: Regex, str: string, replacement: string) -> string;
};

local regex = {};

regex.new = (nil :: any) :: (pattern: string) -> Regex;

return regex;
