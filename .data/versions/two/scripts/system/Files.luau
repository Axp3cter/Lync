--!strict

--[=[
	Files

	Reads, writes, copies, removes, lists and inspects files and folders for the repository scripts.

	The scripts reach the file system only through this module.

	Every operation here yields, except isRelativePath.

	A failure outside the scripts, such as a missing file or a refused permission, comes back as a
	Result. A mistake by the caller throws.

	A path is one or more names joined by "/", relative to the working directory. A name is not
	empty and is not "." or "..", and a path holds no backslash or colon.

	Every path that a function here returns is a valid path for every function here, except that
	Linux allows a name holding a colon or a backslash, which a path refuses.
]=]


-- Imports -----------------------------------------------------------------------------------------

local fs    = require("@std/fs")
local Types = require("../Types")


-- Module ------------------------------------------------------------------------------------------

local Files = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	Everything under one folder, as paths relative to it.

	Both lists run depth first, each folder's entries in name order, and a folder comes before what
	it holds.

	@field files   every entry that is not a folder
	@field folders every folder
]=]
type Contents = {
	read files:   { string },
	read folders: { string },
}


--- What a path holds: a file, a folder, or anything else, such as a link.
type Kind =
	| "File"
	| "Folder"
	| "Other"


type Entry = { read name: string, read kind: Kind }


-- Constants ---------------------------------------------------------------------------------------

--- Captures what follows the last ": " of a message, which is libuv's cause in a Lute error.
const COLON_CAUSE_PATTERN = ": ([^:]+)$"


--- Matches a backslash or a colon, which no name in a path may hold.
const FORBIDDEN_CHARACTER_PATTERN = "[\\:]"


--- Captures everything before the last "/" of a path, which is the folder that holds it.
const HOLDING_FOLDER_PATTERN = "^(.*)/[^/]*$"


--- Matches a Lute error that a function name leads, as in "listdir: Error listing directory x".
const NAMED_ERROR_PATTERN = "^%l+: Error "


--- Captures the cause in the parentheses that end a message, as in "listing x (not a directory)".
const PARENTHESIZED_CAUSE_PATTERN = "%(([^()]+)%)$"


--- Matches a Lute error that begins "Error ", as in "Error opening file x: no such file".
const PLAIN_ERROR_PATTERN = "^Error "


const KIND_BY_FILE_TYPE: Types.Complete<{ read [fs.FileType]: Kind }> = {
	file    = "File",
	dir     = "Folder",

	link    = "Other",
	fifo    = "Other",
	socket  = "Other",
	char    = "Other",
	block   = "Other",
	unknown = "Other",
}
table.freeze(KIND_BY_FILE_TYPE)


const READ_MODE:  fs.HandleMode = "r"
const WRITE_MODE: fs.HandleMode = "w"

-- These records are not frozen, because the checker types a frozen record as read-only, which
-- Lute's options reject.
const RECURSIVE_CREATE: fs.CreateDirectoryOptions = { makeParents = true }
const RECURSIVE_REMOVE: fs.RemoveDirectoryOptions = { recursive = true }


-- Private -----------------------------------------------------------------------------------------

local function isRelativePath(path: string): boolean
	if string.find(path, FORBIDDEN_CHARACTER_PATTERN) ~= nil then
		return false
	end

	for _, name in string.split(path, "/") do
		if
			name == ""
			or name == "."
			or name == ".."
		then
			return false
		end
	end

	return true
end


--[=[
	Reduces an error thrown by Lute's file system to the cause libuv gave.

	@param  thrown the value that a failed `pcall` caught
	@return that cause, or the whole text of `thrown` when Lute's file system did not throw it
]=]
local function causeOf(thrown: unknown): string
	local message = tostring(thrown)

	local isPlainError = string.find(message, PLAIN_ERROR_PATTERN) ~= nil
	local isNamedError = string.find(message, NAMED_ERROR_PATTERN) ~= nil
	local isLuteError  = isPlainError or isNamedError
	if not isLuteError then
		return message
	end

	-- A Lute file-system error ends in libuv's cause, inside parentheses or after ": ".
	local parenthesizedCause = string.match(message, PARENTHESIZED_CAUSE_PATTERN)
	if parenthesizedCause ~= nil then
		return parenthesizedCause
	end

	local colonCause = string.match(message, COLON_CAUSE_PATTERN)
	if colonCause ~= nil then
		return colonCause
	end

	return message
