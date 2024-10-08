--  https://github.com/JohnnyMorganz/luau-lsp/issues/271

declare _FILE : {
    name: string,
    path: string,
    source: string,
};

--// PROCESS

export type ProcessResult = {
    ok: boolean,
    code: number,
    status: "Exited" | "Stopped" | "Signal" | "Unknown",
}

declare class ProcessChild
    --[[
        Waits for the process to exit. Calls system function.

        Does not yield, **blocks** process.

        @return ProcessResult
    ]]
    function wait(self): ProcessResult
    --[[
        Kills process. Calls system function.

        Does not yield, **blocks** process.

        @return ProcessResult
    ]]
    function kill(self): ProcessResult

    --[[
        Reads the output of the process. Stdout.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return string
    ]]
    function readOut(self, size : number?): string
    --[[
        Writes to the input of the process. Stdin.

        @param data The data to write to the process.
    ]]
    function writeIn(self, data : string): ()
    --[[
        Reads the error output of the process. Stderr.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return string
    ]]
    function readErr(self, size : number?): string
end

--// NETWORK

declare class NetWebSocket
    --[[
        Whether the websocket is connected.
    ]]
    connected : boolean

    --[[
        Sends a message to the websocket.
    ]]
    function send(self, message: string): ()

    --[[
        Closes the websocket.
    ]]
    function close(self): ()
end

declare class NetClientWebSocket extends NetWebSocket
    --[[
        Binds a function to the open event.
        
        *Only one function can be bound at a time*.
    ]]
    function bindOpen(self, func: () -> ()): ()
    --[[
        Binds a function to the message event.

        *Only one function can be bound at a time*.
    ]]
    function bindMessage(self, func: (message: string) -> ()): ()
    --[[
        Binds a function to the close event.

        *Only one function can be bound at a time*.
    ]]
    function bindClose(self, func: () -> ()): ()
end

declare class NetServerHandle
    --[[
        Closes the server.
    ]]
    function close(self): ()
end