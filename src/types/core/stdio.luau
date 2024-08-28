local stdio = {};

--[[
    Generates escape sequence to move the cursor.

    @param action The action.
    @return string
]]
stdio.cursorMove = (nil :: any) ::
    & ((action: "home") -> string)
    & ((action: "goto", line: number, column: number) -> string)
    & ((action: "up" | "down" | "right" | "left", amount: number) -> string)
    & ((action: "nextline", linesDown: number) -> string)
    & ((action: "prevline", linesUp: number) -> string)
    & ((action: "gotocol", column: number) -> string);

--[[
    Generates escape sequence to erase text.

    @param erase The erase action.
    @return string
]]
stdio.erase = (nil :: any) :: ((erase: "endOf" | "startOf" | "entire" | "savedLines" | "endOfLine" | "startOfLine" | "entireLine") -> string);

--[[
    Generates style.

    @param action The action.
    @return string
]]
stdio.style = (nil :: any) :: (style: "bold" | "dim" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough") -> string;

--[[
    Resets styles.

    Optional style parameter to reset a specific style. Nil to reset all.

    @param style The style to reset.
    @return string
]]
stdio.reset = (nil :: any) ::
    & (() -> string)
    & ((style: "weight" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough" | "color") -> string);

type color = (color: "black" | "red" | "green" | "yellow" | "blue" | "magenta" | "cyan" | "white" | "bblack" | "bred" | "bgreen" | "byellow" | "bblue" | "bmagenta" | "bcyan" | "bwhite") -> string;

--[[
    Generates color.

    @param color The color.
    @return string
]]
stdio.color = (nil :: any) :: color;
--[[
    Generates background color.

    @param color The color.
    @return string
]]
stdio.bgcolor = (nil :: any) :: color;

--[[
    Generates color.

    @param code The color code.
    @return string
]]
stdio.color256 = (nil :: any) :: (code: number) -> string;
--[[
    Generates background color.

    @param code The color code.
    @return string
]]
stdio.bgcolor256 = (nil :: any) :: (code: number) -> string;

--[[
    Generates true color.

    @param r The red value.
    @param g The green value.
    @param b The blue value.
    @return string
]]
stdio.trueColor = (nil :: any) :: (r: number, g: number, b: number) -> string;
--[[
    Generates background true color.

    @param r The red value.
    @param g The green value.
    @param b The blue value.
    @return string
]]
stdio.bgtrueColor = (nil :: any) :: (r: number, g: number, b: number) -> string;

--[[
    Writes to stdout.

    @param text The text to write.
    @return string
]]
stdio.writeOut = (nil :: any) :: (text: string) -> ();
--[[
    Writes to stderr.

    @param text The text to write.
    @return string
]]
stdio.writeErr = (nil :: any) :: (text: string) -> ();
--[[
    Reads from stdin.

    Optional amount parameter to read a specific amount of bytes. Nil to read all.

    @param amount The amount of text to read.
    @return string
]]
stdio.readIn = (nil :: any) :: (amount: number?) -> string;

return stdio;