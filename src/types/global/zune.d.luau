--  https://github.com/JohnnyMorganz/luau-lsp/issues/271

declare _FILE: {
    name: string,
    path: string,
    source: string,
}

--[======[ FileSystem ]======]--
export type MetadataKind = "file"
    | "dir"
    | "symlink"
    | "door"
    | "character_device"
    | "unix_domain_socket"
    | "block_device"
    | "event_port"
    | "named_pipe"
    | "whiteout"
    | "unknown"

export type Metadata = {
    kind: MetadataKind,
    symlink: boolean,
    createdAt: number,
    modifiedAt: number,
    accessedAt: number,
    size: number,
    permissions: {
        readOnly: boolean,
    },
}

export type FileHandle = {
    --[[
        Reads the contents of a file.

        *Optional: The amount of bytes to read, if nil, reads the whole till EOF or Luau limit.*

        @param amount The amount of bytes to read.
    ]]
    read:
        & ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
        & ((self: FileHandle, amount: number?, useBuffer: true) -> buffer),


    --[[
        Writes to a file.

        @param contents The contents to write to the file.
    ]]
    write: (self: FileHandle, contents: buffer | string) -> (),

    --[[
        Appends to a file.

        @param contents The contents to append to the file.
    ]]
    append: (self: FileHandle, contents: buffer | string) -> (),

    --[[
        Returns the size of the file. Based on current state of the file object.
    ]]
    getSize: (self: FileHandle) -> number,

    --[[
        Returns the current position of the file.
    ]]
    getSeekPosition: (self: FileHandle) -> number,

    --[[
        Seeks to a position in the file relative to the end.

        *Optional: The amount of bytes to seek, if nil, seeks to the end*

        @param amount The amount of bytes to seek.
    ]]
    seekFromEnd: (self: FileHandle, amount: number?) -> (),

    --[[
        Seeks to a position in the file absolute to the start.

        *Optional: The amount of bytes to seek, if nil, seeks to the start, 0*

        @param amount The amount of bytes to seek.
    ]]
    seekTo: (self: FileHandle, amount: number?) -> (),

    --[[
        Seeks to a position in the file relative to the current position.

        *Optional: The amount of bytes to seek, if nil, seeks to the next position, 1*

        *If `0` is provided, seek will not move.*

        @param amount The amount of bytes to seek.
    ]]
    seekBy: (self: FileHandle, amount: number?) -> (),

    --[[
        Locks the file.

        *Optional: The mode to lock the file, if nil, locks the file in exclusive mode.*

        @param lockMode The mode to lock the file.
    ]]
    lock: (self: FileHandle, lockMode: ("shared" | "exclusive" | "none")?) -> boolean,

    --[[
        Unlocks the file.
    ]]
    unlock: (self: FileHandle) -> (),

    --[[
        Flushes the file. Writes the contents to the disk.

        Does not yield, **blocks** process.
    ]]
    sync: (self: FileHandle) -> (),

    --[[
        Returns whether the file is readonly.

        *Optional: Whether to set the file to readonly, if nil, returns the current state.*

        @param enabled Whether to set the file to readonly.
    ]]
    readonly:
        & ((self: FileHandle) -> boolean)
        & ((self: FileHandle, enabled: boolean) -> ()),

    --[[
        Closes the file. (Will flush the file)
    ]]
    close: (self: FileHandle) -> (),
}

export type FileWatcher = {
    --[[
        Stops the watcher.
    ]]
    stop: (self: FileWatcher) -> (),
}

type CreateFileOptions = {
    --[[
        Whether to create the file in exclusive mode.

        *Default: false*
    ]]
    exclusive: boolean?,
}

type OpenFileOptions = {
    --[[
        The mode to open the file in.

        Available modes: `r`, `w`

        *Default: `rw`*
    ]]
    mode: string?,
}

type FileSystemLib = {
    --[[
        Creates a file.

        If exclusive is true, the operation will fail if the file already exists.

        @param path The path to the file.
        @param opts The options to create the file.
        @return `FileHandle` The file handle.
    ]]
    createFile: (path: string, opts: CreateFileOptions?) -> FileHandle,

    --[[
        Opens a file.

        *The file must exist*
        @param path The path to the file.
        @param opts The options to open the file.
        @return `FileHandle` The file handle.
        @error `ReadError`
    ]]
    openFile: (path: string, opts: OpenFileOptions?) -> FileHandle,

    --[[
        Reads the contents of a file.

        *The content could be limited*

        @param path The path to the file.
        @param useBuffer Whether to read the file as a buffer.
        @return `string | buffer` The contents of the file.
        @error
    ]]
    readFile:
        & ((path: string) -> string)
        & ((path: string, useBuffer: true) -> buffer),

    --[[
        Reads the contents of a directory.

        @param path The path to the directory.
        @return `{string} | string` The contents of the directory, or an error.
    ]]
    readDir: (path: string) -> { string },

    --[[
        Writes to a file.

        *The content could be limited*

        @param path The path to the file.
        @param contents The contents to write to the file.
        @return `FileWriteError` An error if the operation failed.
    ]]
    writeFile: (path: string, contents: buffer | string) -> (),

    --[[
        Creates a directory.

        @param path The path to the directory.
        @param recursive Whether to write recursively.
        @return `DirWriteError` An error if the operation failed.
    ]]
    writeDir:  (path: string, recursive: boolean?) -> (),

    --[[
        Deletes a file.

        @param path The path to the file.
        @return `FileRemoveError` An error if the operation failed.
    ]]
    removeFile: (path: string) -> (),

    --[[
        Deletes a directory.

        @param path The path to the directory.
        @param recursive Whether to delete recursively.
        @return `DirRemoveError` An error if the operation failed.
    ]]
    removeDir: (path: string, recursive: boolean?) -> (),

    --[[
        Returns the metadata of a file or directory.

        @param path The path to the file or directory.
        @return `Metadata` Nil or The metadata of the file or directory
    ]]
    metadata: (path: string) -> Metadata?,

    --[[
        Checks if a file exists.

        @param path The path to the file.
        @return `boolean` Whether the file exists.
    ]]
    isFile: (path: string) -> boolean,

    --[[
        Checks if a directory exists.

        @param path The path to the directory.
        @return `boolean` Whether the directory exists.
    ]]
    isDir: (path: string) -> boolean,

    --[[
        Moves a file or directory to a new location.

        @param from The path to the file or directory.
        @param to The path to rename the file or directory to.
        @param overwrite Whether to overwrite the file or directory if it exists.
    ]]
    move: (from: string, to: string, overwrite: boolean?) -> (),

    --[[
        Copies a file or directory to a new location.

        @param from The path to the file or directory.
        @param to The path to copy the file or directory to.
        @param overwrite Whether to overwrite the file or directory if it exists.
    ]]
    copy: (from: string, to: string, overwrite: boolean?) -> (),

    --[[
        Creates a symbolic link.

        *Currently **not** supported on `Windows`*

        @param from The path to the file or directory.
        @param to The path to create the symbolic link to.
    ]]
    symlink: (from: string, to: string) -> (),

    watch: (path: string, callback: (path: string, events: {"created" | "modified" | "moved" | "renamed" | "deleted" | "metadata"}) -> ()) -> FileWatcher,
}
--[======[ FileSystem ]======]--

