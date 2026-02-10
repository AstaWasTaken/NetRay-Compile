--!strict
-- Name: Compiler
-- Purpose: Entry point for compiling NetRay IDL into runtime modules
-- Generated-by: NetRay-Compiler (authored)

local Lexer = require(script.Parent.idl.Lexer)
local Parser = require(script.Parent.idl.Parser)
local Analyzer = require(script.Parent.idl.Analyzer)
local Generator = require(script.Parent.generator.Generator)

export type CompileResult = {
	server: string,
	client: string,
	types: string,
}

local FORBIDDEN_PATTERNS = {
	"string.pack",
	"string.unpack",
	"string.char",
	"table.insert",
	"pairs(",
	"ipairs(",
	"+ 0",
	"coroutine",
}

local function verifyForbidden(code: string, label: string)
	for index = 1, #FORBIDDEN_PATTERNS do
		local pattern = FORBIDDEN_PATTERNS[index]
		if string.find(code, pattern, 1, true) then
			error(("Forbidden pattern '%s' found in %s"):format(pattern, label))
		end
	end
end

local function compile(idlText: string, remoteScope: string?): CompileResult
	local scopeName = remoteScope or "NetRay"
	local tokens = Lexer.lex(idlText)
	local ast = Parser.parse(tokens)
	local analyzed = Analyzer.analyze(ast, scopeName)
	local generated = Generator.generate(analyzed)
	verifyForbidden(generated.server, "Server.luau")
	verifyForbidden(generated.client, "Client.luau")
	verifyForbidden(generated.types, "Types.luau")
	return generated
end

return {
	compile = compile,
	verifyForbidden = verifyForbidden,
}
