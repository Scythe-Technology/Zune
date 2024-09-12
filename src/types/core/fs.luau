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

type IOError = "AccessDenied"
	| "FileNotFound"
	| "UnknownError"
type DiskError = "DiskQuotaExceeded"
type FileError = "Aborted"
type DeviceError = "Busy"
type ReadError = "OutOfMemory"
type NetworkError = "NetworkNotFound"
type EncodingError = "InvalidUtf-8"
	| "InvalidWtf-8"

export type FileReadError = IOError
	| FileError
	| DeviceError
	| ReadError
	| "NotFile"
	| "NotOpenForReading"
	| "FailedToCreateBuffer"

export type FileWriteError = IOError
	| DiskError
	| FileError
	| DeviceError
	| "TooBig"
	| "OutOfSpace"
	| "Locked"
	| "NotOpenForWriting"

export type FileRemoveError = IOError
	| DeviceError
	| "NotFile"

export type DirReadError = IOError
	| DeviceError
	| ReadError
	| "NotDirectory"

export type DirWriteError = IOError
	| DiskError
	| NetworkError
	| EncodingError
	| "BadName"
	| "TooLong"
	| "SymbolicLinkLoop"
	| "PathAlreadyExists"
	| "SymbolicLinkQuotaExceeded"

export type DirRemoveError = IOError
	| DeviceError
	| "NotDirectory"
	| "DirNotEmpty"

export type MetadataError = IOError
	| DeviceError

export type MoveError = IOError
	| DeviceError
	| DiskError
	| NetworkError
	| EncodingError
	| "NotFile"
	| "NotDirectory"
	| "PathAlreadyExists"
	| "DirNotEmpty"
	| "SymbolicLinkLoop"
	| "SharingViolation"
	| "TooLong"
	| "AntivirusInterference"
	| "BadName"

export type CopyError = IOError
	| DeviceError

export type SymlinkError = IOError
	| DiskError
	| EncodingError
	| NetworkError
	| "TooLong"
	| "PathAlreadyExists"
	| "BadName"
	| "NotDirectory"
	| "OutOfSpace"
	| "SymbolicLinkLoop"
	| "NotDirectory"
	| "NotFile"
	| "NotSupported"

export type Metadata = {
	kind : MetadataKind,
	symlink : boolean,
	createdAt : number,
	modifiedAt : number,
	accessedAt : number,
	size : number,
	permissions : {
		readOnly : boolean,
	},
}

export type FileHandle = {
	--[[
		Reads the contents of a file.

		*Optional: The amount of bytes to read, if nil, reads the whole till EOF or Luau limit.*

		@param amount The amount of bytes to read.
	]]
	read :
		& ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
		& ((self: FileHandle, amount: number?, useBuffer: true) -> buffer),


	--[[
		Writes to a file.

		@param contents The contents to write to the file.
	]]
	write : (self: FileHandle, contents: buffer | string) -> (),

	--[[
		Appends to a file.
		
		@param contents The contents to append to the file.
	]]
	append : (self: FileHandle, contents: buffer | string) -> (),

	--[[
		Returns the size of the file. Based on current state of the file object.
	]]
	getSize : (self: FileHandle) -> number,

	--[[
		Returns the current position of the file.
	]]
	getSeekPosition : (self: FileHandle) -> number,

	--[[
		Seeks to a position in the file relative to the end.

		*Optional: The amount of bytes to seek, if nil, seeks to the end*

		@param amount The amount of bytes to seek.
	]]
	seekFromEnd : (self: FileHandle, amount: number?) -> (),

	--[[
		Seeks to a position in the file absolute to the start.

		*Optional: The amount of bytes to seek, if nil, seeks to the start, 0*

		@param amount The amount of bytes to seek.
	]]
	seekTo : (self: FileHandle, amount: number?) -> (),

	--[[
		Seeks to a position in the file relative to the current position.

		*Optional: The amount of bytes to seek, if nil, seeks to the next position, 1*

		*If `0` is provided, seek will not move.*

		@param amount The amount of bytes to seek.
	]]
	seekBy : (self: FileHandle, amount: number?) -> (),

	--[[
		Locks the file.

		*Optional: The mode to lock the file, if nil, locks the file in exclusive mode.*

		@param lockMode The mode to lock the file.
	]]
	lock : (self: FileHandle, lockMode: ("shared" | "exclusive" | "none")?) -> boolean,

	--[[
		Unlocks the file.
	]]
	unlock : (self: FileHandle) -> (),

	--[[
		Flushes the file. Writes the contents to the disk.

		Does not yield, **blocks** process.
	]]
	sync : (self: FileHandle) -> (),

	--[[
		Closes the file. (Will flush the file)
	]]
	close : (self: FileHandle) -> (),
}