end


--[=[
	Runs an operation that returns nothing, turning a failure into a Result.

	`obtain` does the same for an operation that returns a value: a function that returns nothing
	does not bind to a type parameter, so the two cannot be one.

	@param  clause    what was being done, which starts the text of a failure
	@param  operation the call into the outside world that can fail
	@param  ...       the arguments passed to `operation`
	@return a success, or a failure whose `error` is `clause`, then the cause
]=]
local function attempt<TArgs...>(
	clause:    string,
	operation: (TArgs...) -> (),
	...:       TArgs...
): Types.Result<nil>
	local ok, result = pcall(operation, ...)
	if not ok then
		return { ok = false, error = `{clause}: {causeOf(result)}` }
	end

	return { ok = true, value = nil }
end


--[=[
	Runs an operation that returns a value, turning a failure into a Result.

	@param  clause    what was being done, which starts the text of a failure
	@param  operation the call into the outside world that can fail
	@param  ...       the arguments passed to `operation`
	@return what `operation` returned, or a failure whose `error` is `clause`, then the cause
]=]
local function obtain<TValue, TArgs...>(
	clause:    string,
	operation: (TArgs...) -> TValue,
	...:       TArgs...
): Types.Result<TValue>
	local ok, result = pcall(operation, ...)
	if not ok then
		return { ok = false, error = `{clause}: {causeOf(result)}` }
	end

	return { ok = true, value = result }
end


--[=[
	Returns the folder that holds `path`.

	@param  path the file or folder whose holder is wanted
	@return `path` without its last name, or "." when `path` is one name
]=]
local function parentOf(path: string): string
	local parent = string.match(path, HOLDING_FOLDER_PATTERN)
	return parent or "."
end


local function entryNamed(entries: { read Entry }, name: string): Entry?
	for _, entry in entries do
		if entry.name == name then
			return entry
		end
	end

	return nil
end


--[=[
	Finds the entry of `entries` called `name`, ignoring case.

	An entry spelled exactly as `name` wins over one that differs only in case.

	@param  entries the entries of one folder, searched for `name`
	@param  name    the name to look for
	@return the entry, or nil when no entry has that name
]=]
local function entryLike(entries: { read Entry }, name: string): Entry?
	local exactEntry = entryNamed(entries, name)
	if exactEntry ~= nil then
		return exactEntry
	end

	local lowerName = string.lower(name)
	for _, entry in entries do
		if string.lower(entry.name) == lowerName then
			return entry
		end
	end

	return nil
end


