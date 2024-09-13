# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- Added `openFile`, and `createFile` to `@zcore/fs`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/fs)

  Example:
    ```lua
    local fs = require("@zcore/fs")

    local file = fs.openFile("file.txt", {
      mode = "r" -- "rw" by default
    })
    file:close()
    local file = fs.createFile("file.txt", {
      exclusive = true -- false by default
    })
    ```

### Changed
- Updated `luau` to `0.642`.
- Updated `@zcore/process` to lock changing variables & allowed changing `cwd`.
  - Changing cwd would affect the global process cwd (even `fs` library).
  - Supports Relative and Absolute paths. `../` or `/`.
    - Relative paths are relative to the current working directory.

### Fixed
- Fixed `@zcore/net` with serve using `reuseAddress` option not working.

## `0.3.0` - September 1, 2024

### Added
- Added `stdin`, `stdout`, and `stderr` to `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/stdio)

  Example:
    ```lua
    local stdio = require("@zcore/stdio")

    stdio.stdin:read() -- read byte
    stdio.stdin:read(10) -- read 10 bytes
    stdio.stdout:write("Hello World!")
    stdio.stderr:write("Error!")
    ```
- Added `terminal` to `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/stdio)

  This should allow you to write more interactive terminal applications.
  
  *note*: If you have weird terminal output in windows, we recommend you to use `enableRawMode` to enable windows console `Virtual Terminal Processing`.

  Example:
    ```lua
    local stdio = require("@zcore/stdio")

    if (stdio.terminal.isTTY) then -- check if terminal is a TTY
      stdio.terminal.enableRawMode() -- enable raw mode
      stdio.stdin:read() -- read next input without waiting for newline
      stdio.terminal.restoreMode() -- return back to original mode before changes.
    end
    ```
- Added `@zcore/regex`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)

  Example:
    ```lua
    local regex = require("@zcore/regex")

    local pattern = regex.new("([A-Za-z\\s!])+")
    local match = pattern:match("Hello World!")
    print(match) --[[<table: 0x12345678> {
        [1] = <table: 0x2ccee88> {
            index = 0, 
            string = "Hello World!", 
        }, 
        [2] = <table: 0x2ccee58> {
            index = 11, 
            string = "!", 
        }, 
    }]]
    ```

### Changed
- Switched from build optimization from ReleaseSafe to ReleaseFast to improve performance.

  Luau should be faster now.

- REPL should now restore the terminal mode while executing lua code and return back to raw mode after execution.

- Removed `readIn`, `writeOut`, and `writeErr` functions in `@zcore/stdio`.

## `0.2.1` - August 31, 2024

### Added
- Added buffer support for `@net/server` body response. If a buffer is returned, it will be sent as the response body, works with `{ body = buffer, statusCode = 200 }`.
  
  Example:
    ```lua
    local net = require("@net/net")

    net.serve({
      port = 8080,
      request = function(req)
        return buffer.fromstring("Hello World!")
      end
    })
    ```
- Added buffer support for `@net/serde` in compress/decompress. If a buffer is passed, it will return a new buffer.
  
  Example:
    ```lua
    local serde = require("@net/serde")

    local compressed_buffer = serde.gzip.compress(buffer.fromstring("Zune"))
    print(compressed_buffer) -- <buffer: 0x12343567>
    ```

### Changed
- Updated backend luau module.

### Fixed
- Fixed Inaccurate luau types for `@zcore/net`.
- Fixed REPL not working after an error is thrown.

## `0.2.0` - August 30, 2024

### Added
- Added `repl` command.
  - Starts a REPL session.
  - Example:
    ```shell
    zune repl
    > print("Hello World!")
    ```
### Changed
- Updated `help` command to display the new `repl` command & updated `test` command description.

## `0.1.0` - August 29, 2024

### Added
- Added `@zcore/crypto` built-in library. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/crypto)

  Example:
  ```luau
  local crypto = require("@zcore/crypto")
  local hash = crypto.hash.sha2.sha256("Hello World!")
  local hmac = crypto.hmac.sha2.sha256("Hello World!", "private key")
  local pass_hash = crypto.password.hash("pass")

  print(crypto.password.verify("pass", pass_hash))
  ```

### Changed
- Partial backend code for print formating.
- Internal package.

## `0.0.5` - August 29, 2024

### Changed
- `--version` & `-V` will now display the version of luau.
  - format: `<name>: <version...>\n`
- Updated `luau` to `0.640`.
- `_VERSION` now includes major and minor version of `luau`.
  - format: `Zune <major>.<minor>.<patch>+<major>.<minor>`
- Partial backend code has been changed for `stdio`, `process`, `fs` and `serde` to use new C-Call handler.
  - Behavior should not change.
  - Performance should not change.

## `0.0.4` - August 28, 2024

### Added
- Added type for `riscv64` architecture in process.

## `0.0.3` - August 28, 2024

### Added
- Builds for Linux-Riscv64.

## `0.0.2` - August 28, 2024

### Added
- `help`, `--help` and `-h` command/flags to display help message.

### Changed

- Test traceback line styles uses regular characters, instead of unicode for Windows.
  - Fixes weird characters in Windows terminal.
- Running zune without params would default to `help` command.

### Fixed

- Some Luau type documentation with incorrect definitions.

## `0.0.1` - August 26, 2024

Initial pre-release.
