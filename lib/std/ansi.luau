--!strict
--!optimize 2

local function Color256Fn(set: number): (code: number) -> string
    return function (code: number): string
        if (code < 0 or code > 255) then
            error("Code must be between 0 to 255", 2)
        end
        return string.format(`\x1b[{set};5;%dm`, code)
    end
end

local function TrueColorFn(set: number): (r: number, g: number, b: number) -> string
    return function (r: number, g: number, b: number): string
        if (r < 0 or r > 255) then
            error("R must be between 0 to 255", 2)
        end
        if (g < 0 or g > 255) then
            error("G must be between 0 to 255", 2)
        end
        if (b < 0 or b > 255) then
            error("B must be between 0 to 255", 2)
        end
        return string.format(`\x1b[{set};2;%d;%d;%dm`, r, g, b)
    end
end

local CursorMoveTemplates = {
    home = "\x1b[H",
    goto = "\x1b[%d;%dH",
    up = "\x1b[%dA",
    down = "\x1b[%dB",
    right = "\x1b[%dC",
    left = "\x1b[%dD",
    nextline = "\x1b[%dE",
    prevline = "\x1b[%dF",
    gotocol = "\x1b[%dG"
}

local function cursorMove(action: string, ...): string
    local template = CursorMoveTemplates[action]
    if (not template) then
        return error("UnknownKind", 2)
    end
    return string.format(template, ...)
end

local EraseTemplates = {
    endOf = "\x1b[0J",
    startOf = "\x1b[1J",
    entire = "\x1b[2J",
    savedLines = "\x1b[3J",
    endOfLine = "\x1b[0K",
    startOfLine = "\x1b[1K",
    entireLine = "\x1b[2K"
};

local function erase(erase: "endOf" | "startOf" | "entire" | "savedLines" | "endOfLine" | "startOfLine" | "entireLine"): string
    return EraseTemplates[erase] or error("UnknownKind", 2)
end

return {
    black = "\x1b[30m",
    red = "\x1b[31m",
    green = "\x1b[32m",
    yellow = "\x1b[33m",
    blue = "\x1b[34m",
    magenta = "\x1b[35m",
    cyan = "\x1b[36m",
    white = "\x1b[37m",
    bright_black = "\x1b[90m",
    bright_red = "\x1b[91m",
    bright_green = "\x1b[92m",
    bright_yellow = "\x1b[93m",
    bright_blue = "\x1b[94m",
    bright_magenta = "\x1b[95m",
    bright_cyan = "\x1b[96m",
    bright_white = "\x1b[97m",
    color256 = Color256Fn(38),
    trueColor = TrueColorFn(38),

    bg = {
        black = "\x1b[40m",
        red = "\x1b[41m",
        green = "\x1b[42m",
        yellow = "\x1b[43m",
        blue = "\x1b[44m",
        magenta = "\x1b[45m",
        cyan = "\x1b[46m",
        white = "\x1b[47m",
        bright_black = "\x1b[100m",
        bright_red = "\x1b[101m",
        bright_green = "\x1b[102m",
        bright_yellow = "\x1b[103m",
        bright_blue = "\x1b[104m",
        bright_magenta = "\x1b[105m",
        bright_cyan = "\x1b[106m",
        bright_white = "\x1b[107m",
        color256 = Color256Fn(48),
        trueColor = TrueColorFn(48),
    },
    
    dim = "\x1b[2m",
    bold = "\x1b[1m",
    italic = "\x1b[3m",
    underline = "\x1b[4m",
    blink = "\x1b[5m",
    inverse = "\x1b[7m",
    hidden = "\x1b[8m",
    strikethrough = "\x1b[9m",

    reset = "\x1b[0m",
    reset_bold = "\x1b[22m",
    reset_dim = "\x1b[22m",
    reset_italic = "\x1b[23m",
    reset_underline = "\x1b[24m",
    reset_blink = "\x1b[25m",
    reset_inverse = "\x1b[27m",
    reset_hidden = "\x1b[28m",
    reset_strikethrough = "\x1b[29m",
    reset_color = "\x1b[39m",
    reset_bgcolor = "\x1b[49m",

    cursorMove = (cursorMove :: any) :: ((action: "home") -> string)
        & ((action: "goto", line: number, column: number) -> string)
        & ((action: "up" | "down" | "right" | "left", amount: number) -> string)
        & ((action: "nextline", linesDown: number) -> string)
        & ((action: "prevline", linesUp: number) -> string)
        & ((action: "gotocol", column: number) -> string),
    
    erase = erase,
}
