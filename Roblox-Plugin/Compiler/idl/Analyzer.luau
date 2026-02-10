--!strict
-- Name: Analyzer
-- Purpose: Analyze AST and assign message IDs
-- Generated-by: NetRay-Compiler (authored)

local Ast = require(script.Parent.Ast)

export type AnalyzedMessage = {
    name: string,
    fullName: string,
    params: { Ast.Param },
    returns: { Ast.Param }?,
    reliability: string?,
    from: string?,
    call: string?,
    yieldMode: string?,
    id: number,
    category: string,
}

export type AnalyzedScope = {
    name: string,
    fullName: string,
    messages: { AnalyzedMessage },
    scopes: { AnalyzedScope },
}

export type ValidateLevel = "Off" | "Basic" | "Full"

export type AnalyzedSchema = {
    options: { Ast.Option },
    validateLevel: ValidateLevel,
    root: AnalyzedScope,
    remoteScope: string,
    structs: { Ast.Struct },
    structByName: { [string]: Ast.Struct },
    maxPassArgs: {
        reliable: number,
        unreliable: number,
        Function: number,
    },
}

local function countPassthrough(params: { Ast.Param }): number
    local count = 0
    for index = 1, #params do
        local param = params[index]
        if param.type.kind == "passthrough" then
            count += 1
        end
    end
    return count
end

local function normalizeValidateLevel(value: string): ValidateLevel
    local normalized = string.lower(value)
    if normalized == "off" then
        return "Off"
    end
    if normalized == "basic" then
        return "Basic"
    end
    if normalized == "full" then
        return "Full"
    end
    error(("Invalid Validate option value '%s' (expected Off, Basic, or Full)"):format(value))
end

local function resolveValidateLevel(options: { Ast.Option }): ValidateLevel
    for index = 1, #options do
        local option = options[index]
        if string.lower(option.name) == "validate" then
            return normalizeValidateLevel(option.value)
        end
    end
    return "Off"
end

local function analyze(schema: Ast.Schema, remoteScope: string): AnalyzedSchema
    local reliableId = 0
    local unreliableId = 0
    local functionId = 0

    local maxPassArgs = {
        reliable = 0,
        unreliable = 0,
        Function = 0,
    }

    local structByName: { [string]: Ast.Struct } = {}
    local structs: { Ast.Struct } = {}

    local function collectStructDecls(decls: { Ast.Decl })
        for index = 1, #decls do
            local decl = decls[index]
            if decl.name and (decl :: any).declarations then
                collectStructDecls((decl :: Ast.Scope).declarations)
            elseif (decl :: any).fields and not (decl :: any).params and not (decl :: any).values then
                local structDecl = decl :: Ast.Struct
                if structByName[structDecl.name] ~= nil then
                    error("E_DUP_STRUCT")
                end
                structByName[structDecl.name] = structDecl
                structs[#structs + 1] = structDecl
            end
        end
    end

    collectStructDecls(schema.declarations)

    local function analyzeDecls(decls: { Ast.Decl }, scopeName: string, scopeFullName: string): AnalyzedScope
        local scope: AnalyzedScope = {
            name = scopeName,
            fullName = scopeFullName,
            messages = {},
            scopes = {},
        }

        for index = 1, #decls do
            local decl = decls[index]
            if decl.name and (decl :: any).declarations then
                local child = decl :: Ast.Scope
                local nested = analyzeDecls(child.declarations, child.name, scopeFullName .. "." .. child.name)
                scope.scopes[#scope.scopes + 1] = nested
            elseif (decl :: any).returns then
                functionId += 1
                local funcDecl = decl :: Ast.Function
                local msg: AnalyzedMessage = {
                    name = funcDecl.name,
                    fullName = scopeFullName .. "." .. funcDecl.name,
                    params = funcDecl.params,
                    returns = funcDecl.returns,
                    yieldMode = funcDecl.yieldMode,
                    id = functionId,
                    category = "function",
                }
                local passCount = countPassthrough(msg.params)
                if passCount > maxPassArgs.Function then
                    maxPassArgs.Function = passCount
                end
                scope.messages[#scope.messages + 1] = msg
            elseif (decl :: any).reliability then
                local eventDecl = decl :: Ast.Event
                local reliability = eventDecl.reliability
                local category = reliability == "unreliable" and "unreliable" or "reliable"
                if category == "unreliable" then
                    unreliableId += 1
                else
                    reliableId += 1
                end
                local id = category == "unreliable" and unreliableId or reliableId
                local msg: AnalyzedMessage = {
                    name = eventDecl.name,
                    fullName = scopeFullName .. "." .. eventDecl.name,
                    params = eventDecl.params,
                    reliability = reliability,
                    from = eventDecl.from or "both",
                    call = eventDecl.call,
                    id = id,
                    category = category,
                }
                local passCount = countPassthrough(msg.params)
                if category == "unreliable" then
                    if passCount > maxPassArgs.unreliable then
                        maxPassArgs.unreliable = passCount
                    end
                else
                    if passCount > maxPassArgs.reliable then
                        maxPassArgs.reliable = passCount
                    end
                end
                scope.messages[#scope.messages + 1] = msg
            end
        end

        return scope
    end

    local root = analyzeDecls(schema.declarations, "Net", "Net")

    return {
        options = schema.options,
        validateLevel = resolveValidateLevel(schema.options),
        root = root,
        remoteScope = remoteScope,
        structs = structs,
        structByName = structByName,
        maxPassArgs = maxPassArgs,
    }
end

return {
    analyze = analyze,
}