--[======[ Process ]======]--
export type CPUArchitecture =
	| "aarch64"
	| "x86_64"
	-- | "x86"
	-- | "arm"
	-- | "aarch64_be"
	-- | "aarch64_32"
	-- | "riscv32"
	| "riscv64"
	-- | "wasm32"
	-- | "wasm64"
	-- | "armeb"
	-- | "arc"
	-- | "avr"
	-- | "bpfel"
	-- | "bpfeb"
	-- | "csky"
	-- | "dxil"
	-- | "hexagon"
	-- | "loongarch32"
	-- | "loongarch64"
	-- | "m68k"
	-- | "mips"
	-- | "mipsel"
	-- | "mips64"
	-- | "mips64el"
	-- | "msp430"
	-- | "powerpc"
	-- | "powerpcle"
	-- | "powerpc64"
	-- | "powerpc64le"
	-- | "r600"
	-- | "amdgcn"
	-- | "sparc"
	-- | "sparc64"
	-- | "sparcel"
	-- | "s390x"
	-- | "tce"
	-- | "tcele"
	-- | "thumb"
	-- | "thumbeb"
	-- | "xcore"
	-- | "xtensa"
	-- | "nvptx"
	-- | "nvptx64"
	-- | "le32"
	-- | "le64"
	-- | "amdil"
	-- | "amdil64"
	-- | "hsail"
	-- | "hsail64"
	-- | "spir"
	-- | "spir64"
	-- | "spirv"
	-- | "spirv32"
	-- | "spirv64"
	-- | "kalimba"
	-- | "shave"
	-- | "lanai"
	-- | "renderscript32"
	-- | "renderscript64"
	-- | "ve"
	-- | "spu_2"

export type OS =
	| "linux"
	| "windows"
	| "macos"
	-- | "freestanding"
	-- | "ananas"
	-- | "cloudabi"
	-- | "dragonfly"
	-- | "freebsd"
	-- | "fuchsia"
	-- | "ios"
	-- | "kfreebsd"
	-- | "lv2"
	-- | "netbsd"
	-- | "openbsd"
	-- | "solaris"
	-- | "uefi"
	-- | "zos"
	-- | "haiku"
	-- | "minix"
	-- | "rtems"
	-- | "nacl"
	-- | "aix"
	-- | "cuda"
	-- | "nvcl"
	-- | "amdhsa"
	-- | "ps4"
	-- | "ps5"
	-- | "elfiamcu"
	-- | "tvos"
	-- | "watchos"
	-- | "driverkit"
	-- | "visionos"
	-- | "mesa3d"
	-- | "contiki"
	-- | "amdpal"
	-- | "hermit"
	-- | "hurd"
	-- | "wasi"
	-- | "emscripten"
	-- | "shadermodel"
	-- | "liteos"
	-- | "serenity"
	-- | "opencl"
	-- | "glsl450"
	-- | "vulkan"
	-- | "plan9"
	-- | "illumos"
	-- | "other"

export type ProcessOptions = {
	cwd: string?,
	env: { [string]: string }?,
	shell: (boolean | string)?,
}

export type ProcessResult = {
	ok: boolean,
	code: number,
	status: "Exited" | "Stopped" | "Signal" | "Unknown",
}

export type ProcessRunResult = ProcessResult & {
	stdout: string,
	stderr: string,
}

declare class ProcessChild
    dead: boolean
    --[[
        Waits for the process to exit. Calls system function.

        Does not yield, **blocks** process.

        @return `ProcessResult`
    ]]
    function wait(self): ProcessResult
    --[[
        Kills process. Calls system function.

        Does not yield, **blocks** process.

        @return `ProcessResult`
    ]]
    function kill(self): ProcessResult

    --[[
        Reads the output of the process. Stdout.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return `string?`
    ]]
    function readOut(self, size: number?): string?
    --[[
        Reads the output of the process. Stdout.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return `string?`
    ]]
    function readOutAsync(self, size: number?): string
    --[[
        Writes to the input of the process. Stdin.

        @param data The data to write to the process.
    ]]
    function writeIn(self, data: string): ()
    --[[
        Reads the error output of the process. Stderr.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return `string?`
    ]]
    function readErr(self, size: number?): string?
    --[[
        Reads the error output of the process. Stderr.

        Optional size parameter to read a specific amount of bytes.
        Nil to read all.

        @param size The size of the output to read.
        @return `string?`
    ]]
    function readErrAsync(self, size: number?): string?
end

