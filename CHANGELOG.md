# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- Added `repl` command.
  - Starts a REPL session.
  - Example:
    ```shell
    zune repl
    > print("Hello World!")
    ```

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
