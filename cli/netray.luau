--!strict
-- Name: netray
-- Purpose: Standalone CLI frontend for compiling NetRay IDL into Luau modules

local Compiler = require("../src/Compiler")
local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

type CompileArgs = {
	inputPath: string,
	outputDir: string,
	scope: string?,
}

local function usage(): string
	return table.concat({
		"NetRay CLI",
		"",
		"Usage:",
		"  netray compile <schema-path> --out-dir <dir> [--scope <name>]",
		"",
		"Arguments:",
		"  <schema-path>        Path to the NetRay IDL schema file",
		"",
		"Options:",
		"  --out-dir <dir>      Output directory for Server.luau, Client.luau, and Types.luau",
		"  --scope <name>       Fallback remote scope when schema does not set option remote_scope",
		"  -h, --help           Show this help message",
	}, "\n")
end

local function cleanError(err: any): string
	local text = tostring(err)
	local tracebackIndex = string.find(text, "\nstack traceback:", 1, true)
	if tracebackIndex ~= nil then
		return string.sub(text, 1, tracebackIndex - 1)
	end
	return text
end

local function joinPath(dir: string, name: string): string
	local lastChar = string.sub(dir, #dir, #dir)
	if lastChar == "/" or lastChar == "\\" then
		return dir .. name
	end
	return dir .. "/" .. name
end

local function fail(message: string, showUsage: boolean?): never
	local rendered = message
	if showUsage then
		rendered ..= "\n\n" .. usage()
	end
	error(rendered, 0)
end

local function printHelp()
	stdio.write(usage() .. "\n")
end

local function parseCompileArgs(args: { string }): CompileArgs
	local inputPath = args[2]
	if inputPath == "-h" or inputPath == "--help" then
		printHelp()
		process.exit(0)
	end
	if inputPath == nil or inputPath == "" then
		fail("Missing <schema-path> for the compile command.", true)
	end

	local outputDir: string? = nil
	local scope: string? = nil

	local index = 3
	while index <= #args do
		local token = args[index]
		if token == "--out-dir" then
			local value = args[index + 1]
			if value == nil or value == "" then
				fail("Missing value for --out-dir.", true)
			end
			outputDir = value
			index += 2
		elseif token == "--scope" then
			local value = args[index + 1]
			if value == nil or value == "" then
				fail("Missing value for --scope.", true)
			end
			scope = value
			index += 2
		elseif token == "-h" or token == "--help" then
			printHelp()
			process.exit(0)
		else
			fail(("Unknown option for compile: %s"):format(token), true)
		end
	end

	if outputDir == nil then
		fail("Missing required --out-dir option.", true)
	end

	return {
		inputPath = inputPath,
		outputDir = outputDir,
		scope = scope,
	}
end

local function writeOutputFile(outputDir: string, name: string, contents: string)
	local path = joinPath(outputDir, name)
	fs.writeFile(path, contents)
end

local function ensureOutputDir(outputDir: string)
	local metadata = fs.metadata(outputDir)
	if metadata.exists then
		if metadata.kind ~= "dir" then
			fail(("Output path '%s' already exists and is not a directory."):format(outputDir))
		end
		return
	end

	fs.writeDir(outputDir)
end

local function compileSchema(args: CompileArgs)
	local readOk, schemaTextOrError = pcall(function()
		return fs.readFile(args.inputPath)
	end)
	if not readOk then
		fail(("Failed to read schema file '%s': %s"):format(args.inputPath, cleanError(schemaTextOrError)))
	end

	local compileOk, compiledOrError = pcall(function()
		return Compiler.compile(schemaTextOrError :: string, args.scope)
	end)
	if not compileOk then
		fail(("Compile failed: %s"):format(cleanError(compiledOrError)))
	end

	local outputOk, outputError = pcall(function()
		ensureOutputDir(args.outputDir)

		local compiled = compiledOrError :: {
			server: string,
			client: string,
			types: string,
		}
		writeOutputFile(args.outputDir, "Server.luau", compiled.server)
		writeOutputFile(args.outputDir, "Client.luau", compiled.client)
		writeOutputFile(args.outputDir, "Types.luau", compiled.types)
	end)
	if not outputOk then
		fail(("Failed to write output directory '%s': %s"):format(args.outputDir, cleanError(outputError)))
	end

	stdio.write(("Wrote Server.luau, Client.luau, and Types.luau to %s\n"):format(args.outputDir))
end

local function main()
	local args = process.args
	if #args == 0 then
		fail("Missing command.", true)
	end

	local command = args[1]
	if command == "-h" or command == "--help" or command == "help" then
		printHelp()
	elseif command == "compile" then
		compileSchema(parseCompileArgs(args))
	else
		fail(("Unknown command: %s"):format(command), true)
	end
end

local ok, err = xpcall(main, function(message)
	return tostring(message)
end)

if not ok then
	stdio.ewrite(err .. "\n")
	process.exit(1)
end