type ProcessLib = {
    --[[
        The os the process is running on.
    ]]
    os: OS,

    --[[
        The architecture of the processor running.
    ]]
    arch: CPUArchitecture,

    --[[
        The current working directory of the process.
    ]]
    cwd: string,

    --[[
        The arguments passed to the process.
    ]]
    args: { string },

    --[[
        The environment variables of the process.
        - Includes `.env` file in the current working directory.
        - Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
        - Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
        - Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
        - Includes `.env.local` file in the current working directory.
    ]]
    env: { [string]: string },

    --[[
        Loads the environment variables of the process.
        - Includes `.env` file in the current working directory.
        - Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
        - Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
        - Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
        - Includes `.env.local` file in the current working directory.

        @return `EnvironmentMap`
    ]]
    loadEnv: () -> { [string]: string },

    --[[
        Creates a new process.

        @param exec The executable to run.
        @param args The arguments to pass to the executable.
        @param procOpts The options for the process.
        @return `ProcessChild`
        @error `ProcessCreateError`
    ]]
    create: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessChild,

    --[[
        Runs a new process.

        Blocks the current process until the process has exited.

        We recommend using `process.create` for non-blocking process creation.

        @param exec The executable to run.
        @param args The arguments to pass to the executable.
        @param procOpts The options for the process.
        @return `ProcessRunResult`
        @error `ProcessRunError`
    ]]
    run: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessRunResult,

    --[[
        Exits the current process with the given exit code.

        @param code
    ]]
    exit: (code: number) -> never,

    --[[
        Registers a signal handler.

        @param signal The signal to handle.
        @param callback The callback to run when the signal is received.
    ]]
    onSignal: (signal: "INT", callback: () -> ()) -> (),
}
--[======[ Process ]======]--

--[======[ Testing ]======]--
type BasicCases = {
    --[[
        Expects the value to be equal to the expected value.

        @param expected The expected value.
    ]]
    toBe: (expected: any) -> (),
    --[[
        Expects the value to be defined.
    ]]
    toBeDefined: () -> (),
    --[[
        Expects the value to be close to the expected value.

        Formula: `abs(value - expected) < 10 ^ -precision`

        #### Example
        ```luau
        expect(1.1).toBeCloseTo(1, -1) -- Within 5
        expect(1.1).toBeCloseTo(1, 0) -- Within 0.5
        expect(1.1).toBeCloseTo(1, 1) -- Within 0.05
        expect(1.1).toBeCloseTo(1, 2) -- Within 0.005
        ```

        @param expected The expected value.
        @param precision The precision of the comparison.
    ]]
    toBeCloseTo: (expected: number, precision: number) -> (),
    --[[
        Expects the value to be greater than the expected value.

        @param expected The expected value.
    ]]
    toBeGreaterThan: (expected: number) -> (),
    --[[
        Expects the value to be greater than or equal to the expected value.

        @param expected The expected value.
    ]]
    toBeGreaterThanOrEqual: (expected: number) -> (),
    --[[
        Expects the value to be less than the expected value.

        @param expected The expected value.
    ]]
    toBeLessThan: (expected: number) -> (),
    --[[
        Expects the value to be less than or equal to the expected value.

        @param expected The expected value.
    ]]
    toBeLessThanOrEqual: (expected: number) -> (),
    --[[
        Expects the value to be nil.
    ]]
    toBeNil: () -> (),
    --[[
        Expects the value to be not a number.
    ]]
    toBeNan: () -> (),
    --[[
        Expect the length of the value to be equal to the expected length.

        - Tables
        - Strings

        @param expected The expected length
    ]]
    toHaveLength: (expected: number) -> (),
    --[[
        Expects the value to be falsy.

        False or nil.
    ]]
    toBeFalsy: () -> (),
    --[[
        Expects the value to be truthy.

        True or non nil.
    ]]
    toBeTruthy: () -> (),
}

type ExpectCases = BasicCases & {
    --[[
        never

        Flipped expectations.
    ]]
    never: BasicCases,
}

type FunctionalCases = ExpectCases & {
    --[[
        toThrow

        Expects a function to throw an error.

        Optionally, the error message can be checked.

        @param expected The expected error message.
    ]]
    toThrow: (expected: string?) -> (),
}

type ExpectHandler = {
    --[[
        [Jest compatibliity]: `expect.any(type)`

        Recommend using `expect.type` instead.

        Expects a value to be a type.
    ]]
    any: (type: string) -> any,

    --[[
        Expects a value to be a type.
    ]]
    type: (type: "nil" | "boolean" | "number" | "string" | "function" | "table" | "userdata" | "thread" | "buffer" | "vector") -> any,

    --[[
        Expects a value to be similar to the expected table.

        @param expected The expected table.
    ]]
    similar: (expected: {[any]: any}) -> any,
}

type TestingLib = {
    --[[
        Whether the testing suite is running.
    ]]
    running: boolean,

    --[[
        [Internal]

        The number of tests that have failed.
    ]]
    _FAILED: number,

    --[[
        [Internal]

        The number of tests conducted.
    ]]
    _COUNT: number,

    --[[
        [Internal]

        The number of tests that have passed.
    ]]
    _START: number,

    --[[
        Conducts a test.

        *Will be ignored if the testing suite is not running.*

        @param name The name of the test.
        @param callback The callback to run the test.
    ]]
    test: (name: string, callback: () -> ()) -> (),

    --[[
        Describes a test suite.

        *Will be ignored if the testing suite is not running.*

        @param name The name of the suite.
        @param callback The callback to run the suite.
    ]]
    describe: (name: string, callback: () -> ()) -> (),

    --[[
        Defers a function.

        Deferred function will be executed after a test completes.
        Useful for cleaning up resources.

        @param callback The callback to defer.
    ]]
    defer: (fn: () -> ()) -> (),

    --[[
        Expects a value.

        @param value The value to expect.
        @return Handler for expectations.
    ]]
    expect: ((value: (...any) -> ...any) -> FunctionalCases) & ((value: any) -> ExpectCases) & ExpectHandler,

    --[[
        Expects a value to be true or non nil.

        Similar to `assert(value)`

        @param value The value to expect.
    ]]
    expected: (value: any) -> (),

    --[[
        Expects a value to equal another.

        Similar to `assert(value == expected, ...)`

        @param expected The expected value.
        @param value The value to test.
    ]]
    expectEqual: ((expected: any, value: any) -> ()),
}
--[======[ Testing ]======]--