--[=[
	Reads the entries directly inside `folder`.

	The operating system lists a folder in an order of its own, so the entries are sorted by name,
	byte by byte, to give every platform the same order.

	@param  folder the folder to read
	@return the entries of `folder`, each with what it holds, or why it could not be listed
]=]
local function scan(folder: string): Types.Result<{ Entry }>
	local listed = obtain(`"{folder}" could not be listed`, fs.listDirectory, folder)
	if not listed.ok then
		return listed
	end

	local listedEntries = listed.value
	local entries       = table.create(#listedEntries) :: { Entry }
	for i, listedEntry in listedEntries do
		entries[i] = { name = listedEntry.name, kind = KIND_BY_FILE_TYPE[listedEntry.type] }
	end

	table.sort(entries, function(left: Entry, right: Entry): boolean
		return left.name < right.name
	end)

	return { ok = true, value = entries }
end


--[=[
	Follows `path` from the working directory, one name at a time, through each folder's listing.

	Every name is matched in a listing, never by the OS, so the answer is the same everywhere.

	A listing that cannot be read is a failure, except inside a link that cannot be followed, which
	has nothing below it.

	@param  path    the names to follow
	@param  entryOf how a name is matched among a folder's entries
	@return the entry of every name, nil when a name has none or stands below a file or such a link
]=]
local function trace(
	path:    string,
	entryOf: (entries: { read Entry }, name: string) -> Entry?
): Types.Result<{ Entry }?>
	local names            = string.split(path, "/")
	local entries          = table.create(#names) :: { Entry }
	local folder           = "."
	local parentKind: Kind = "Folder"
	for i, name in names do
		-- A file has nothing below it.
		if parentKind == "File" then
			return { ok = true, value = nil }
		end

		local scanned = scan(folder)
		if not scanned.ok then
			if parentKind == "Folder" then
				return scanned
			elseif parentKind == "Other" then
				return { ok = true, value = nil }
			end

			local unhandled: never = parentKind
			return unhandled
		end

		local entry = entryOf(scanned.value, name)
		if entry == nil then
			return { ok = true, value = nil }
		end

		entries[i] = entry
		parentKind = entry.kind
		folder     = if i == 1 then entry.name else `{folder}/{entry.name}`
	end

	return { ok = true, value = entries }
end


local function inspect(path: string): Types.Result<Kind?>
	local traced = trace(path, entryNamed)
	if not traced.ok then
		return traced
	end

	local entries = traced.value
	if entries == nil then
		return { ok = true, value = nil }
	end

	local lastEntry = entries[#entries]

	return { ok = true, value = lastEntry.kind }
end


--[=[
	Creates the folder `path` and the folders above it.

	@param  path the folder to create, where "." is the working directory, which always exists
	@return a success, or why `path` could not be created, such as a file with its name
]=]
local function createFolder(path: string): Types.Result<nil>
	if path == "." then
		return { ok = true, value = nil }
	end

	local clause  = `"{path}" could not be created`
	local created = attempt(clause, fs.createDirectory, path, RECURSIVE_CREATE)
	if not created.ok then
		return created
	end

	-- Lute treats a file already at `path` as a folder that exists.
	local inspected = inspect(path)
	if not inspected.ok then
		return inspected
	end

	-- Windows finds a folder spelled in another case, which an exact listing does not show.
	local kind = inspected.value
	if kind == nil then
		return { ok = true, value = nil }
	end

	if kind == "File" then
		return { ok = false, error = `"{path}" could not be created: a file has that name` }
	end

	return { ok = true, value = nil }
end


--[=[
	Adds everything under `folder` to `contents`, each folder before what it holds.

	@param  folder   the folder to gather from, which is not itself added
	@param  prefix   the relative path of `folder` and a "/", which is empty at the root
	@param  contents where the relative paths are added
	@return a success, or why a listing failed
]=]
local function gather(folder: string, prefix: string, contents: Contents): Types.Result<nil>
	local scanned = scan(folder)
	if not scanned.ok then
		return scanned
	end

	for _, entry in scanned.value do
		local relativePath = `{prefix}{entry.name}`

		if entry.kind == "Folder" then
			table.insert(contents.folders, relativePath)

			local gathered = gather(`{folder}/{entry.name}`, `{relativePath}/`, contents)
			if not gathered.ok then
				return gathered
			end
		elseif entry.kind == "File" or entry.kind == "Other" then
			table.insert(contents.files, relativePath)
		else
			local _: never = entry.kind
		end
	end

	return { ok = true, value = nil }
end


--[=[
	Reads everything under `folder`, as paths relative to it.

	@param  folder the folder to read
	@return the files and the folders under `folder`, or why a listing failed
]=]
local function survey(folder: string): Types.Result<Contents>
	local contents: Contents = {
		files   = {},
		folders = {},
	}

	local gathered = gather(folder, "", contents)
	if not gathered.ok then
		return gathered
	end

	return { ok = true, value = contents }
end


local function copyFile(source: string, destination: string): Types.Result<nil>
	local clause = `"{source}" could not be copied to "{destination}"`
	return attempt(clause, fs.copy, source, destination)
end


local function copyFolder(source: string, destination: string): Types.Result<nil>
	local surveyed = survey(source)
	if not surveyed.ok then
		return surveyed
	end

	local rootCreated = createFolder(destination)
	if not rootCreated.ok then
		return rootCreated
	end

	local contents = surveyed.value
	for _, relativePath in contents.folders do
		local folderCreated = createFolder(`{destination}/{relativePath}`)
		if not folderCreated.ok then
			return folderCreated
		end
	end

	for _, relativePath in contents.files do
		local fileCopied = copyFile(`{source}/{relativePath}`, `{destination}/{relativePath}`)
		if not fileCopied.ok then
			return fileCopied
		end
	end

	return { ok = true, value = nil }
end


-- Public ------------------------------------------------------------------------------------------

--[=[
	Copies the file or folder `source` to `destination`.

	A file is copied to `destination` itself, replacing a file that is there, after the folders
	above `destination` are created.

	A folder is copied with everything under it: `destination` and the folders above it are
	created, files that are already there are replaced, and files under `destination` that
	`source` lacks stay.

	A `source` that is missing, a link, or anything else that is neither a file nor a folder fails
	the copy before anything is created.

	A `destination` that is a file fails a folder copy before anything is copied.

	The folder is listed before anything is copied, so a `destination` inside `source` receives what
	`source` held when the copy began.

	A failure stops the copy and leaves what was already copied in place.

	A link inside a folder is copied as a file, so a link to a folder fails the copy.

	@param  source      the file or folder to copy
	@param  destination where the copy goes, named as the file or folder that it becomes
	@return a success once everything is copied, or the clause that says what failed
	@error  when `source` or `destination` is not relative names joined by "/"
]=]
function Files.copy(source: string, destination: string): Types.Result<nil>
	if not isRelativePath(source) then
		error(`source must be relative names joined by "/", got "{source}"`, 2)
	end

	if not isRelativePath(destination) then
		error(`destination must be relative names joined by "/", got "{destination}"`, 2)
	end

	local clause = `"{source}" could not be copied to "{destination}"`

	local inspected = inspect(source)
	if not inspected.ok then
		return inspected
	end

	local kind = inspected.value
	if kind == nil then
		return { ok = false, error = `{clause}: it does not exist` }
	end

	if kind == "File" then
		local created = createFolder(parentOf(destination))
		if not created.ok then
			return created
		end

		return copyFile(source, destination)
	elseif kind == "Folder" then
		return copyFolder(source, destination)
	elseif kind == "Other" then
		return { ok = false, error = `{clause}: it is neither a file nor a folder` }
	end

	local unhandled: never = kind
	return unhandled
end


--[=[
	Returns what `path` holds.

	A link is Other, even when it points to a folder.

	Nothing is there for a path below a file, or below a link that cannot be followed.

	Nothing is there for a name in the wrong case, because every name must match the disk exactly.

	@param  path the file, folder or link to ask about
	@return the kind, nil when nothing is there, or why a folder on the way could not be listed
	@error  when `path` is not relative names joined by "/"
]=]
function Files.inspect(path: string): Types.Result<Kind?>
	if not isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	return inspect(path)
end


--[=[
	Tells whether `path` is one or more names joined by "/", relative to the working directory.

	A name is not empty and is not "." or "..", so a leading, trailing or doubled "/" is refused.

	A path holds no backslash or colon, which rules out a drive, a stream and a UNC path.

	@param  path the text to test
	@return true when every function here accepts `path`
]=]
function Files.isRelativePath(path: string): boolean
	return isRelativePath(path)
end


--[=[
	Lists every file under the folder `folder`.

	Each path starts with `folder`.

	An entry that is not a folder counts as a file, and a link is never followed.

	@param  folder the folder whose files are listed
	@return the paths, depth first, each folder's entries in name order, or why a listing failed
	@error  when `folder` is not relative names joined by "/"
]=]
function Files.list(folder: string): Types.Result<{ string }>
	if not isRelativePath(folder) then
		error(`folder must be relative names joined by "/", got "{folder}"`, 2)
	end

	local surveyed = survey(folder)
	if not surveyed.ok then
		return surveyed
	end

	local files = surveyed.value.files
	local paths = table.create(#files) :: { string }
	for i, relativePath in files do
		paths[i] = `{folder}/{relativePath}`
	end

	return { ok = true, value = paths }
end


--[=[
	Reads the file `path` as text, byte for byte.

	@param  path the file to read
	@return the contents of the file, or why it could not be read
	@error  when `path` is not relative names joined by "/"
]=]
function Files.read(path: string): Types.Result<string>
	if not isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	local clause = `"{path}" could not be read`
	-- Files are opened here, not through readFileToString, which leaves its file open when the read
	-- fails, or writeStringToFile, whose "w+" creates a new file as mode 0777.
	local opened = obtain(clause, fs.open, path, READ_MODE)
	if not opened.ok then
		return opened
	end

	local file   = opened.value
	local read   = obtain(clause, fs.read, file)
	local closed = attempt(clause, fs.close, file)
	if not read.ok then
		return read
	end

	if not closed.ok then
		return closed
	end

	return read
end


--[=[
	Removes the file, link or folder `path`, and everything under a folder.

	A path that does not exist is already removed, so this succeeds.

	A name in the wrong case does not exist, so nothing is removed.

	A link, whether it is `path` or lies under a folder, is removed without being followed.

	@param  path what to remove
	@return a success once `path` is gone, or the clause that says what failed
	@error  when `path` is not relative names joined by "/"
]=]
function Files.remove(path: string): Types.Result<nil>
	if not isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	local inspected = inspect(path)
	if not inspected.ok then
		return inspected
	end

	local kind = inspected.value
	if kind == nil then
		return { ok = true, value = nil }
	end

	local clause = `"{path}" could not be removed`

	if kind == "Folder" then
		return attempt(clause, fs.removeDirectory, path, RECURSIVE_REMOVE)
	elseif kind == "File" or kind == "Other" then
		return attempt(clause, fs.remove, path)
	end

	local unhandled: never = kind
	return unhandled
end


--[=[
	Returns `path` with every name spelled as the disk spells it.

	Windows finds a file whatever the case of its name, and Linux does not, so a caller compares
	the result with `path` to see whether every name was spelled exactly.

	When two names differ only in case, the one spelled exactly as written wins.

	Nothing is there for a missing name, for a path below a file, or for a path below a link that
	cannot be followed.

	@param  path the path to look up, in any case
	@return the spelling on disk, nil when nothing is there, or why a folder could not be listed
	@error  when `path` is not relative names joined by "/"
]=]
function Files.resolveCase(path: string): Types.Result<string?>
	if not isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	local traced = trace(path, entryLike)
	if not traced.ok then
		return traced
	end

	local entries = traced.value
	if entries == nil then
		return { ok = true, value = nil }
	end

	local names = table.create(#entries) :: { string }
	for i, entry in entries do
		names[i] = entry.name
	end

	return { ok = true, value = table.concat(names, "/") }
end


--[=[
	Writes `text` to the file `path`, replacing its contents.

	The folders above `path` that do not exist are created.

	Lute 1.0.0 has no `fs.move`, so the file is written in place: a failure part-way leaves the file
	partly written.

	@param  path the file to write
	@param  text what the file holds afterwards, byte for byte
	@return a success once the file is written and closed, or the clause that says what failed
	@error  when `path` is not relative names joined by "/"
]=]
function Files.write(path: string, text: string): Types.Result<nil>
	if not isRelativePath(path) then
		error(`path must be relative names joined by "/", got "{path}"`, 2)
	end

	local created = createFolder(parentOf(path))
	if not created.ok then
		return created
	end

	local clause = `"{path}" could not be written`
	local opened = obtain(clause, fs.open, path, WRITE_MODE)
	if not opened.ok then
		return opened
	end

	local file    = opened.value
	local written = attempt(clause, fs.write, file, text)
	local closed  = attempt(clause, fs.close, file)
	if not written.ok then
		return written
	end

	return closed
end


return table.freeze(Files)
