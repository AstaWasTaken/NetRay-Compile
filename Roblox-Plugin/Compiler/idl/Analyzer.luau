--!strict
-- Name: Analyzer
-- Purpose: Analyze AST and assign message IDs

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
    enums: { Ast.Enum },
    enumByName: { [string]: Ast.Enum },
    taggedEnums: { Ast.Enum },
    taggedEnumByName: { [string]: Ast.Enum },
    sets: { Ast.Set },
    setByName: { [string]: Ast.Set },
    maxPassArgs: {
        reliable: number,
        unreliable: number,
        Function: number,
    },
}

local CONTAINER_KINDS: { [string]: boolean } = {
    optional = true,
    array = true,
    fixedarray = true,
    map = true,
    vector = true,
    cframe = true,
    inline_struct = true,
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

local function cloneType(typeDef: Ast.Type): Ast.Type
    local copy: any = {}
    for key, value in typeDef do
        copy[key] = value
    end
    return copy :: Ast.Type
end

local function cloneParam(param: Ast.Param): Ast.Param
    return {
        name = param.name,
        type = cloneType(param.type),
    }
end

local function cloneParamList(params: { Ast.Param }): { Ast.Param }
    local out: { Ast.Param } = {}
    for index = 1, #params do
        out[index] = cloneParam(params[index])
    end
    return out
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
    local enumByName: { [string]: Ast.Enum } = {}
    local enums: { Ast.Enum } = {}
    local taggedEnumByName: { [string]: Ast.Enum } = {}
    local taggedEnums: { Ast.Enum } = {}
    local setByName: { [string]: Ast.Set } = {}
    local sets: { Ast.Set } = {}

    local function collectDecls(decls: { Ast.Decl })
        for index = 1, #decls do
            local decl = decls[index]
            if decl.name and (decl :: any).declarations then
                collectDecls((decl :: Ast.Scope).declarations)
            elseif (decl :: any).fields and not (decl :: any).params and not (decl :: any).values and not (decl :: any).variants then
                local structDecl = decl :: Ast.Struct
                if structByName[structDecl.name] ~= nil then
                    error("E_DUP_STRUCT")
                end
                if enumByName[structDecl.name] ~= nil or taggedEnumByName[structDecl.name] ~= nil or setByName[structDecl.name] ~= nil then
                    error("E_DUP_DECL")
                end
                structByName[structDecl.name] = structDecl
                structs[#structs + 1] = structDecl
            elseif (decl :: any).declKind == "set" then
                local setDecl = decl :: Ast.Set
                if setByName[setDecl.name] ~= nil then
                    error("E_DUP_SET")
                end
                if structByName[setDecl.name] ~= nil or enumByName[setDecl.name] ~= nil or taggedEnumByName[setDecl.name] ~= nil then
                    error("E_DUP_DECL")
                end
                setByName[setDecl.name] = setDecl
                sets[#sets + 1] = setDecl
            elseif (decl :: any).declKind == "enum" then
                local enumDecl = decl :: Ast.Enum
                local hasVariants = enumDecl.variants ~= nil and #((enumDecl.variants :: any) :: { any }) > 0
                if hasVariants then
                    if taggedEnumByName[enumDecl.name] ~= nil then
                        error("E_DUP_ENUM")
                    end
                    if structByName[enumDecl.name] ~= nil or enumByName[enumDecl.name] ~= nil or setByName[enumDecl.name] ~= nil then
                        error("E_DUP_DECL")
                    end
                    taggedEnumByName[enumDecl.name] = enumDecl
                    taggedEnums[#taggedEnums + 1] = enumDecl
                elseif enumDecl.values ~= nil then
                    if enumByName[enumDecl.name] ~= nil then
                        error("E_DUP_ENUM")
                    end
                    if structByName[enumDecl.name] ~= nil or taggedEnumByName[enumDecl.name] ~= nil or setByName[enumDecl.name] ~= nil then
                        error("E_DUP_DECL")
                    end
                    enumByName[enumDecl.name] = enumDecl
                    enums[#enums + 1] = enumDecl
                end
            end
        end
    end

    collectDecls(schema.declarations)

    local resolveType: (Ast.Type) -> Ast.Type

    local function resolveTaggedVariants(variants: { any }?): { any }?
        if variants == nil then
            return nil
        end
        local resolvedVariants: { any } = {}
        for index = 1, #variants do
            local variant = variants[index]
            local fields = cloneParamList((variant.fields :: any) or {})
            for fieldIndex = 1, #fields do
                fields[fieldIndex].type = resolveType(fields[fieldIndex].type)
            end
            resolvedVariants[index] = {
                name = variant.name,
                fields = fields,
            }
        end
        return resolvedVariants
    end

    function resolveType(typeDef: Ast.Type): Ast.Type
        local kind = typeDef.kind
        if kind == "enum_inline" then
            return {
                kind = "enum",
                values = typeDef.values,
            }
        end

        if CONTAINER_KINDS[kind] then
            local resolved = cloneType(typeDef)
            if kind == "map" then
                if resolved.key ~= nil then
                    resolved.key = resolveType((resolved.key :: any) :: Ast.Type)
                end
                if resolved.value ~= nil then
                    resolved.value = resolveType((resolved.value :: any) :: Ast.Type)
                end
                return resolved
            end
            if kind == "inline_struct" then
                local fields: { Ast.Param } = cloneParamList((resolved.fields :: any) or {})
                for fieldIndex = 1, #fields do
                    fields[fieldIndex].type = resolveType(fields[fieldIndex].type)
                end
                resolved.fields = fields
                return resolved
            end
            if kind == "cframe" then
                if resolved.value ~= nil then
                    resolved.value = resolveType((resolved.value :: any) :: Ast.Type)
                end
                if resolved.key ~= nil then
                    resolved.key = resolveType((resolved.key :: any) :: Ast.Type)
                end
                return resolved
            end
            if resolved.value ~= nil then
                resolved.value = resolveType((resolved.value :: any) :: Ast.Type)
            end
            return resolved
        end

        local enumDecl = enumByName[kind]
        if enumDecl ~= nil then
            return {
                kind = "enum",
                name = kind,
                values = enumDecl.values,
            }
        end

        local taggedDecl = taggedEnumByName[kind]
        if taggedDecl ~= nil then
            return {
                kind = "tagged_enum",
                name = kind,
                tag = taggedDecl.tag or "Type",
                variants = resolveTaggedVariants(taggedDecl.variants),
            }
        end

        local setDecl = setByName[kind]
        if setDecl ~= nil then
            return {
                kind = "set",
                name = kind,
                values = setDecl.values,
            }
        end

        return typeDef
    end

    local function resolveParams(params: { Ast.Param })
        for index = 1, #params do
            params[index].type = resolveType(params[index].type)
        end
    end

    local function resolveDecls(decls: { Ast.Decl })
        for index = 1, #decls do
            local decl = decls[index]
            if decl.name and (decl :: any).declarations then
                resolveDecls((decl :: Ast.Scope).declarations)
            elseif (decl :: any).fields and not (decl :: any).params and not (decl :: any).values and not (decl :: any).variants then
                local structDecl = decl :: Ast.Struct
                resolveParams(structDecl.fields)
            elseif (decl :: any).reliability then
                local eventDecl = decl :: Ast.Event
                resolveParams(eventDecl.params)
            elseif (decl :: any).returns then
                local functionDecl = decl :: Ast.Function
                resolveParams(functionDecl.params)
                resolveParams(functionDecl.returns)
            elseif (decl :: any).variants then
                local enumDecl = decl :: Ast.Enum
                local variants = resolveTaggedVariants(enumDecl.variants)
                if variants ~= nil then
                    enumDecl.variants = variants
                end
            end
        end
    end

    resolveDecls(schema.declarations)

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
        enums = enums,
        enumByName = enumByName,
        taggedEnums = taggedEnums,
        taggedEnumByName = taggedEnumByName,
        sets = sets,
        setByName = setByName,
        maxPassArgs = maxPassArgs,
    }
end

return {
    analyze = analyze,
}