--[======[ Task ]======]--
type TaskLib = {
    --[[
        Cancels a task.

        @param thread The task to cancel.
    ]]
    cancel: (thread: thread) -> (),

    --[[
        Defers a task.

        Runs on next frame.

        @param f The function to defer.
        @return `thread`
    ]]
    defer: <A..., R...>(f: ((A...) -> R...) | thread, A...) -> thread,

    --[[
        Delays a task.

        Runs after a certain amount of time.

        @param sec The time to delay.
        @param f The function to delay.
        @return `thread`
    ]]
    delay: <A..., R...>(sec: number, f: ((A...) -> (R...)) | thread, A...) -> thread,

    --[[
        Spawns a task.

        Runs immediately.

        @param f The function to spawn.
        @return `thread`
    ]]
    spawn: <A..., R...>(f: ((A...) -> (R...)) | thread, A...) -> thread,

    --[[
        Sleeps task.

        Yields caller.
        Resumes after a certain amount of time.

        @param sec The time to wait.
        @return `number`
    ]]
    wait: (sec: number?) -> number,

    --[[
        Counts the number of tasks.

        Optional kinds parameter to count a specific kind of task.

        Kinds:
        - `s` to count sleeping tasks.
        - `d` to count deferred tasks.
        - `w` to count awaiting tasks. (Zune backend)
        - `t` to count internal tasks. (Zune backend)

        #### Example

        ```luau
        task.defer(function() end)
        task.spawn(function() task.wait(1) end)
        print(task.count("sd")) -- 2
        print(task.count("d")) -- 1
        print(task.count()) -- 2
        ```

        @param kinds The kinds of tasks to count.
        @return `number` | `...number`
    ]]
    count: (() -> number) & ((kinds: string?) -> ...number),
}
--[======[ Task ]======]--

--[======[ Network ]======]--
declare class NetWebSocket
    --[[
        Whether the websocket is connected.
    ]]
    connected: boolean

    --[[
        Sends a message to the websocket.
    ]]
    function send(self, message: string | buffer): ()

    --[[
        Closes the websocket.
    ]]
    function close(self): ()
end

declare class NetUDPSocket
    --[[
        Port used
    ]]
    port: number
    --[[
        Whether the socket is active
    ]]
    stopped: boolean
    --[[
        Send a UDP datagram message to remote host.
    ]]
    function send(self, message: string | buffer, port: number, address: string): ()
    --[[
        Stops the Socket.
    ]]
    function stop(self): ()
end

declare class NetTCPConnection
    --[[
        Whether the socket is active
    ]]
    stopped: boolean
    --[[
        Send a message to remote host.
    ]]
    function send(self, message: string | buffer): ()
    --[[
        Stops the socket.
    ]]
    function close(self): ()
end

declare class NetTCPServer
    --[[
        Whether the socket is active
    ]]
    stopped: boolean
    --[[
        Stops the socket.
    ]]
    function stop(self): ()
end

declare class NetServerHandle
    --[[
        Whether the socket is active
    ]]
    stopped: boolean

    --[[
        Stops the server.
    ]]
    function stop(self): ()
end

export type ServerRequest = {
    method: string,
    path: string,
    query: {[string]: string},
    headers: {[string]: string},
    body: string?,
}

export type ServerResponse = {
    statusCode: number,
    headers: {[string]: string}?,
    body: buffer | string,
}

