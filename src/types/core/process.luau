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
;

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
;

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

export type ProcessChild = {
	--[[
		Waits for the process to exit. Calls system function.

		Does not yield, **blocks** process.

		@return `ProcessResult`
	]]
	wait : (self: ProcessChild) -> ProcessResult,
	--[[
		Kills process. Calls system function.

		Does not yield, **blocks** process.

		@return `ProcessResult`
	]]
	kill : (self: ProcessChild) -> ProcessResult,

	--[[
		Reads the output of the process. Stdout.

		Optional size parameter to read a specific amount of bytes.
		Nil to read all.

		@param size The size of the output to read.
		@return `string`
	]]
	readOut : (self: ProcessChild, size: number?) -> string,
	--[[
		Writes to the input of the process. Stdin.

		@param data The data to write to the process.
	]]
	writeIn : (self: ProcessChild, data: string) -> (),
	--[[
		Reads the error output of the process. Stderr.

		Optional size parameter to read a specific amount of bytes.
		Nil to read all.

		@param size The size of the output to read.
		@return `string`
	]]
	readErr : (self: ProcessChild, size: number?) -> string,
}

local process = {};

--[[
	The os the process is running on.
]]
process.os = (nil :: any) :: OS;

--[[
	The architecture of the processor running.
]]
process.arch = (nil :: any) :: CPUArchitecture;

--[[
	The current working directory of the process.
]]
process.cwd = (nil :: any) :: string;

--[[
	The arguments passed to the process.
]]
process.args = (nil :: any) :: { string }

--[[
	The environment variables of the process.
	- Includes `.env` file in the current working directory.
	- Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
	- Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
	- Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
	- Includes `.env.local` file in the current working directory.
]]
process.env = (nil :: any) :: { [string]: string }

--[[
	Loads the environment variables of the process.
	- Includes `.env` file in the current working directory.
	- Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
	- Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
	- Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
	- Includes `.env.local` file in the current working directory.

	@return `EnvironmentMap`
]]
process.loadEnv = (nil :: any) :: () -> { [string]: string };

--[[
	Creates a new process.

	@param exec The executable to run.
	@param args The arguments to pass to the executable.
	@param procOpts The options for the process.
	@return `ProcessChild`
]]
process.create = (nil :: any) :: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> (boolean, ProcessChild | string);

--[[
	Runs a new process.

	Blocks the current process until the process has exited.

	We recommend using `process.create` for non-blocking process creation.

	@param exec The executable to run.
	@param args The arguments to pass to the executable.
	@param procOpts The options for the process.
	@return `ProcessRunResult`
]]
process.run = (nil :: any) :: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> (boolean, ProcessRunResult | string);

--[[
	Exits the current process with the given exit code.

	@param code
]]
process.exit = (nil :: any) :: (code: number) -> never;

return process;
