local stdio = {};

stdio.MAX_READ = (nil :: any) :: number;

--[[
    Generates escape sequence to move the cursor.

    @param action The action.
    @return `string`
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
    @return `string`
]]
stdio.erase = (nil :: any) :: ((erase: "endOf" | "startOf" | "entire" | "savedLines" | "endOfLine" | "startOfLine" | "entireLine") -> string);

--[[
    Generates style.

    @param action The action.
    @return `string`
]]
stdio.style = (nil :: any) :: (style: "bold" | "dim" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough") -> string;

--[[
    Resets styles.

    Optional style parameter to reset a specific style. Nil to reset all.

    @param style The style to reset.
    @return `string`
]]
stdio.reset = (nil :: any) ::
    & (() -> string)
    & ((style: "weight" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough" | "color") -> string);

type color = (color: "black" | "red" | "green" | "yellow" | "blue" | "magenta" | "cyan" | "white" | "bblack" | "bred" | "bgreen" | "byellow" | "bblue" | "bmagenta" | "bcyan" | "bwhite") -> string;

--[[
    Generates color.

    @param color The color.
    @return `string`
]]
stdio.color = (nil :: any) :: color;
--[[
    Generates background color.

    @param color The color.
    @return `string`
]]
stdio.bgcolor = (nil :: any) :: color;

--[[
    Generates color.

    @param code The color code.
    @return `string`
]]
stdio.color256 = (nil :: any) :: (code: number) -> string;
--[[
    Generates background color.

    @param code The color code.
    @return `string`
]]
stdio.bgcolor256 = (nil :: any) :: (code: number) -> string;

--[[
    Generates true color.

    @param r The red value.
    @param g The green value.
    @param b The blue value.
    @return `string`
]]
stdio.trueColor = (nil :: any) :: (r: number, g: number, b: number) -> string;
--[[
    Generates background true color.

    @param r The red value.
    @param g The green value.
    @param b The blue value.
    @return `string`
]]
stdio.bgtrueColor = (nil :: any) :: (r: number, g: number, b: number) -> string;

export type Terminal = {
    --[[
        Whether the terminal is a TTY.
    ]]
    isTTY : boolean;

    --[[
        Enable raw mode.

        On unix: Will attempt to change terminal mode.
        On windows: Will attempt to change console mode.

        @return `boolean` Whether the mode was successfully changed.
    ]]
    enableRawMode : (self: Terminal) -> boolean;

    --[[
        Restore terminal mode.

        On unix: Will attempt to restore the original terminal mode.
        On windows: Will attempt to restore the original console mode.

        @return `boolean` Whether the mode was successfully restored.
    ]]
    restoreMode : (self: Terminal) -> boolean;


    --[[
        Get the terminal size.

        *Will return `nil` if the terminal is not TTY.*

        *Will **error** if there was an issue getting the terminal size.*

        @return `number` The width of the terminal.
        @return `number` The height of the terminal.
    ]]
    getSize : (self: Terminal) -> (number, number);
};

export type StdWriter = {
    --[[
        Write text to the writer.

        @param `text` The text to write.
    ]]
    write : (text: string | buffer) -> ();
};

export type StdReader = {
    --[[
        Read text from the reader.

        Optional `amount`, defaults to `1`.
        
        @param amount The amount of characters to read.
        @return `string`
    ]]
    read : (amount: number?) -> string;
};

--[[
    Terminal.
]]
stdio.terminal = (nil :: any) :: Terminal;
--[[
    stdout writer.
]]
stdio.stdout = (nil :: any) :: StdWriter;
--[[
    stderr writer.
]]
stdio.stderr = (nil :: any) :: StdWriter;
--[[
    stdin reader.
]]
stdio.stdin = (nil :: any) :: StdReader;

return stdio;