export type ServerWebSocketHandlers = {
    --[[
        Function to check if the request should be upgraded to a websocket.
        Should return true if the request should be upgraded.
        @return `boolean`
    ]]
    upgrade: ((request: ServerRequest) -> boolean)?,

    --[[
        A function event for when a websocket is opened.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    open: ((websocket: NetWebSocket) -> ())?,
    --[[
        A function event for when a websocket receives a message.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    message: ((websocket: NetWebSocket, message: string) -> ())?,
    --[[
        A function event for when a websocket is closed.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    close: ((websocket: NetWebSocket) -> ())?,
}

export type ServeOptions = {
    --[[
        The port to bind to.
    ]]
    port: number,

    --[[
        The address to bind to.
        - Default: `127.0.0.1`
    ]]
    address: string?,

    --[[
        Whether to reuse the address.
        - Useful for multi-threaded servers.

        Default: `false`
    ]]
    reuseAddress: boolean?,

    --[[
        The maximum body size to accept.
        - Default: `4096`
    ]]
    maxBodySize: number?,

    --[[
        The function to handle requests.
    ]]
    request: (request: ServerRequest) -> buffer | string | ServerResponse,

    --[[
        Functions to handle websockets.
    ]]
    webhook: ServerWebSocketHandlers?,
}

export type Response = {
    ok: boolean,
    statusCode: number,
    statusReason: string,
    headers: {[string]: string},
    body: string,
}

type BareRequestOptions = {
    method: "GET",
    headers: {[string]: string}?,

    --[[
            Whether to follow redirects.
            - Default: `true`
        ]]
        allowRedirects: boolean?,

        --[[
            The maximum body size to accept.
            - Default: `2097152`
        ]]
        maxBodySize: number?,
}

type BodyRequestOptions = {
    method: "POST" | "PUT" | "DELETE",
    headers: {[string]: string}?,
    body: string,
}

export type RequestOptions = BareRequestOptions | BodyRequestOptions

export type WebSocketOptions = {
    --[[
        The protocols to use.
    ]]
    protocols: {string}?,
    --[[
        Timeout for the connection.

        *Default: 30*

        *Negative number for indefinite*
    ]]
    timeout: number?,
    --[[
        WebSocket open event.
    ]]
    open: ((socket: NetWebSocket) -> ())?,
    --[[
        WebSocket close event.
    ]]
    close: ((socket: NetWebSocket, close: number?) -> ())?,
    --[[
        WebSocket message event.
    ]]
    message: ((socket: NetWebSocket, message: string) -> ())?,
}

export type UDPSocketOptions = {
    --[[
        The port to bind to.

        *Nil or None lets the system pick.*
    ]]
    port: number?,

    --[[
        The address to bind to.
        - Default: `127.0.0.1`
    ]]
    address: string?,

    --[[
        Callback to handle UDP datagram
    ]]
    data: ((socket: NetUDPSocket, buffer: string, port: number, address: string) -> ())?,
}

export type TCPClientOptions = {
    --[[
        The port to connect with.
    ]]
    port: number,

    --[[
        The address to bind to.
    ]]
    address: string,

    --[[
        Callbacks for open event.
    ]]
    open: ((socket: NetTCPConnection) -> ())?,
    --[[
        Callbacks for data event.
    ]]
    data: ((socket: NetTCPConnection, buffer: string) -> ())?,
    --[[
        Callbacks for close event.
    ]]
    close: ((socket: NetTCPConnection) -> ())?,
}

export type TCPServerOptions = {
    --[[
        The port to bind to.

        *Nil or None lets the system pick.*
    ]]
    port: number?,

    --[[
        The address to bind to.

        *Default: `127.0.0.1`*
    ]]
    address: string?,

    --[[
        Whether to reuse the address.
        - Useful for multi-threaded servers.

        Default: `false`
    ]]
    reuseAddress: boolean?,

    --[[
        Callback for open event.
    ]]
    open: ((socket: NetTCPConnection) -> ())?,
    --[[
        Callback for data event.
    ]]
    data: ((socket: NetTCPConnection, buffer: string) -> ())?,
    --[[
        Callback for close event.
    ]]
    close: ((socket: NetTCPConnection) -> ())?,
}

type NetworkLib = {
    --[[
        Starts a server on the specified port.

        @param options The options for the server.
        @return `string | ServerHandle` The error message, or the server handle.
        @error `ServerStartError`
    ]]
    serve: (options: ServeOptions) -> NetServerHandle,

    --[[
        Makes a request to the specified host.

        Optional options, defaults to GET request.

        *TLS is supported.*

        @param host The host to make the request to.
        @param options The options for the request.
        @return `Response`
        @error `RequestError`
    ]]
    request: (host: string, options: RequestOptions?) -> Response,

    --[[
        Creates a websocket client.

        *TLS is supported.*

        @param host The host to connect to.
        @param opts The options for the websocket.
        @return `ClientWebSocket`
        @error `WebSocketError`
    ]]
    websocket: (host: string, opts: WebSocketOptions) -> NetWebSocket,
    --[[
        Creates a UDP Socket.

        @param opts The options for the UDP Socket.
        @return `UDPSocket`
    ]]
    udpSocket: (opts: UDPSocketOptions) -> NetUDPSocket,

    --[[
        Creates a TCP Client.

        @param opts The options for the TCP Client.
        @return `TCPClient`
    ]]
    tcpConnect: (opts: TCPClientOptions) -> NetTCPConnection,

    --[[
        Creates a TCP Server.

        @param opts The options for the TCP Server.
        @return `TCPServer`
    ]]
    tcpHost: (opts: TCPServerOptions) -> NetTCPServer,
}
--[======[ Network ]======]--

--[======[ Luau ]======]--
export type CompileOptions = {
    debug_level: number?,
    optimization_level: number?,
    coverage_level: number?,
}

export type LoadOptions = {
    env: {[any]: any}?,
    chunkName: string?,
    nativeCodeGen: boolean?,
}

type LuauLib = {
    --[[
        Compiles Luau source code.

        @param source The source code to compile.
        @param options The options for the compilation.
        @return `string` The compiled code, or an error.
        @error `CompileError`
    ]]
    compile: (source: string, options: CompileOptions?) -> string,

    --[[
        Loads Luau source code.

        *Notes:*
        - `nativeCodeGen` will be disabled if `env` field is not a regular table (non-metatable).
        - If `env` is not provided, it will default to the global environment.
            - If the global environment is an unsafe environment, `nativeCodeGen` will not work.
        - If `chunkName` is not provided, it will default to `(load)`.

        @param bytecode The bytecode to load.
        @param options The options for the load.
        @return `(...any) -> ...any` The loaded function.
    ]]
    load: (bytecode: string, options: LoadOptions?) -> ((...any) -> ...any),
}
--[======[ Luau ]======]--

--[======[ Serde ]======]--
export type JsonEncodeConfig = {
    --[[
        Pretty print indent level
    ]]
    prettyIndent: number,
}


export type JsonDecodeConfig = {
    --[[
        Preserve null values
    ]]
    preserveNull: boolean,
}

export type JsonEncoder = {
    --[[
        Encodes value to JSON/JSON5

        @param value The value to encode
        @param indent The indent level
        @return `string` The encoded JSON/JSON5
    ]]
    encode: (value: any, config: JsonEncodeConfig?) -> string,
    --[[
        Decodes JSON/JSON5

        @param json The JSON/JSON5 to decode
        @param config The configuration
        @return `any` The decoded value
    ]]
    decode: (json: string, config: JsonDecodeConfig?) -> any,

    --[[
        IndentKind for Pretty Printing
    ]]
    Indents: {
        None: number,
        TwoSpaces: number,
        FourSpaces: number,
        Tabs: number,
    },

    --[[
        Special values
    ]]
    Values: {
        Null: any,
    }
}

export type TomlEncoder = {
    --[[
        Encodes table to TOML

        @param object The table to encode
        @return `string` The encoded TOML
    ]]
    encode: (object: {[string]: any}) -> string,
    --[[
        Decodes TOML

        @param toml The TOML to decode
        @return `table` The decoded table
    ]]
    decode: (toml: string) -> {[string]: any},
}

export type YamlEncoder = {
    --[[
        Encodes table to YAML

        @param object The table to encode
        @return `string` The encoded YAML
    ]]
    encode: (object: {[string]: any}) -> string,
    --[[
        Decodes YAML

        @param yaml The YAML to decode
        @return `table` The decoded table
    ]]
    decode: (yaml: string) -> {[string]: any},
}

export type Base64Encoder = {
    --[[
        Encodes table to Base64

        @param value The value to encode
        @return `string` The encoded Base64
    ]]
    encode: (value: string) -> string,
    --[[
        Decodes Base64

        @param base64 The Base64 to decode
        @return `string` The decoded value
    ]]
    decode: (base64: string) -> string,
}

export type GenericCompressionOptions = {
    --[[
        The compression level.
    ]]
    level: number?,
}

export type GenericCompressor = {
    --[[
        Compresses a string.
    ]]
    compress :
        & ((raw: string, options: GenericCompressionOptions?) -> string)
        & ((raw: buffer, options: GenericCompressionOptions?) -> buffer),
    --[[
        Decompresses a string.
    ]]
    decompress :
        & ((compressed: string) -> string)
        & ((compressed: buffer) -> buffer),
}

type SerdeLib = {
    --[[
        JSON encoder and decoder.
    ]]
    json: JsonEncoder,

    --[[
        JSON5 encoder and decoder.
    ]]
    json5: JsonEncoder,

    --[[
        TOML encoder and decoder.
    ]]
    toml: TomlEncoder,

    --[[
        YAML encoder and decoder.
    ]]
    yaml: YamlEncoder,

    --[[
        BASE64 encoder and decoder.
    ]]
    base64: Base64Encoder,

    --[[
        GZIP compressor and decompressor.
    ]]
    gzip: GenericCompressor,

    --[[
        ZLIB compressor and decompressor.
    ]]
    zlib: GenericCompressor,

    --[[
        LZ4 compressor and decompressor.
    ]]
    lz4: GenericCompressor,
}
--[======[ Serde ]======]--

--[======[ Stdio ]======]--
export type Terminal = {
    --[[
        Whether the terminal is a TTY.
    ]]
    isTTY: boolean,

    --[[
        Enable raw mode.

        On unix: Will attempt to change terminal mode.
        On windows: Will attempt to change console mode.

        @return `boolean` Whether the mode was successfully changed.
    ]]
    enableRawMode: (self: Terminal) -> boolean,

    --[[
        Restore terminal mode.

        On unix: Will attempt to restore the original terminal mode.
        On windows: Will attempt to restore the original console mode.

        @return `boolean` Whether the mode was successfully restored.
    ]]
    restoreMode: (self: Terminal) -> boolean,


    --[[
        Get the terminal size.

        *Will return `nil` if the terminal is not TTY.*

        *Will **error** if there was an issue getting the terminal size.*

        @return `number` The width of the terminal.
        @return `number` The height of the terminal.
    ]]
    getSize: (self: Terminal) -> (number, number),
}

export type StdWriter = {
    --[[
        Write text to the writer.

        @param `text` The text to write.
    ]]
    write: (self: StdWriter, text: string | buffer) -> (),
}

export type StdReader = {
    --[[
        Read text from the reader.

        Optional `amount`, defaults to `1`.

        @param amount The amount of characters to read.
        @return `string`
    ]]
    read: (self: StdReader, amount: number?) -> string,
    --[[
        Read text from the reader.

        Optional `amount`, defaults to `1`.

        @param amount The amount of characters to read.
        @return `string`
    ]]
    readAsync: (self: StdReader, amount: number?) -> string,
}

type ColorFunction = (color: "black" | "red" | "green" | "yellow" | "blue" | "magenta" | "cyan" | "white" | "bblack" | "bred" | "bgreen" | "byellow" | "bblue" | "bmagenta" | "bcyan" | "bwhite") -> string

type StdioLib = {
    MAX_READ: number,

    --[[
        Generates escape sequence to move the cursor.

        @param action The action.
        @return `string`
    ]]
    cursorMove:
        & ((action: "home") -> string)
        & ((action: "goto", line: number, column: number) -> string)
        & ((action: "up" | "down" | "right" | "left", amount: number) -> string)
        & ((action: "nextline", linesDown: number) -> string)
        & ((action: "prevline", linesUp: number) -> string)
        & ((action: "gotocol", column: number) -> string),

    --[[
        Generates escape sequence to erase text.

        @param erase The erase action.
        @return `string`
    ]]
    erase: ((erase: "endOf" | "startOf" | "entire" | "savedLines" | "endOfLine" | "startOfLine" | "entireLine") -> string),

    --[[
        Generates style.

        @param action The action.
        @return `string`
    ]]
    style: (style: "bold" | "dim" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough") -> string,

    --[[
        Resets styles.

        Optional style parameter to reset a specific style. Nil to reset all.

        @param style The style to reset.
        @return `string`
    ]]
    reset:
        & (() -> string)
        & ((style: "weight" | "italic" | "underline" | "blinking" | "inverse" | "hidden" | "strikethrough" | "color") -> string),

    --[[
        Generates color.

        @param color The color.
        @return `string`
    ]]
    color: ColorFunction,
    --[[
        Generates background color.

        @param color The color.
        @return `string`
    ]]
    bgcolor: ColorFunction,

    --[[
        Generates color.

        @param code The color code.
        @return `string`
    ]]
    color256: (code: number) -> string,
    --[[
        Generates background color.

        @param code The color code.
        @return `string`
    ]]
    bgcolor256: (code: number) -> string,

    --[[
        Generates true color.

        @param r The red value.
        @param g The green value.
        @param b The blue value.
        @return `string`
    ]]
    trueColor: (r: number, g: number, b: number) -> string,
    --[[
        Generates background true color.

        @param r The red value.
        @param g The green value.
        @param b The blue value.
        @return `string`
    ]]
    bgtrueColor: (r: number, g: number, b: number) -> string,

    --[[
        Formats input to a readable string.

        @param ... The arguments to format.
        @return `string`
    ]]
    format: (...any) -> string,

    --[[
        Terminal.
    ]]
    terminal: Terminal,
    --[[
        stdout writer.
    ]]
    stdout: StdWriter,
    --[[
        stderr writer.
    ]]
    stderr: StdWriter,
    --[[
        stdin reader.
    ]]
    stdin: StdReader,
}
--[======[ Stdio ]======]--

--[======[ Crypto ]======]--
type HashFn = (str: string) -> string
type HmacFn = (str: string, key: string) -> string

type HashAlgorithms<F> = {
    sha1: F,
    md5: F,
    blake3: F,
    sha2: {
        sha224: F,
        sha256: F,
        sha384: F,
        sha512: F,
    },
    sha3: {
        sha3_224: F,
        sha3_256: F,
        sha3_384: F,
        sha3_512: F,
    },
    blake2: {
        b128: F,
        b160: F,
        b256: F,
        b384: F,
        b512: F,
        s128: F,
        s160: F,
        s224: F,
        s256: F,
    },
}

type BcryptPasswordOptions = {
    --- Default: "argon2d"
    algorithm: "bcrypt"?,
    --[[
        Default: 4

        Only between 4 and 31
    ]]
    cost: number?,
}

type Argon2PasswordOptions = {
    --- Default: "argon2d"
    algorithm: ("argon2d" | "argon2i" | "argon2id")?,
    --- Default: 2
    timeCost: number?,
    --- Default: 65536
    memoryCost: number?,
    --- Default: 1
    threads: number?,
}

type PasswordOptions = BcryptPasswordOptions | Argon2PasswordOptions

type EncryptedAes = {
    cipher: string,
    tag: string,
}

type CryptoLib = {
    --[[
        Hash functions
    ]]
    hash: HashAlgorithms<HashFn>,

    --[[
        HMAC functions
    ]]
    hmac: HashAlgorithms<HmacFn>,

    --[[
        Password hashing function
    ]]
    password: {
        hash: (password: string, options: PasswordOptions?) -> string,
        verify: (password: string, hash: string) -> boolean,
    },

    --[[
        Cryptographically secure random number generation.
    ]]
    random: {
        --[[
            Generates a random number (f64), if no arguments are provided, it will generate a number between 0 and 1.
        ]]
        nextNumber:
            & (() -> number)
            & ((min: number, max: number) -> number),
        --[[
            Generates a random integer (i32), if no arguments are provided,

            it will generate a number between the limits of a signed 32-bit integer.
        ]]
        nextInteger:
            & (() -> number)
            & ((min: number, max: number) -> number),

        --[[
            Generates a random boolean.
        ]]
        nextBoolean: () -> boolean,

        --[[
            Writes random bytes to the buffer.
        ]]
        fill: (buffer: buffer, offset: number, length: number) -> (),
    },

    --[[
        AES encryption and decryption.
    ]]
    aes: {
        aes128: {
            encrypt: (data: string | buffer, key: string | buffer, nonce: string | buffer) -> EncryptedAes,
            decrypt: (cipher: string | buffer, tag: string | buffer, key: string | buffer, nonce: string | buffer) -> string,
        },
        aes256: {
            encrypt: (data: string | buffer, key: string | buffer, nonce: string | buffer) -> EncryptedAes,
            decrypt: (cipher: string | buffer, tag: string | buffer, key: string | buffer, nonce: string | buffer) -> string,
        },
    },
}
--[======[ Crypto ]======]--

--[======[ Regex ]======]--
export type RegexMatch = {
    --[[
        The captured group.
    ]]
    string: string,
    --[[
        The index of the group.
    ]]
    index: number,
}

export type Regex = {
    --[[
        Match a string.

        @param str String to match
    ]]
    match: (self: Regex, str: string) -> {RegexMatch}?,
    --[[
        Search a string.

        @param str String to search
    ]]
    search: (self: Regex, str: string) -> {RegexMatch}?,
    --[[
        Capture a string.

        *If global is nil, it will default to false.*

        @param str String to capture
        @param global Whether to capture globally
        @return `{{RegexMatch}}`
    ]]
    captures: (self: Regex, str: string, global: boolean?) -> {{RegexMatch}},
    --[[
        Check if a string matches the pattern.

        @param str String to check
    ]]
    isMatch: (self: Regex, str: string) -> boolean,
    --[[
        Format a string.

        @param str String to format
        @param format Format to use
    ]]
    format: (self: Regex, str: string, format: string) -> string,
    --[[
        Replace the first occurrence of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replace: (self: Regex, str: string, replacement: string) -> string,
    --[[
        Replace all occurrences of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replaceAll: (self: Regex, str: string, replacement: string) -> string,
}

type RegexLib = {
    --[[
        Create a new regex object.

        Flags:
          - `i`: Case insensitive
          - `m`: Multiline

        @param pattern Pattern to use
        @param flags Flags to use
    ]]
    new: (pattern: string, flags: string?) -> Regex,
}
--[======[ Regex ]======]--

--[======[ Datetime ]======]--
export type TimeDictionary = {
    year: number,
    month: number,
    day: number,
    hour: number,
    minute: number,
    second: number,
    millisecond: number,
}

export type DateTime = {
    unixTimestamp: number,
    unixTimestampMillis: number,

    UnixTimestamp: number,
    UnixTimestampMillis: number,

    toLocalTime: (self: DateTime) -> TimeDictionary,
    ToLocalTime: (self: DateTime) -> TimeDictionary,

    toUniversalTime: (self: DateTime) -> TimeDictionary,
    ToUniversalTime: (self: DateTime) -> TimeDictionary,

    toIsoDate: (self: DateTime) -> string,
    ToIsoDate: (self: DateTime) -> string,

    formatLocalTime: (self: DateTime, format: string) -> string,
    FormatLocalTime: (self: DateTime, format: string) -> string,

    formatUniversalTime: (self: DateTime, format: string) -> string,
    FormatUniversalTime: (self: DateTime, format: string) -> string,
}

type DatetimeLib = {
    now: () -> DateTime,

    fromIsoDate: (date: string) -> DateTime,
    fromUnixTimestamp: (timestamp: number) -> DateTime,
    fromUnixTimestampMillis: (timestamp: number) -> DateTime,
    fromLocalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime,
    fromUniversalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime,

    parse: (date: string) -> DateTime,
}
--[======[ Datetime ]======]--

--[======[ FFI ]======]--
export type Library = {
    close: (self: Library) -> (),
    getSymbol: (self: Library, symbol: string) -> Pointer,
    [string]: (...any) -> any,
}

declare class Structure
    function size(self): number
    function alignment(self): number
    function offset(self, field: string): number
    function new(self, fields: {{ [string]: buffer | number }}): buffer
end

export type Closure = {
    ptr: Pointer,
    callback: (...any) -> any,
}

export type FunctionDefinition = {
    returns: Structure | number,
    args: { Structure | number }
}

export type Pointer = {
    release: (self: Pointer) -> Pointer,
    retain: (self: Pointer) -> Pointer,
    drop: (self: Pointer) -> Pointer,
    offset: (self: Pointer, offset: number) -> Pointer,
    read: (self: Pointer, srcOffset: number, dest: buffer | Pointer, destOffset: number, count: number) -> buffer,
    write: (self: Pointer, destOffset: number, src: buffer | Pointer, srcOffset: number, count: number) -> (),
    readi8: (self: Pointer, offset: number?) -> number,
    readu8: (self: Pointer, offset: number?) -> number,
    readi16: (self: Pointer, offset: number?) -> number,
    readu16: (self: Pointer, offset: number?) -> number,
    readi32: (self: Pointer, offset: number?) -> number,
    readu32: (self: Pointer, offset: number?) -> number,
    readi64: (self: Pointer, offset: number?) -> buffer,
    readu64: (self: Pointer, offset: number?) -> buffer,
    readf32: (self: Pointer, offset: number?) -> number,
    readf64: (self: Pointer, offset: number?) -> number,
    readPtr: (self: Pointer, offset: number?) -> Pointer,
    writei8: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writeu8: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writei16: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writeu16: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writei32: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writeu32: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writei64: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writeu64: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writef32: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writef64: (self: Pointer, offset: number, value: number | buffer | boolean) -> (),
    writePtr: (self: Pointer, offset: number, value: Pointer) -> (),
    isNull: (self: Pointer) -> boolean,
    setSize: (self: Pointer, size: number) -> (),
    span: (self: Pointer, offset: number?) -> buffer,
}

type FFILib = {
    supported: boolean,

    prefix: string,
    suffix: string,

    types: {
        void: number,
        i8: number,
        u8: number,
        i16: number,
        u16: number,
        i32: number,
        u32: number,
        i64: number,
        u64: number,
        float: number,
        double: number,
        pointer: number,
    },

    sizeOf: (type: Structure | number) -> number,
    alignOf: (type: Structure | number) -> number,

    createPtr: (src: buffer) -> Pointer,
    getRef: (src: Pointer) -> Pointer,

    alloc: (size: number) -> Pointer,
    free: (src: Pointer) -> (),
    dupe: (src: buffer | Pointer) -> Pointer,
    len: (src: buffer | Pointer) -> number?,
    copy: (dest: buffer | Pointer, destOffset: number, src: buffer | Pointer, srcOffset: number, count: number) -> (),

    struct: (fields: {{ [string]: Structure | number }}) -> Structure,
    fn: (definition: FunctionDefinition, srcPtr: Pointer) -> ((...any) -> any),
    closure: (definition: FunctionDefinition, handler: (...any) -> any) -> Closure,
    dlopen: (path: string, { [string]: FunctionDefinition }) -> Library,
}
--[======[ FFI ]======]--

--[======[ SQLite ]======]--

export type SQLite3Values = {[string]: number | string | buffer};
export type SQLite3Result = {
    lastInsertRowId: number,
    changes: number,
}

declare class SQLite3Statement
    function run(self, args: SQLite3Values?): SQLite3Result
    function get(self, args: SQLite3Values?): SQLite3Values?
    function all(self, args: SQLite3Values?): {SQLite3Values}
    function finalize(self): ()
end

declare class SQLite3Database
    transaction: <T...>(self: SQLite3Database, callback: (T...) -> (), kind: ("deferred" | "immediate" | "exclusive")?) -> ((T...) -> ())

    function query(self, query: string): SQLite3Statement
    function exec(self, query: string, args: SQLite3Values?): ()
    function close(self): ()
end

export type SQLiteLib = {
    --[[
        Opens a database.

        *Default: `:memory:`*

        @param path The path to the database.
        @return `SQLite3Database`
        @error `SQLite3Error`
    ]]
    open: (path: string?) -> SQLite3Database,
}
--[======[ SQLite ]======]--

declare zune: {
    fs: FileSystemLib,
    process: ProcessLib,
    testing: TestingLib,
    task: TaskLib,
    net: NetworkLib,
    luau: LuauLib,
    serde: SerdeLib,
    stdio: StdioLib,
    crypto: CryptoLib,
    regex: RegexLib,
    datetime: DatetimeLib,
    ffi: FFILib,
    sqlite: SQLiteLib,
}
