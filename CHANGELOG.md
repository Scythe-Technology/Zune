# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- Added flags to `new` in regex. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)
  - `i` - Case Insensitive
  - `m` - Multiline
- Added zune configuration support as `zune.toml`.
- Added `init` command to generate config files.
- Added `luau` command to display luau info.
- Added partial tls support for `websocket` to `@zcore/net`.
- Added `readonly` method to `FileHandle` in `@zcore/fs`.
  - Nil to get state, boolean to set state.

### Changed
- Changed `captures` in regex to accept boolean instead of flags.
  - Boolean `true` is equivalent to `g` flag.
- Errors in required modules should now display their path relative to the current working directory.
- Updated required or ranned luau files to use optimization level 1, instead of 2.
- Updated `test` command to be like `run`.
  - If the first argument is `-`, it will read from stdin.
  - Fast search for file directly.
- Updated `luau` to `0.643`.
- Updated `help` command to display new commands.
- Updated `stdin` in `@zcore/stdio` to return nil if no data is available.
- Updated `websocket` in `@zcore/net` to properly return a boolean and an error string or userdata.
- Updated `request` in `@zcore/net` to timeout if request takes too long.

### Fixed
- Fixed `eval` requiring modules relative to the parent of the current working directory, instead of the current working directory.
- Fixed `require` casuing an error when requiring a module that returns nil.
- Fixed `websockets` yielding forever.
- Fixed threads under scheduler getting garbage collected.

## `0.4.0` - September 17, 2024

### Added
- Added `watch`, `openFile`, and `createFile` to `@zcore/fs`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/fs)

  Example:
    ```lua
    local fs = require("@zcore/fs")

    local watcher = fs.watch("file.txt", function(filename, events)
      print(filename, events)
    end)

    local ok, file = fs.createFile("file.txt", {
      exclusive = true -- false by default
    })
    assert(ok, file);
    file:close();
    local ok, file = fs.openFile("file.txt", {
      mode = "r" -- "rw" by default
    })
    assert(ok, file);
    file:close();

    watcher:stop();
    ```
- Added `eval` command. Evaluates the first argument as luau code.

  Example:
    ```shell
    zune --eval "print('Hello World!')"
    -- OR --
    zune -e "print('Hello World!')"
    ```
- Added stdin input to `run` command if the first argument is `-`.

  Example:
    ```shell
    echo "print('Hello World!')" | zune run -
    ```
- Added `--globals` flag to `repl` to load all zune libraries as globals too.
- Added `warn` global, similar to print but with a warning prefix.
- Added `random` and `aes` to `@zcore/crypto`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/crypto)

  Example:
    ```lua
    local crypto = require("@zcore/crypto")

    -- Random
    print(crypto.random.nextNumber()) -- 0.0 <= x < 1.0
    print(crypto.random.nextNumber(-100, 100)) -- -100.0 <= x < 100.0
    print(crypto.random.nextInteger(1, 10)) -- 1 <= x <= 10
    print(crypto.random.nextBoolean()) -- true or false

    local buf = buffer.create(2)
    crypto.random.fill(buf, 0, 2)
    print(buffer.readi16(buf, 0))-- random 16-bit integer

    -- AES
    local message = "Hello World!"
    local key = "1234567890123456" -- 16 bytes
    local nonce = "123456789012" -- 12 bytes
    local encrypted = crypto.aes.aes128.encrypt(message, key, nonce)
    local decrypted = crypto.aes.aes128.decrypt(encrypted.cipher, encrypted.tag, key, nonce)
    print(decrypted) -- "Hello World!"
    ```
- Added `getSize` method to `terminal` in `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)

  Example:
    ```lua
    local stdio = require("@zcore/stdio")
    
    if (stdio.terminal.isTTY) then
      local cols, rows = stdio.terminal:getSize()
      print(cols, rows) -- 80   24
    end
    ```
- Added `base64` to `@zcore/serde`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)

  Example:
    ```lua
    local serde = require("@zcore/serde")

    local encoded = serde.base64.encode("Hello World!")
    local decoded = serde.base64.decode(encoded)
    print(decoded) -- "Hello World!"
    ```
- Added `.luaurc` support. Alias requires should work.

  Example:
    ```json
    {
      "aliases": {
        "dev": "/path/to/dev",
        "globals": "/path/to/globals.luau"
      }
    }
    ```
    ```lua
    local module = require("@dev/module")
    local globals = require("@globals")
    ```
- Added `captures` method to `Regex` in `@zcore/regex`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)

  Flags
  - `g` - Global
  - `m` - Multiline

  Example:
    ```lua
    local regex = require("@zcore/regex")

    local pattern = regex.new("[A-Za-z!]+")
    print(pattern:captures("Hello World!", 'g')) -- {{RegexMatch}, {RegexMatch}}
    ```
- Added `@zcore/datetime`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/datetime)

  Example:
    ```lua
    local datetime = require("@zcore/datetime")

    print(datetime.now().unixTimestamp) -- Timestamp
    print(datetime.now():toIsoDate()) -- ISO Date
    ```
- Added `onSignal` to `@zcore/process`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/process)

  Example:
    ```lua
    local process = require("@zcore/process")

    process.onSignal("INT", function()
      print("Received SIGINT")
    end)
    ```

### Changed
- Updated `luau` to `0.642`.
- Updated `@zcore/process` to lock changing variables & allowed changing `cwd`.
  - Changing cwd would affect the global process cwd (even `fs` library).
  - Supports Relative and Absolute paths. `../` or `/`.
    - Relative paths are relative to the current working directory.
- Updated `require` function to be able to require modules that return exactly 1 value, instead of only functions, tables, or nil.

### Fixed
- Fixed `@zcore/net` with serve using `reuseAddress` option not working.
- Fixed `REPL` requiring modules relative to the parent of the current working directory, instead of the current working directory.

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
