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

        Flags:
          - `g`: Global
          - `m`: Multiline

        @param str String to capture
        @param flags Flags to use
        @return `{{RegexMatch}}`
    ]]
    captures : (self: Regex, str: string, flags: string?) -> {{RegexMatch}};
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

regex.new = (nil :: any) :: (pattern: string) -> Regex;

return regex;
