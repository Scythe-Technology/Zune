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

local fs = {};

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