type CreateFileOptions = {
	--[[
		Whether to create the file in exclusive mode.

		*Default: false*
	]]
	exclusive : boolean?,
};

type OpenFileOptions = {
	--[[
		The mode to open the file in.

		Available modes: `r`, `w`

		*Default: `rw`*
	]]
	mode : string?,
};

local fs = {};

--[[
	Creates a file.

	If exclusive is true, the operation will fail if the file already exists.

	@param path The path to the file.
	@param opts The options to create the file.
	@return boolean Whether the operation was successful.
	@return FileHandle | FileReadError An error if the operation failed.
]]
fs.createFile = (nil :: any) :: (path: string, opts: CreateFileOptions?) -> (boolean, FileHandle | FileReadError);

--[[
	Opens a file.

	*The file must exist*

	@param path The path to the file.
	@param opts The options to open the file.
	@return boolean Whether the operation was successful.
	@return FileHandle | FileReadError An error if the operation failed.
]]
fs.openFile = (nil :: any) :: (path: string, opts: OpenFileOptions?) -> (boolean, FileHandle | FileReadError);

--[[
	Reads the contents of a file.

	*The content could be limited*
	
	@param path The path to the file.
	@param useBuffer Whether to read the file as a buffer.
	@return boolean Whether the operation was successful.
	@return string | buffer | FileReadError The contents of the file, or an error.
]]
fs.readFile = (nil :: any) :: (path: string, useBuffer: boolean?) -> (boolean, string | buffer | FileReadError);

--[[
	Reads the contents of a directory.

	@param path The path to the directory.
	@return boolean Whether the operation was successful.
	@return {string} | string The contents of the directory, or an error.
]]
fs.readDir = (nil :: any) :: (path: string) -> (boolean, { string } | string);

--[[
	Writes to a file.

	*The content could be limited*

	@param path The path to the file.
	@param contents The contents to write to the file.
	@return boolean Whether the operation was successful.
	@return FileWriteError An error if the operation failed.
]]
fs.writeFile = (nil :: any) :: (path: string, contents: buffer | string) -> (boolean, FileWriteError?);

--[[
	Creates a directory.

	@param path The path to the directory.
	@param recursive Whether to write recursively.
	@return boolean Whether the operation was successful.
	@return DirWriteError An error if the operation failed.
]]
fs.writeDir = (nil :: any) ::  (path: string, recursive: boolean?) -> (boolean, DirWriteError?);

--[[
	Deletes a file.

	@param path The path to the file.
	@return boolean Whether the operation was successful.
	@return FileRemoveError An error if the operation failed.
]]
fs.removeFile = (nil :: any) :: (path: string) -> (boolean, FileRemoveError?);

--[[
	Deletes a directory.

	@param path The path to the directory.
	@param recursive Whether to delete recursively.
	@return boolean Whether the operation was successful.
	@return DirRemoveError An error if the operation failed.
]]
fs.removeDir = (nil :: any) :: (path: string, recursive: boolean?) -> (boolean, DirRemoveError?);

--[[
	Returns the metadata of a file or directory.

	@param path The path to the file or directory.
	@return boolean Whether the operation was successful.
	@return Metadata | MetadataError The metadata of the file or directory, or an error.
]]
fs.metadata = (nil :: any) :: (path: string) -> (boolean, Metadata? | MetadataError);

--[[
	Checks if a file exists.

	@param path The path to the file.
	@return boolean Whether the file exists.
]]
fs.isFile = (nil :: any) :: (path: string) -> boolean;

--[[
	Checks if a directory exists.

	@param path The path to the directory.
	@return boolean Whether the directory exists.
]]
fs.isDir = (nil :: any) :: (path: string) -> boolean;

--[[
	Moves a file or directory to a new location.

	@param from The path to the file or directory.
	@param to The path to rename the file or directory to.
	@param overwrite Whether to overwrite the file or directory if it exists.
	@return boolean Whether the operation was successful.
	@return MoveError An error if the operation failed.
]]
fs.move = (nil :: any) :: (from: string, to: string, overwrite: boolean?) -> (boolean, MoveError?);

--[[
	Copies a file or directory to a new location.

	@param from The path to the file or directory.
	@param to The path to copy the file or directory to.
	@param overwrite Whether to overwrite the file or directory if it exists.
	@return boolean Whether the operation was successful.
	@return CopyError An error if the operation failed.
]]
fs.copy = (nil :: any) :: (from: string, to: string, overwrite: boolean?) -> (boolean, CopyError?);

--[[
	Creates a symbolic link.

	*Currently **not** supported on `Windows`*

	@param from The path to the file or directory.
	@param to The path to create the symbolic link to.
	@return boolean Whether the operation was successful.
	@return SymlinkError An error if the operation failed.
]]
fs.symlink = (nil :: any) :: (from: string, to: string) -> (boolean, SymlinkError?);

return fs;
