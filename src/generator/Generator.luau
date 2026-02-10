--!strict
-- Name: Generator
-- Purpose: Emit runtime modules from analyzed schema
-- Generated-by: NetRay-Compiler (authored)

local Ast = require("../idl/Ast")
local Analyzer = require("../idl/Analyzer")

type MessageInfo = {
    message: Analyzer.AnalyzedMessage,
    symbol: string,
    apiBase: string,
    fullName: string,
    serializedParams: { Ast.Param },
    passthroughParams: { Ast.Param },
    serializedReturns: { Ast.Param },
    passthroughReturns: { Ast.Param },
}

type IntegerRange = {
    min: number,
    max: number,
}

type EmitState = {
    tempIndex: number,
}

type WidthInfo = {
    bytes: number,
    writer: string,
    reader: string,
    maxValue: number,
}

type LengthPrefixInfo = {
    declaredMax: number?,
    isVarint: boolean,
    width: WidthInfo?,
}

type TypeBrandingMode = "Off" | "On"
type DecodeStructMode = "Locals" | "Table"

type DecodedLeaf = {
    labelSuffix: string,
    targetName: string,
    typeDef: Ast.Type,
}

type DecodedParamPlan = {
    leaves: { DecodedLeaf },
    leafNames: { string },
}

type DecodeVarMeta = {
    kind: string,
    valueVar: string,
}

type DecodeVarCursor = {
    index: number,
}

local EMPTY_PARAMS: { Ast.Param } = {}

local LUAU_KEYWORDS: { [string]: boolean } = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
    ["continue"] = true,
    ["export"] = true,
    ["type"] = true,
}

local PRIMITIVE_BYTES: { [string]: number } = {
    u8 = 1,
    i8 = 1,
    u16 = 2,
    i16 = 2,
    u32 = 4,
    i32 = 4,
    f32 = 4,
    f64 = 8,
}

local PRIMITIVE_WRITERS: { [string]: string } = {
    u8 = "writeu8",
    i8 = "writei8",
    u16 = "writeu16",
    i16 = "writei16",
    u32 = "writeu32",
    i32 = "writei32",
    f32 = "writef32",
    f64 = "writef64",
}

local PRIMITIVE_READERS: { [string]: string } = {
    u8 = "readu8",
    i8 = "readi8",
    u16 = "readu16",
    i16 = "readi16",
    u32 = "readu32",
    i32 = "readi32",
    f32 = "readf32",
    f64 = "readf64",
}

local INTEGER_RANGES: { [string]: IntegerRange } = {
    u8 = { min = 0, max = 255 },
    i8 = { min = -128, max = 127 },
    u16 = { min = 0, max = 65535 },
    i16 = { min = -32768, max = 32767 },
    u32 = { min = 0, max = 4294967295 },
    i32 = { min = -2147483648, max = 2147483647 },
}

local MAX_FIXED_LENGTH_BOUND = 65535
local MAX_VARINT_LENGTH = 4294967295

local function widthForBound(maxValue: number): WidthInfo
    if maxValue <= 255 then
        return {
            bytes = 1,
            writer = "writeu8",
            reader = "readu8",
            maxValue = 255,
        }
    end

    return {
        bytes = 2,
        writer = "writeu16",
        reader = "readu16",
        maxValue = 65535,
    }
end

local function validateBoundedLength(maxValue: number?, typeLabel: string): number?
    if maxValue == nil then
        return nil
    end
    if maxValue < 0 then
        error(("%s max length cannot be negative (%d)"):format(typeLabel, maxValue))
    end
    if maxValue > MAX_FIXED_LENGTH_BOUND then
        error(("%s max length %d exceeds supported u16 limit"):format(typeLabel, maxValue))
    end
    return maxValue
end

local function getLengthPrefixInfo(typeLabel: string, maxValue: number?): LengthPrefixInfo
    local declaredMax = validateBoundedLength(maxValue, typeLabel)
    if declaredMax == nil then
        return {
            declaredMax = nil,
            isVarint = true,
            width = nil,
        }
    end
    return {
        declaredMax = declaredMax,
        isVarint = false,
        width = widthForBound(declaredMax),
    }
end

local function getStringLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("String", typeDef.max)
end

local function getArrayLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("Array", typeDef.max)
end

local function getMapLengthPrefixInfo(typeDef: Ast.Type): LengthPrefixInfo
    return getLengthPrefixInfo("Map", typeDef.max)
end

local function getMessageIdWidthInfo(maxId: number): WidthInfo
    if maxId < 0 then
        error(("Message ID cannot be negative (%d)"):format(maxId))
    end
    if maxId > 65535 then
        error(("Message ID %d exceeds supported u16 limit"):format(maxId))
    end
    return widthForBound(maxId)
end

local function isValidateFull(validateLevel: Analyzer.ValidateLevel): boolean
    return validateLevel == "Full"
end

local function isValidateBasicOrFull(validateLevel: Analyzer.ValidateLevel): boolean
    return validateLevel ~= "Off"
end

local function emitError(
    lines: { string },
    depth: number,
    _validateLevel: Analyzer.ValidateLevel,
    _detailedMessage: string,
    shortCodeConst: string
)
    lines[#lines + 1] = string.rep("    ", depth) .. ("error(%s)"):format(shortCodeConst)
end

local function indent(lines: { string }, depth: number): { string }
    local prefix = string.rep("    ", depth)
    local out: { string } = {}
    for index = 1, #lines do
        out[#out + 1] = prefix .. lines[index]
    end
    return out
end

local function concat(lines: { string }): string
    return table.concat(lines, "\n") .. "\n"
end

local function appendLines(target: { string }, source: { string })
    for index = 1, #source do
        target[#target + 1] = source[index]
    end
end

local function join(values: { string }): string
    if #values == 0 then
        return ""
    end
    return table.concat(values, ", ")
end

local function sanitizeIdentifier(value: string): string
    local sanitized = string.gsub(value, "[^%w_]", "_")
    if string.match(sanitized, "^[0-9]") then
        sanitized = "_" .. sanitized
    end
    return sanitized
end

local function addLine(lines: { string }, depth: number, text: string)
    lines[#lines + 1] = string.rep("    ", depth) .. text
end

local function nextTemp(state: EmitState, prefix: string): string
    state.tempIndex += 1
    return ("%s_%d"):format(prefix, state.tempIndex)
end

local function splitParams(params: { Ast.Param }): ({ Ast.Param }, { Ast.Param })
    local serialized: { Ast.Param } = {}
    local passthrough: { Ast.Param } = {}
    for index = 1, #params do
        local param = params[index]
        if param.type.kind == "passthrough" then
            passthrough[#passthrough + 1] = param
        else
            serialized[#serialized + 1] = param
        end
    end
    return serialized, passthrough
end

local function getPassthroughTypeName(param: Ast.Param): string
    local value = (param.type :: any).value
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "any"
end

local function getPassthroughTypeNameFromType(typeDef: Ast.Type): string
    local value = (typeDef.value :: any)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "unknown"
end

local function normalizeTypeKind(kind: string): string
    if kind == "boolean" then
        return "bool"
    end
    return kind
end

local function isNumericKind(kind: string): boolean
    return kind == "u8"
        or kind == "i8"
        or kind == "u16"
        or kind == "i16"
        or kind == "u32"
        or kind == "i32"
        or kind == "f32"
        or kind == "f64"
end

local function getStringBoundComment(typeDef: Ast.Type): string?
    local kind = normalizeTypeKind(typeDef.kind)
    if kind ~= "string" or typeDef.max == nil then
        return nil
    end
    return ("string<%d>"):format(typeDef.max)
end

local function resolveTypeBranding(options: { Ast.Option }): TypeBrandingMode
    for index = 1, #options do
        local option = options[index]
        if string.lower(option.name) == "typebranding" then
            local lowered = string.lower(option.value)
            if lowered == "on" then
                return "On"
            end
            if lowered == "off" then
                return "Off"
            end
            error(("Invalid TypeBranding option value '%s' (expected Off or On)"):format(option.value))
        end
    end
    return "Off"
end

local function resolveDecodeStruct(options: { Ast.Option }): DecodeStructMode
    for index = 1, #options do
        local option = options[index]
        if string.lower(option.name) == "decodestruct" then
            local lowered = string.lower(option.value)
            if lowered == "locals" then
                return "Locals"
            end
            if lowered == "table" then
                return "Table"
            end
            error(("Invalid DecodeStruct option value '%s' (expected Locals or Table)"):format(option.value))
        end
    end
    return "Locals"
end

local function toLuauType(typeDef: Ast.Type): string
    local kind = normalizeTypeKind(typeDef.kind)
    if isNumericKind(kind) then
        return kind
    end
    if kind == "bool" then
        return "boolean"
    end
    if kind == "string" then
        return "string"
    end
    if kind == "passthrough" then
        return getPassthroughTypeNameFromType(typeDef)
    end
    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type is missing value type")
        end
        return ("%s?"):format(toLuauType(valueType))
    end
    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type is missing value type")
        end
        return ("{ %s }"):format(toLuauType(valueType))
    end
    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type is missing key/value types")
        end
        local keyName = toLuauType(keyType)
        local valueName = toLuauType(valueType)
        return ("{ [%s]: %s }"):format(keyName, valueName)
    end
    return kind
end

local function typedParamList(params: { Ast.Param }): string
    local chunks: { string } = {}
    for index = 1, #params do
        local param = params[index]
        chunks[#chunks + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
    end
    return join(chunks)
end

local function returnTypeExpr(params: { Ast.Param }): string
    if #params == 0 then
        return "()"
    end
    local chunks: { string } = {}
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    if #chunks == 1 then
        return chunks[1]
    end
    return ("(%s)"):format(join(chunks))
end

local function tupleTypeExpr(params: { Ast.Param }): string
    local chunks: { string } = {}
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    if #chunks == 0 then
        return "() -> ()"
    end
    if #chunks == 1 then
        return ("() -> %s"):format(chunks[1])
    end
    return ("() -> (%s)"):format(join(chunks))
end

local function callbackTypeExpr(params: { Ast.Param }, includePlayer: boolean, returns: { Ast.Param }): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "player: Player"
    end
    for index = 1, #params do
        local param = params[index]
        chunks[#chunks + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeExpr(returns))
end

local function callbackSignatureTypeExpr(params: { Ast.Param }, includePlayer: boolean, returns: { Ast.Param }): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "Player"
    end
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeExpr(returns))
end

local function callableTypeExpr(params: { Ast.Param }, includePlayer: boolean, returnTypeName: string): string
    local chunks: { string } = {}
    if includePlayer then
        chunks[#chunks + 1] = "Player"
    end
    for index = 1, #params do
        chunks[#chunks + 1] = toLuauType(params[index].type)
    end
    return ("(%s) -> %s"):format(join(chunks), returnTypeName)
end

local function messageClientCallbackTypeName(baseName: string, category: string): string
    if category == "function" then
        return baseName .. "_ClientFunctionCallback"
    end
    return baseName .. "_ClientEventCallback"
end

local function messageServerCallbackTypeName(baseName: string, category: string): string
    if category == "function" then
        return baseName .. "_ServerFunctionCallback"
    end
    return baseName .. "_ServerEventCallback"
end

local function messageClientApiTypeName(baseName: string): string
    return baseName .. "_ClientApi"
end

local function messageServerApiTypeName(baseName: string): string
    return baseName .. "_ServerApi"
end

local function collectMessages(
    scope: Analyzer.AnalyzedScope,
    scopePath: string,
    out: { MessageInfo },
    symbolByMessage: { [Analyzer.AnalyzedMessage]: string }
)
    for index = 1, #scope.messages do
        local message = scope.messages[index]
        if message.id < 1 or message.id > 65535 then
            error(("Message ID %d for '%s' exceeds u16 range"):format(message.id, message.name))
        end
        local fullName = scopePath .. "." .. message.name
        local symbol = sanitizeIdentifier(fullName .. "_" .. message.category .. "_" .. tostring(message.id))
        local apiBase = sanitizeIdentifier(fullName .. "_" .. message.category)
        local serializedParams, passthroughParams = splitParams(message.params)
        local returns = message.returns or {}
        local serializedReturns, passthroughReturns = splitParams(returns)

        local info: MessageInfo = {
            message = message,
            symbol = symbol,
            apiBase = apiBase,
            fullName = fullName,
            serializedParams = serializedParams,
            passthroughParams = passthroughParams,
            serializedReturns = serializedReturns,
            passthroughReturns = passthroughReturns,
        }
        out[#out + 1] = info
        symbolByMessage[message] = symbol
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        collectMessages(child, scopePath .. "." .. child.name, out, symbolByMessage)
    end
end

local function buildScopeTables(
    scope: Analyzer.AnalyzedScope,
    depth: number,
    isRoot: boolean,
    symbolByMessage: { [Analyzer.AnalyzedMessage]: string },
    rootTypeName: string?
): { string }
    local lines: { string } = {}
    if isRoot then
        if rootTypeName ~= nil then
            lines[#lines + 1] = ("local %s: %s = {"):format(scope.name, rootTypeName)
        else
            lines[#lines + 1] = "local " .. scope.name .. " = {"
        end
    else
        lines[#lines + 1] = scope.name .. " = {"
    end

    for index = 1, #scope.messages do
        local msg = scope.messages[index]
        local symbol = symbolByMessage[msg] or msg.name
        lines[#lines + 1] = ("%s = %s,"):format(msg.name, symbol)
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        local childLines = buildScopeTables(child, depth + 1, false, symbolByMessage, nil)
        for lineIndex = 1, #childLines do
            if lineIndex == #childLines then
                lines[#lines + 1] = childLines[lineIndex] .. ","
            else
                lines[#lines + 1] = childLines[lineIndex]
            end
        end
    end

    lines[#lines + 1] = "}"
    return indent(lines, depth)
end

local function paramNames(params: { Ast.Param }): { string }
    local names: { string } = {}
    for index = 1, #params do
        names[#names + 1] = params[index].name
    end
    return names
end

local function canUseDotField(fieldName: string): boolean
    if string.match(fieldName, "^[A-Za-z_][A-Za-z0-9_]*$") == nil then
        return false
    end
    return LUAU_KEYWORDS[fieldName] ~= true
end

local function fieldAccessExpr(valueExpr: string, fieldName: string): string
    if canUseDotField(fieldName) then
        return ("%s.%s"):format(valueExpr, fieldName)
    end
    return ("%s[%q]"):format(valueExpr, fieldName)
end

local function expandDecodeParams(
    params: { Ast.Param },
    structByName: { [string]: Ast.Struct },
    decodeStructMode: DecodeStructMode
): { Ast.Param }
    local expanded: { Ast.Param } = {}
    for index = 1, #params do
        local param = params[index]
        local structDecl = structByName[normalizeTypeKind(param.type.kind)]
        if decodeStructMode == "Locals" and structDecl ~= nil then
            for fieldIndex = 1, #structDecl.fields do
                local field = structDecl.fields[fieldIndex]
                expanded[#expanded + 1] = {
                    name = ("%s_%s"):format(param.name, field.name),
                    type = field.type,
                }
            end
        else
            expanded[#expanded + 1] = param
        end
    end
    return expanded
end

local function buildDecodedParamPlans(
    params: { Ast.Param },
    structByName: { [string]: Ast.Struct },
    decodeStructMode: DecodeStructMode
): { DecodedParamPlan }
    local plans: { DecodedParamPlan } = {}
    for index = 1, #params do
        local param = params[index]
        local paramName = sanitizeIdentifier(param.name)
        local leaves: { DecodedLeaf } = {}
        local structDecl = structByName[normalizeTypeKind(param.type.kind)]
        if decodeStructMode == "Locals" and structDecl ~= nil then
            for fieldIndex = 1, #structDecl.fields do
                local field = structDecl.fields[fieldIndex]
                leaves[#leaves + 1] = {
                    labelSuffix = param.name .. "." .. field.name,
                    targetName = ("decoded_%s_%s"):format(paramName, sanitizeIdentifier(field.name)),
                    typeDef = field.type,
                }
            end
        else
            leaves[#leaves + 1] = {
                labelSuffix = param.name,
                targetName = ("decoded_%s"):format(paramName),
                typeDef = param.type,
            }
        end

        local leafNames: { string } = {}
        for leafIndex = 1, #leaves do
            leafNames[#leafNames + 1] = leaves[leafIndex].targetName
        end
        plans[#plans + 1] = {
            leaves = leaves,
            leafNames = leafNames,
        }
    end
    return plans
end

local function collectDecodedLeafNames(plans: { DecodedParamPlan }): { string }
    local names: { string } = {}
    for planIndex = 1, #plans do
        local leafNames = plans[planIndex].leafNames
        for leafIndex = 1, #leafNames do
            names[#names + 1] = leafNames[leafIndex]
        end
    end
    return names
end

local function canSendEvent(direction: string?, isServer: boolean): boolean
    local resolved = direction or "both"
    if resolved == "client" then
        return not isServer
    end
    if resolved == "server" then
        return isServer
    end
    return true
end

local function canReceiveEvent(direction: string?, isServer: boolean): boolean
    local resolved = direction or "both"
    if resolved == "client" then
        return isServer
    end
    if resolved == "server" then
        return not isServer
    end
    return true
end

local function emitSizeForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    valueExpr: string,
    label: string,
    sizeVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct },
    stringLenHints: { [string]: string }?
)
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"number\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be number", "ERR_TYPE")
            addLine(lines, depth, "end")
            local range = INTEGER_RANGES[kind]
            if range ~= nil then
                addLine(lines, depth, ("if %s %% 1 ~= 0 then"):format(valueExpr))
                emitError(lines, depth + 1, validateLevel, label .. " must be an integer", "ERR_SCHEMA")
                addLine(lines, depth, "end")
                addLine(lines, depth, ("if %s < %s or %s > %s then"):format(valueExpr, tostring(range.min), valueExpr, tostring(range.max)))
                emitError(lines, depth + 1, validateLevel, label .. " out of range", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
        end
        addLine(lines, depth, ("%s += %d"):format(sizeVar, primitiveBytes))
        return
    end

    if kind == "bool" then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"boolean\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be boolean", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += 1"):format(sizeVar))
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local declaredMax = prefixInfo.declaredMax
        local lenVar = nextTemp(state, "stringLen")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"string\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be string", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if depth == 1 and stringLenHints ~= nil then
            stringLenHints[valueExpr] = lenVar
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s) + %s"):format(sizeVar, lenVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d + %s"):format(sizeVar, widthInfo.bytes, lenVar))
        else
            error("Internal string length prefix mismatch")
        end
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Optional type is missing inner value for %s"):format(label))
        end
        addLine(lines, depth, ("%s += 1"):format(sizeVar))
        addLine(lines, depth, ("if %s ~= nil then"):format(valueExpr))
        emitSizeForType(lines, state, valueType, valueExpr, label, sizeVar, depth + 1, validateLevel, structByName, stringLenHints)
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Array type is missing value type for %s"):format(label))
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        local keyVar = nextTemp(state, "arrayKey")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be array table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            addLine(lines, depth + 1, ("if %s[%s] == nil then"):format(valueExpr, indexVar))
            emitError(lines, depth + 2, validateLevel, label .. " must be dense", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = next(%s, nil)"):format(keyVar, valueExpr))
            addLine(lines, depth, ("while %s ~= nil do"):format(keyVar))
            addLine(
                lines,
                depth + 1,
                ("if type(%s) ~= \"number\" or %s %% 1 ~= 0 or %s < 1 or %s > %s then"):format(
                    keyVar,
                    keyVar,
                    keyVar,
                    keyVar,
                    lenVar
                )
            )
            emitError(lines, depth + 2, validateLevel, label .. " must be dense", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
            addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(keyVar, valueExpr, keyVar))
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(sizeVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d"):format(sizeVar, widthInfo.bytes))
        else
            error("Internal array length prefix mismatch")
        end
        if valueKind == "bool" then
            if isValidateFull(validateLevel) then
                local boolValue = nextTemp(state, "arrayBoolValue")
                addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
                addLine(lines, depth + 1, ("local %s = %s[%s]"):format(boolValue, valueExpr, indexVar))
                addLine(lines, depth + 1, ("if type(%s) ~= \"boolean\" then"):format(boolValue))
                emitError(lines, depth + 2, validateLevel, label .. "[] must be boolean", "ERR_TYPE")
                addLine(lines, depth + 1, "end")
                addLine(lines, depth, "end")
            end
            addLine(lines, depth, ("%s += ((%s + 7) // 8)"):format(sizeVar, lenVar))
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            emitSizeForType(
                lines,
                state,
                valueType,
                ("%s[%s]"):format(valueExpr, indexVar),
                label .. "[]",
                sizeVar,
                depth + 1,
                validateLevel,
                structByName,
                stringLenHints
            )
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error(("Map type is missing key/value types for %s"):format(label))
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local mapCount = nextTemp(state, "mapCount")
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be map table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = 0"):format(mapCount))
        addLine(lines, depth, ("local %s, %s = next(%s, nil)"):format(mapKey, mapValue, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(mapKey))
        addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth + 1, ("if %s > %d then"):format(mapCount, declaredMax))
            emitError(lines, depth + 2, validateLevel, label .. " exceeds map bound", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
        end
        emitSizeForType(lines, state, keyType, mapKey, label .. " key", sizeVar, depth + 1, validateLevel, structByName, stringLenHints)
        emitSizeForType(lines, state, valueType, mapValue, label .. " value", sizeVar, depth + 1, validateLevel, structByName, stringLenHints)
        addLine(lines, depth + 1, ("%s, %s = next(%s, %s)"):format(mapKey, mapValue, valueExpr, mapKey))
        addLine(lines, depth, "end")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(mapCount, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(sizeVar, mapCount))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d"):format(sizeVar, widthInfo.bytes))
        else
            error("Internal map length prefix mismatch")
        end
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be struct table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitSizeForType(
                lines,
                state,
                field.type,
                fieldAccessExpr(valueExpr, field.name),
                label .. "." .. field.name,
                sizeVar,
                depth,
                validateLevel,
                structByName,
                stringLenHints
            )
        end
        return
    end

    error(("Unsupported serialized type '%s' in %s"):format(kind, label))
end

local function emitWriteForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    valueExpr: string,
    bufferVar: string,
    offsetVar: string,
    depth: number,
    structByName: { [string]: Ast.Struct },
    stringLenHints: { [string]: string }?
)
    local kind = normalizeTypeKind(typeDef.kind)
    local writer = PRIMITIVE_WRITERS[kind]
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if writer ~= nil and primitiveBytes ~= nil then
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(writer, bufferVar, offsetVar, valueExpr))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, primitiveBytes))
        return
    end

    if kind == "bool" then
        addLine(lines, depth, ("writeu8(%s, %s, %s and 1 or 0)"):format(bufferVar, offsetVar, valueExpr))
        addLine(lines, depth, ("%s += 1"):format(offsetVar))
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local cachedLen: string? = nil
        if depth == 1 and stringLenHints ~= nil then
            cachedLen = stringLenHints[valueExpr]
        end
        local lenExpr: string
        if cachedLen ~= nil then
            lenExpr = cachedLen
        else
            local lenVar = nextTemp(state, "stringLen")
            addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
            lenExpr = lenVar
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, lenExpr))
            addLine(lines, depth, ("writestring(%s, %s, %s)"):format(bufferVar, offsetVar, valueExpr))
            addLine(lines, depth, ("%s += %s"):format(offsetVar, lenExpr))
        elseif widthInfo ~= nil then
            local stringBase = nextTemp(state, "stringBase")
            local stringDataOffset = ("%s + %d"):format(stringBase, widthInfo.bytes)
            addLine(lines, depth, ("local %s = %s"):format(stringBase, offsetVar))
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, stringBase, lenExpr))
            addLine(lines, depth, ("writestring(%s, %s, %s)"):format(bufferVar, stringDataOffset, valueExpr))
            addLine(lines, depth, ("%s = %s + %s"):format(offsetVar, stringDataOffset, lenExpr))
        else
            error("Internal string length prefix mismatch")
        end
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for write path")
        end
        addLine(lines, depth, ("if %s == nil then"):format(valueExpr))
        addLine(lines, depth + 1, ("writeu8(%s, %s, 0)"):format(bufferVar, offsetVar))
        addLine(lines, depth + 1, ("%s += 1"):format(offsetVar))
        addLine(lines, depth, "else")
        addLine(lines, depth + 1, ("writeu8(%s, %s, 1)"):format(bufferVar, offsetVar))
        addLine(lines, depth + 1, ("%s += 1"):format(offsetVar))
        emitWriteForType(lines, state, valueType, valueExpr, bufferVar, offsetVar, depth + 1, structByName, stringLenHints)
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for write path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, lenVar))
            addLine(lines, depth, ("%s += %d"):format(offsetVar, widthInfo.bytes))
        else
            error("Internal array length prefix mismatch")
        end
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local valueIndex = nextTemp(state, "arrayValueIndex")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            local packedByte = nextTemp(state, "arrayPackedByte")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, lenVar))
            addLine(lines, depth, ("local %s = 1"):format(valueIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = 0"):format(packedByte))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            addLine(lines, depth + 2, ("if %s > %s then"):format(valueIndex, lenVar))
            addLine(lines, depth + 3, "break")
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("if %s[%s] then"):format(valueExpr, valueIndex))
            addLine(lines, depth + 3, ("%s = bor(%s, %s)"):format(packedByte, packedByte, bitMask))
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("%s += 1"):format(valueIndex))
            addLine(lines, depth + 2, ("%s = lshift(%s, 1)"):format(bitMask, bitMask))
            addLine(lines, depth + 1, "end")
            addLine(lines, depth + 1, ("writeu8(%s, %s, %s)"):format(bufferVar, offsetVar, packedByte))
            addLine(lines, depth + 1, ("%s += 1"):format(offsetVar))
            addLine(lines, depth, "end")
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            emitWriteForType(
                lines,
                state,
                valueType,
                ("%s[%s]"):format(valueExpr, indexVar),
                bufferVar,
                offsetVar,
                depth + 1,
                structByName,
                stringLenHints
            )
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for write path")
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local mapCount = nextTemp(state, "mapCount")
        local countKey = nextTemp(state, "mapCountKey")
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        addLine(lines, depth, ("local %s = 0"):format(mapCount))
        addLine(lines, depth, ("local %s = next(%s, nil)"):format(countKey, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(countKey))
        addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
        addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(countKey, valueExpr, countKey))
        addLine(lines, depth, "end")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, mapCount))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, mapCount))
            addLine(lines, depth, ("%s += %d"):format(offsetVar, widthInfo.bytes))
        else
            error("Internal map length prefix mismatch")
        end
        addLine(lines, depth, ("local %s, %s = next(%s, nil)"):format(mapKey, mapValue, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(mapKey))
        emitWriteForType(lines, state, keyType, mapKey, bufferVar, offsetVar, depth + 1, structByName, stringLenHints)
        emitWriteForType(lines, state, valueType, mapValue, bufferVar, offsetVar, depth + 1, structByName, stringLenHints)
        addLine(lines, depth + 1, ("%s, %s = next(%s, %s)"):format(mapKey, mapValue, valueExpr, mapKey))
        addLine(lines, depth, "end")
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitWriteForType(
                lines,
                state,
                field.type,
                fieldAccessExpr(valueExpr, field.name),
                bufferVar,
                offsetVar,
                depth,
                structByName,
                stringLenHints
            )
        end
        return
    end

    error(("Unsupported serialized type '%s' in write path"):format(kind))
end

local function fixedBytesForType(typeDef: Ast.Type): number?
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        return primitiveBytes
    end
    if kind == "bool" then
        return 1
    end
    return nil
end

local function offsetExpr(baseExpr: string, offset: number): string
    if offset == 0 then
        return baseExpr
    end
    return ("%s + %d"):format(baseExpr, offset)
end

local function emitWriteFixedToBlock(
    lines: { string },
    typeDef: Ast.Type,
    valueExpr: string,
    bufferVar: string,
    blockVar: string,
    blockOffset: number,
    depth: number
)
    local writeOffset = offsetExpr(blockVar, blockOffset)
    local kind = normalizeTypeKind(typeDef.kind)
    local writer = PRIMITIVE_WRITERS[kind]
    if writer ~= nil then
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(writer, bufferVar, writeOffset, valueExpr))
        return
    end
    if kind == "bool" then
        addLine(lines, depth, ("writeu8(%s, %s, %s and 1 or 0)"):format(bufferVar, writeOffset, valueExpr))
        return
    end
    error(("Unsupported serialized type '%s' in fixed write path"):format(kind))
end

local function emitReserveInline(
    lines: { string },
    depth: number,
    offsetVar: string,
    payloadLengthVar: string,
    sizeExpr: string,
    startVar: string,
    nextVar: string,
    validateLevel: Analyzer.ValidateLevel,
    label: string
)
    addLine(lines, depth, ("local %s = %s"):format(startVar, offsetVar))
    addLine(lines, depth, ("local %s = %s + %s"):format(nextVar, startVar, sizeExpr))
    addLine(lines, depth, ("if %s > %s then"):format(nextVar, payloadLengthVar))
    emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
    addLine(lines, depth, "end")
    addLine(lines, depth, ("%s = %s"):format(offsetVar, nextVar))
end

local function emitReadFixedFromBlock(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    targetVar: string,
    label: string,
    payloadVar: string,
    blockVar: string,
    blockOffset: number,
    depth: number,
    validateLevel: Analyzer.ValidateLevel
)
    local readOffset = offsetExpr(blockVar, blockOffset)
    local kind = normalizeTypeKind(typeDef.kind)
    local reader = PRIMITIVE_READERS[kind]
    if reader ~= nil then
        addLine(lines, depth, ("%s = (%s(%s, %s) :: %s)"):format(targetVar, reader, payloadVar, readOffset, toLuauType(typeDef)))
        return
    end

    if kind == "bool" then
        local rawBool = nextTemp(state, "rawBool")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rawBool, payloadVar, readOffset))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(rawBool, rawBool))
            emitError(lines, depth + 1, validateLevel, label .. " invalid boolean tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s == 1"):format(targetVar, rawBool))
        return
    end

    error(("Unsupported serialized type '%s' in fixed read path"):format(kind))
end

local function emitReadForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    targetVar: string,
    label: string,
    payloadVar: string,
    payloadLengthVar: string,
    offsetVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    local reader = PRIMITIVE_READERS[kind]
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if reader ~= nil and primitiveBytes ~= nil then
        local fieldNext = nextTemp(state, "fieldNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(fieldNext, offsetVar, primitiveBytes))
        addLine(lines, depth, ("if %s > %s then"):format(fieldNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = (%s(%s, %s) :: %s)"):format(targetVar, reader, payloadVar, offsetVar, toLuauType(typeDef)))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, fieldNext))
        return
    end

    if kind == "bool" then
        local boolNext = nextTemp(state, "boolNext")
        local rawBool = nextTemp(state, "rawBool")
        addLine(lines, depth, ("local %s = %s + 1"):format(boolNext, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(boolNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rawBool, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, boolNext))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(rawBool, rawBool))
            emitError(lines, depth + 1, validateLevel, label .. " invalid boolean tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s == 1"):format(targetVar, rawBool))
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local strLen = nextTemp(state, "stringLen")
        local strNext = nextTemp(state, "stringNext")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(strLen))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(strLen, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local lenNext = nextTemp(state, "stringLenNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(lenNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(lenNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(strLen, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, lenNext))
        else
            error("Internal string length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(strLen, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(strLen, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = %s + %s"):format(strNext, offsetVar, strLen))
        addLine(lines, depth, ("if %s > %s then"):format(strNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = readstring(%s, %s, %s)"):format(targetVar, payloadVar, offsetVar, strLen))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, strNext))
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for read path")
        end
        local flagNext = nextTemp(state, "optionalFlagNext")
        local optionalFlag = nextTemp(state, "optionalFlag")
        local optionalValue = nextTemp(state, "optionalValue")
        addLine(lines, depth, ("local %s = %s + 1"):format(flagNext, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(flagNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(optionalFlag, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, flagNext))
        addLine(lines, depth, ("if %s == 0 then"):format(optionalFlag))
        addLine(lines, depth + 1, ("%s = nil"):format(targetVar))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("elseif %s == 1 then"):format(optionalFlag))
            addLine(lines, depth + 1, ("local %s"):format(optionalValue))
            emitReadForType(lines, state, valueType, optionalValue, label, payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth + 1, ("%s = %s"):format(targetVar, optionalValue))
            addLine(lines, depth, "else")
            emitError(lines, depth + 1, validateLevel, label .. " invalid optional tag", "ERR_TAG")
        else
            addLine(lines, depth, "else")
            addLine(lines, depth + 1, ("local %s"):format(optionalValue))
            emitReadForType(lines, state, valueType, optionalValue, label, payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth + 1, ("%s = %s"):format(targetVar, optionalValue))
        end
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for read path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local maxLen = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "arrayCount")
        local indexVar = nextTemp(state, "arrayIndex")
        local arrayVar = nextTemp(state, "arrayValues")
        local valueVar = nextTemp(state, "arrayValue")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "arrayCountNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, countNext))
        else
            error("Internal array length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and maxLen ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = table.create(%s)"):format(arrayVar, countVar))
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedCursor = nextTemp(state, "arrayPackedCursor")
            local packedNext = nextTemp(state, "arrayPackedNext")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local unpackIndex = nextTemp(state, "arrayUnpackIndex")
            local packedByte = nextTemp(state, "arrayPackedByte")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
            addLine(lines, depth, ("local %s = %s"):format(packedCursor, offsetVar))
            addLine(lines, depth, ("local %s = %s + %s"):format(packedNext, packedCursor, packedByteCount))
            addLine(lines, depth, ("if %s > %s then"):format(packedNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = 1"):format(unpackIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = readu8(%s, %s)"):format(packedByte, payloadVar, packedCursor))
            addLine(lines, depth + 1, ("%s += 1"):format(packedCursor))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            addLine(lines, depth + 2, ("if %s > %s then"):format(unpackIndex, countVar))
            addLine(lines, depth + 3, "break")
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("%s[%s] = band(%s, %s) ~= 0"):format(arrayVar, unpackIndex, packedByte, bitMask))
            addLine(lines, depth + 2, ("%s += 1"):format(unpackIndex))
            addLine(lines, depth + 2, ("%s = lshift(%s, 1)"):format(bitMask, bitMask))
            addLine(lines, depth + 1, "end")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(offsetVar, packedCursor))
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
            addLine(lines, depth + 1, ("local %s"):format(valueVar))
            emitReadForType(lines, state, valueType, valueVar, label .. "[]", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth + 1, ("%s[%s] = %s"):format(arrayVar, indexVar, valueVar))
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, arrayVar))
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for read path")
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local maxLen = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "mapCount")
        local indexVar = nextTemp(state, "mapIndex")
        local mapVar = nextTemp(state, "mapValues")
        local keyVar = nextTemp(state, "mapKey")
        local valueVar = nextTemp(state, "mapValue")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "mapCountNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, countNext))
        else
            error("Internal map length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and maxLen ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds map bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = {}"):format(mapVar))
        addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
        addLine(lines, depth + 1, ("local %s"):format(keyVar))
        emitReadForType(lines, state, keyType, keyVar, label .. " key", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth + 1, ("local %s"):format(valueVar))
        emitReadForType(lines, state, valueType, valueVar, label .. " value", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth + 1, ("%s[%s] = %s"):format(mapVar, keyVar, valueVar))
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(targetVar, mapVar))
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        local structVar = nextTemp(state, "structValue")
        addLine(lines, depth, ("local %s = {}"):format(structVar))
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            local fieldVar = nextTemp(state, "structField")
            addLine(lines, depth, ("local %s"):format(fieldVar))
            emitReadForType(
                lines,
                state,
                field.type,
                fieldVar,
                label .. "." .. field.name,
                payloadVar,
                payloadLengthVar,
                offsetVar,
                depth,
                validateLevel,
                structByName
            )
            addLine(lines, depth, ("%s[%q] = %s"):format(structVar, field.name, fieldVar))
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, structVar))
        return
    end

    error(("Unsupported serialized type '%s' in read path"):format(kind))
end

local function emitSkipForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    label: string,
    payloadVar: string,
    payloadLengthVar: string,
    offsetVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        local nextOffset = nextTemp(state, "skipNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, primitiveBytes))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "bool" then
        local nextOffset = nextTemp(state, "skipBoolNext")
        addLine(lines, depth, ("local %s = %s + 1"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        if isValidateBasicOrFull(validateLevel) then
            local rawBool = nextTemp(state, "skipRawBool")
            addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rawBool, payloadVar, offsetVar))
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(rawBool, rawBool))
            emitError(lines, depth + 1, validateLevel, label .. " invalid boolean tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local strLen = nextTemp(state, "skipStringLen")
        local strNext = nextTemp(state, "skipStringNext")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(strLen))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(strLen, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local lenNext = nextTemp(state, "skipStringLenNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(lenNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(lenNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(strLen, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, lenNext))
        else
            error("Internal string length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(strLen, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(strLen, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = %s + %s"):format(strNext, offsetVar, strLen))
        addLine(lines, depth, ("if %s > %s then"):format(strNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, strNext))
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for skip path")
        end
        local flagNext = nextTemp(state, "skipOptionalFlagNext")
        local optionalFlag = nextTemp(state, "skipOptionalFlag")
        addLine(lines, depth, ("local %s = %s + 1"):format(flagNext, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(flagNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(optionalFlag, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, flagNext))
        addLine(lines, depth, ("if %s == 0 then"):format(optionalFlag))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("elseif %s == 1 then"):format(optionalFlag))
            emitSkipForType(lines, state, valueType, label, payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth, "else")
            emitError(lines, depth + 1, validateLevel, label .. " invalid optional tag", "ERR_TAG")
        else
            addLine(lines, depth, "else")
            emitSkipForType(lines, state, valueType, label, payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
        end
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for skip path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local maxLen = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "skipArrayCount")
        local indexVar = nextTemp(state, "skipArrayIndex")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "skipArrayCountNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, countNext))
        else
            error("Internal array length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and maxLen ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "skipArrayPackedByteCount")
            local packedNext = nextTemp(state, "skipArrayPackedNext")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
            addLine(lines, depth, ("local %s = %s + %s"):format(packedNext, offsetVar, packedByteCount))
            addLine(lines, depth, ("if %s > %s then"):format(packedNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(offsetVar, packedNext))
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
            emitSkipForType(lines, state, valueType, label .. "[]", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for skip path")
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local maxLen = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "skipMapCount")
        local indexVar = nextTemp(state, "skipMapIndex")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "skipMapCountNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, countNext))
        else
            error("Internal map length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and maxLen ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds map bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
        emitSkipForType(lines, state, keyType, label .. " key", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
        emitSkipForType(lines, state, valueType, label .. " value", payloadVar, payloadLengthVar, offsetVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth, "end")
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitSkipForType(
                lines,
                state,
                field.type,
                label .. "." .. field.name,
                payloadVar,
                payloadLengthVar,
                offsetVar,
                depth,
                validateLevel,
                structByName
            )
        end
        return
    end

    error(("Unsupported serialized type '%s' in skip path"):format(kind))
end

local function typeHasVariableLength(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): boolean
    local kind = normalizeTypeKind(typeDef.kind)
    if kind == "string" or kind == "array" or kind == "map" or kind == "optional" then
        return true
    end
    if PRIMITIVE_BYTES[kind] ~= nil or kind == "bool" then
        return false
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return false
        end
        seenStructs[kind] = true
        for fieldIndex = 1, #structDecl.fields do
            if typeHasVariableLength(structDecl.fields[fieldIndex].type, structByName, seenStructs) then
                seenStructs[kind] = nil
                return true
            end
        end
        seenStructs[kind] = nil
        return false
    end
    return false
end

local function paramsHaveVariableLength(params: { Ast.Param }, structByName: { [string]: Ast.Struct }): boolean
    local seenStructs: { [string]: boolean } = {}
    for index = 1, #params do
        if typeHasVariableLength(params[index].type, structByName, seenStructs) then
            return true
        end
    end
    return false
end

local function fixedBytesForCanonicalType(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): number
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        return primitiveBytes
    end
    if kind == "bool" then
        return 1
    end
    if kind == "string" or kind == "array" or kind == "map" or kind == "optional" then
        return 0
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return 0
        end
        seenStructs[kind] = true
        local total = 0
        for fieldIndex = 1, #structDecl.fields do
            total += fixedBytesForCanonicalType(structDecl.fields[fieldIndex].type, structByName, seenStructs)
        end
        seenStructs[kind] = nil
        return total
    end
    return 0
end

local function fixedBytesForCanonicalParams(params: { Ast.Param }, structByName: { [string]: Ast.Struct }): number
    local seenStructs: { [string]: boolean } = {}
    local total = 0
    for index = 1, #params do
        total += fixedBytesForCanonicalType(params[index].type, structByName, seenStructs)
    end
    return total
end

local function emitCanonicalSizeForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    valueExpr: string,
    label: string,
    prefixSizeVar: string,
    varSizeVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct },
    stringLenHints: { [string]: string }?
)
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"number\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be number", "ERR_TYPE")
            addLine(lines, depth, "end")
            local range = INTEGER_RANGES[kind]
            if range ~= nil then
                addLine(lines, depth, ("if %s %% 1 ~= 0 then"):format(valueExpr))
                emitError(lines, depth + 1, validateLevel, label .. " must be an integer", "ERR_SCHEMA")
                addLine(lines, depth, "end")
                addLine(lines, depth, ("if %s < %s or %s > %s then"):format(valueExpr, tostring(range.min), valueExpr, tostring(range.max)))
                emitError(lines, depth + 1, validateLevel, label .. " out of range", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
        end
        return
    end

    if kind == "bool" then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"boolean\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be boolean", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local declaredMax = prefixInfo.declaredMax
        local lenVar = nextTemp(state, "stringLen")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"string\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be string", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if depth == 1 and stringLenHints ~= nil then
            stringLenHints[valueExpr] = lenVar
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(prefixSizeVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d"):format(prefixSizeVar, widthInfo.bytes))
        else
            error("Internal string length prefix mismatch")
        end
        addLine(lines, depth, ("%s += %s"):format(varSizeVar, lenVar))
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Optional type is missing inner value for %s"):format(label))
        end
        addLine(lines, depth, ("%s += 1"):format(prefixSizeVar))
        addLine(lines, depth, ("if %s ~= nil then"):format(valueExpr))
        emitSizeForType(lines, state, valueType, valueExpr, label, varSizeVar, depth + 1, validateLevel, structByName, nil)
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Array type is missing value type for %s"):format(label))
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        local keyVar = nextTemp(state, "arrayKey")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be array table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            addLine(lines, depth + 1, ("if %s[%s] == nil then"):format(valueExpr, indexVar))
            emitError(lines, depth + 2, validateLevel, label .. " must be dense", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = next(%s, nil)"):format(keyVar, valueExpr))
            addLine(lines, depth, ("while %s ~= nil do"):format(keyVar))
            addLine(
                lines,
                depth + 1,
                ("if type(%s) ~= \"number\" or %s %% 1 ~= 0 or %s < 1 or %s > %s then"):format(
                    keyVar,
                    keyVar,
                    keyVar,
                    keyVar,
                    lenVar
                )
            )
            emitError(lines, depth + 2, validateLevel, label .. " must be dense", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
            addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(keyVar, valueExpr, keyVar))
            addLine(lines, depth, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(prefixSizeVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d"):format(prefixSizeVar, widthInfo.bytes))
        else
            error("Internal array length prefix mismatch")
        end
        if valueKind == "bool" then
            if isValidateFull(validateLevel) then
                local boolValue = nextTemp(state, "arrayBoolValue")
                addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
                addLine(lines, depth + 1, ("local %s = %s[%s]"):format(boolValue, valueExpr, indexVar))
                addLine(lines, depth + 1, ("if type(%s) ~= \"boolean\" then"):format(boolValue))
                emitError(lines, depth + 2, validateLevel, label .. "[] must be boolean", "ERR_TYPE")
                addLine(lines, depth + 1, "end")
                addLine(lines, depth, "end")
            end
            addLine(lines, depth, ("%s += ((%s + 7) // 8)"):format(varSizeVar, lenVar))
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            emitSizeForType(
                lines,
                state,
                valueType,
                ("%s[%s]"):format(valueExpr, indexVar),
                label .. "[]",
                varSizeVar,
                depth + 1,
                validateLevel,
                structByName,
                nil
            )
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error(("Map type is missing key/value types for %s"):format(label))
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local mapCount = nextTemp(state, "mapCount")
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be map table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = 0"):format(mapCount))
        addLine(lines, depth, ("local %s, %s = next(%s, nil)"):format(mapKey, mapValue, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(mapKey))
        addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth + 1, ("if %s > %d then"):format(mapCount, declaredMax))
            emitError(lines, depth + 2, validateLevel, label .. " exceeds map bound", "ERR_SCHEMA")
            addLine(lines, depth + 1, "end")
        end
        emitSizeForType(lines, state, keyType, mapKey, label .. " key", varSizeVar, depth + 1, validateLevel, structByName, nil)
        emitSizeForType(lines, state, valueType, mapValue, label .. " value", varSizeVar, depth + 1, validateLevel, structByName, nil)
        addLine(lines, depth + 1, ("%s, %s = next(%s, %s)"):format(mapKey, mapValue, valueExpr, mapKey))
        addLine(lines, depth, "end")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(mapCount, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(prefixSizeVar, mapCount))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s += %d"):format(prefixSizeVar, widthInfo.bytes))
        else
            error("Internal map length prefix mismatch")
        end
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be struct table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitCanonicalSizeForType(
                lines,
                state,
                field.type,
                fieldAccessExpr(valueExpr, field.name),
                label .. "." .. field.name,
                prefixSizeVar,
                varSizeVar,
                depth,
                validateLevel,
                structByName,
                stringLenHints
            )
        end
        return
    end

    error(("Unsupported canonical serialized type '%s' in %s"):format(kind, label))
end

local function emitWriteCanonicalForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    valueExpr: string,
    bufferVar: string,
    prefixVar: string,
    fixedVar: string,
    varVar: string,
    depth: number,
    structByName: { [string]: Ast.Struct },
    stringLenHints: { [string]: string }?
)
    local kind = normalizeTypeKind(typeDef.kind)
    local writer = PRIMITIVE_WRITERS[kind]
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if writer ~= nil and primitiveBytes ~= nil then
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(writer, bufferVar, fixedVar, valueExpr))
        addLine(lines, depth, ("%s += %d"):format(fixedVar, primitiveBytes))
        return
    end

    if kind == "bool" then
        addLine(lines, depth, ("writeu8(%s, %s, %s and 1 or 0)"):format(bufferVar, fixedVar, valueExpr))
        addLine(lines, depth, ("%s += 1"):format(fixedVar))
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local cachedLen: string? = nil
        if depth == 1 and stringLenHints ~= nil then
            cachedLen = stringLenHints[valueExpr]
        end
        local lenExpr: string
        if cachedLen ~= nil then
            lenExpr = cachedLen
        else
            local lenVar = nextTemp(state, "stringLen")
            addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
            lenExpr = lenVar
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(prefixVar, bufferVar, prefixVar, lenExpr))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, prefixVar, lenExpr))
            addLine(lines, depth, ("%s += %d"):format(prefixVar, widthInfo.bytes))
        else
            error("Internal string length prefix mismatch")
        end
        addLine(lines, depth, ("writestring(%s, %s, %s)"):format(bufferVar, varVar, valueExpr))
        addLine(lines, depth, ("%s += %s"):format(varVar, lenExpr))
        return
    end

    if kind == "optional" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for canonical write path")
        end
        addLine(lines, depth, ("if %s == nil then"):format(valueExpr))
        addLine(lines, depth + 1, ("writeu8(%s, %s, 0)"):format(bufferVar, prefixVar))
        addLine(lines, depth + 1, ("%s += 1"):format(prefixVar))
        addLine(lines, depth, "else")
        addLine(lines, depth + 1, ("writeu8(%s, %s, 1)"):format(bufferVar, prefixVar))
        addLine(lines, depth + 1, ("%s += 1"):format(prefixVar))
        emitWriteForType(lines, state, valueType, valueExpr, bufferVar, varVar, depth + 1, structByName, nil)
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical write path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(prefixVar, bufferVar, prefixVar, lenVar))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, prefixVar, lenVar))
            addLine(lines, depth, ("%s += %d"):format(prefixVar, widthInfo.bytes))
        else
            error("Internal array length prefix mismatch")
        end
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local valueIndex = nextTemp(state, "arrayValueIndex")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            local packedByte = nextTemp(state, "arrayPackedByte")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, lenVar))
            addLine(lines, depth, ("local %s = 1"):format(valueIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = 0"):format(packedByte))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            addLine(lines, depth + 2, ("if %s > %s then"):format(valueIndex, lenVar))
            addLine(lines, depth + 3, "break")
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("if %s[%s] then"):format(valueExpr, valueIndex))
            addLine(lines, depth + 3, ("%s = bor(%s, %s)"):format(packedByte, packedByte, bitMask))
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("%s += 1"):format(valueIndex))
            addLine(lines, depth + 2, ("%s = lshift(%s, 1)"):format(bitMask, bitMask))
            addLine(lines, depth + 1, "end")
            addLine(lines, depth + 1, ("writeu8(%s, %s, %s)"):format(bufferVar, varVar, packedByte))
            addLine(lines, depth + 1, ("%s += 1"):format(varVar))
            addLine(lines, depth, "end")
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, lenVar))
            emitWriteForType(lines, state, valueType, ("%s[%s]"):format(valueExpr, indexVar), bufferVar, varVar, depth + 1, structByName, nil)
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for canonical write path")
        end
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local mapCount = nextTemp(state, "mapCount")
        local countKey = nextTemp(state, "mapCountKey")
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        addLine(lines, depth, ("local %s = 0"):format(mapCount))
        addLine(lines, depth, ("local %s = next(%s, nil)"):format(countKey, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(countKey))
        addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
        addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(countKey, valueExpr, countKey))
        addLine(lines, depth, "end")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(prefixVar, bufferVar, prefixVar, mapCount))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, prefixVar, mapCount))
            addLine(lines, depth, ("%s += %d"):format(prefixVar, widthInfo.bytes))
        else
            error("Internal map length prefix mismatch")
        end
        addLine(lines, depth, ("local %s, %s = next(%s, nil)"):format(mapKey, mapValue, valueExpr))
        addLine(lines, depth, ("while %s ~= nil do"):format(mapKey))
        emitWriteForType(lines, state, keyType, mapKey, bufferVar, varVar, depth + 1, structByName, nil)
        emitWriteForType(lines, state, valueType, mapValue, bufferVar, varVar, depth + 1, structByName, nil)
        addLine(lines, depth + 1, ("%s, %s = next(%s, %s)"):format(mapKey, mapValue, valueExpr, mapKey))
        addLine(lines, depth, "end")
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitWriteCanonicalForType(
                lines,
                state,
                field.type,
                fieldAccessExpr(valueExpr, field.name),
                bufferVar,
                prefixVar,
                fixedVar,
                varVar,
                depth,
                structByName,
                stringLenHints
            )
        end
        return
    end

    error(("Unsupported canonical serialized type '%s' in write path"):format(kind))
end

local function consumeDecodeVarMeta(metas: { DecodeVarMeta }, cursor: DecodeVarCursor, expectedKind: string): DecodeVarMeta
    local meta = metas[cursor.index]
    if meta == nil or meta.kind ~= expectedKind then
        error(("Internal canonical decode metadata mismatch (expected %s)"):format(expectedKind))
    end
    cursor.index += 1
    return meta
end

local function emitDecodeCanonicalPrefixForType(
    lines: { string },
    state: EmitState,
    metas: { DecodeVarMeta },
    typeDef: Ast.Type,
    label: string,
    payloadVar: string,
    payloadLengthVar: string,
    prefixVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    if PRIMITIVE_BYTES[kind] ~= nil or kind == "bool" then
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local lenVar = nextTemp(state, "stringLen")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(lenVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(lenVar, prefixVar, payloadVar, payloadLengthVar, prefixVar))
        elseif widthInfo ~= nil then
            local lenNext = nextTemp(state, "prefixNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(lenNext, prefixVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(lenNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(lenVar, widthInfo.reader, payloadVar, prefixVar))
            addLine(lines, depth, ("%s = %s"):format(prefixVar, lenNext))
        else
            error("Internal string length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        metas[#metas + 1] = {
            kind = "string",
            valueVar = lenVar,
        }
        return
    end

    if kind == "optional" then
        local tagVar = nextTemp(state, "optionalTag")
        local tagNext = nextTemp(state, "optionalTagNext")
        addLine(lines, depth, ("local %s = %s + 1"):format(tagNext, prefixVar))
        addLine(lines, depth, ("if %s > %s then"):format(tagNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(tagVar, payloadVar, prefixVar))
        addLine(lines, depth, ("%s = %s"):format(prefixVar, tagNext))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(tagVar, tagVar))
            emitError(lines, depth + 1, validateLevel, label .. " invalid optional tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        metas[#metas + 1] = {
            kind = "optional",
            valueVar = tagVar,
        }
        return
    end

    if kind == "array" then
        local prefixInfo = getArrayLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "arrayCount")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, prefixVar, payloadVar, payloadLengthVar, prefixVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "prefixNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, prefixVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, prefixVar))
            addLine(lines, depth, ("%s = %s"):format(prefixVar, countNext))
        else
            error("Internal array length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        metas[#metas + 1] = {
            kind = "array",
            valueVar = countVar,
        }
        return
    end

    if kind == "map" then
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local countVar = nextTemp(state, "mapCount")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(countVar))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(countVar, prefixVar, payloadVar, payloadLengthVar, prefixVar))
        elseif widthInfo ~= nil then
            local countNext = nextTemp(state, "prefixNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(countNext, prefixVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(countNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(countVar, widthInfo.reader, payloadVar, prefixVar))
            addLine(lines, depth, ("%s = %s"):format(prefixVar, countNext))
        else
            error("Internal map length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds map bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        metas[#metas + 1] = {
            kind = "map",
            valueVar = countVar,
        }
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitDecodeCanonicalPrefixForType(
                lines,
                state,
                metas,
                field.type,
                label .. "." .. field.name,
                payloadVar,
                payloadLengthVar,
                prefixVar,
                depth,
                validateLevel,
                structByName
            )
        end
        return
    end

    error(("Unsupported canonical serialized type '%s' in prefix read path"):format(kind))
end

local function emitDecodeCanonicalDataForType(
    lines: { string },
    state: EmitState,
    metas: { DecodeVarMeta },
    cursor: DecodeVarCursor,
    typeDef: Ast.Type,
    targetVar: string,
    label: string,
    payloadVar: string,
    payloadLengthVar: string,
    fixedVar: string,
    varVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    local reader = PRIMITIVE_READERS[kind]
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if reader ~= nil and primitiveBytes ~= nil then
        addLine(lines, depth, ("%s = (%s(%s, %s) :: %s)"):format(targetVar, reader, payloadVar, fixedVar, toLuauType(typeDef)))
        addLine(lines, depth, ("%s += %d"):format(fixedVar, primitiveBytes))
        return
    end

    if kind == "bool" then
        local rawBool = nextTemp(state, "rawBool")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rawBool, payloadVar, fixedVar))
        addLine(lines, depth, ("%s += 1"):format(fixedVar))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(rawBool, rawBool))
            emitError(lines, depth + 1, validateLevel, label .. " invalid boolean tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s == 1"):format(targetVar, rawBool))
        return
    end

    if kind == "string" then
        local meta = consumeDecodeVarMeta(metas, cursor, "string")
        local strLen = meta.valueVar
        local strNext = nextTemp(state, "stringNext")
        addLine(lines, depth, ("local %s = %s + %s"):format(strNext, varVar, strLen))
        addLine(lines, depth, ("if %s > %s then"):format(strNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = readstring(%s, %s, %s)"):format(targetVar, payloadVar, varVar, strLen))
        addLine(lines, depth, ("%s = %s"):format(varVar, strNext))
        return
    end

    if kind == "optional" then
        local meta = consumeDecodeVarMeta(metas, cursor, "optional")
        local tagVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for canonical read path")
        end
        local optionalValue = nextTemp(state, "optionalValue")
        addLine(lines, depth, ("if %s == 0 then"):format(tagVar))
        addLine(lines, depth + 1, ("%s = nil"):format(targetVar))
        addLine(lines, depth, "else")
        addLine(lines, depth + 1, ("local %s"):format(optionalValue))
        emitReadForType(lines, state, valueType, optionalValue, label, payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth + 1, ("%s = %s"):format(targetVar, optionalValue))
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local meta = consumeDecodeVarMeta(metas, cursor, "array")
        local countVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical read path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local indexVar = nextTemp(state, "arrayIndex")
        local arrayVar = nextTemp(state, "arrayValues")
        local valueVar = nextTemp(state, "arrayValue")
        addLine(lines, depth, ("local %s = table.create(%s)"):format(arrayVar, countVar))
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedCursor = nextTemp(state, "arrayPackedCursor")
            local packedNext = nextTemp(state, "arrayPackedNext")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local unpackIndex = nextTemp(state, "arrayUnpackIndex")
            local packedByte = nextTemp(state, "arrayPackedByte")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
            addLine(lines, depth, ("local %s = %s"):format(packedCursor, varVar))
            addLine(lines, depth, ("local %s = %s + %s"):format(packedNext, packedCursor, packedByteCount))
            addLine(lines, depth, ("if %s > %s then"):format(packedNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = 1"):format(unpackIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = readu8(%s, %s)"):format(packedByte, payloadVar, packedCursor))
            addLine(lines, depth + 1, ("%s += 1"):format(packedCursor))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            addLine(lines, depth + 2, ("if %s > %s then"):format(unpackIndex, countVar))
            addLine(lines, depth + 3, "break")
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("%s[%s] = band(%s, %s) ~= 0"):format(arrayVar, unpackIndex, packedByte, bitMask))
            addLine(lines, depth + 2, ("%s += 1"):format(unpackIndex))
            addLine(lines, depth + 2, ("%s = lshift(%s, 1)"):format(bitMask, bitMask))
            addLine(lines, depth + 1, "end")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(varVar, packedCursor))
        else
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
            addLine(lines, depth + 1, ("local %s"):format(valueVar))
            emitReadForType(lines, state, valueType, valueVar, label .. "[]", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth + 1, ("%s[%s] = %s"):format(arrayVar, indexVar, valueVar))
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, arrayVar))
        return
    end

    if kind == "map" then
        local meta = consumeDecodeVarMeta(metas, cursor, "map")
        local countVar = meta.valueVar
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for canonical read path")
        end
        local indexVar = nextTemp(state, "mapIndex")
        local mapVar = nextTemp(state, "mapValues")
        local keyVar = nextTemp(state, "mapKey")
        local valueVar = nextTemp(state, "mapValue")
        addLine(lines, depth, ("local %s = {}"):format(mapVar))
        addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
        addLine(lines, depth + 1, ("local %s"):format(keyVar))
        emitReadForType(lines, state, keyType, keyVar, label .. " key", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth + 1, ("local %s"):format(valueVar))
        emitReadForType(lines, state, valueType, valueVar, label .. " value", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth + 1, ("%s[%s] = %s"):format(mapVar, keyVar, valueVar))
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(targetVar, mapVar))
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        local structVar = nextTemp(state, "structValue")
        addLine(lines, depth, ("local %s = {}"):format(structVar))
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            local fieldVar = nextTemp(state, "structField")
            addLine(lines, depth, ("local %s"):format(fieldVar))
            emitDecodeCanonicalDataForType(
                lines,
                state,
                metas,
                cursor,
                field.type,
                fieldVar,
                label .. "." .. field.name,
                payloadVar,
                payloadLengthVar,
                fixedVar,
                varVar,
                depth,
                validateLevel,
                structByName
            )
            addLine(lines, depth, ("%s[%q] = %s"):format(structVar, field.name, fieldVar))
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, structVar))
        return
    end

    error(("Unsupported canonical serialized type '%s' in data read path"):format(kind))
end

local function emitSkipCanonicalDataForType(
    lines: { string },
    state: EmitState,
    metas: { DecodeVarMeta },
    cursor: DecodeVarCursor,
    typeDef: Ast.Type,
    label: string,
    payloadVar: string,
    payloadLengthVar: string,
    fixedVar: string,
    varVar: string,
    depth: number,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        addLine(lines, depth, ("%s += %d"):format(fixedVar, primitiveBytes))
        return
    end

    if kind == "bool" then
        if isValidateBasicOrFull(validateLevel) then
            local rawBool = nextTemp(state, "skipRawBool")
            addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rawBool, payloadVar, fixedVar))
            addLine(lines, depth, ("if %s ~= 0 and %s ~= 1 then"):format(rawBool, rawBool))
            emitError(lines, depth + 1, validateLevel, label .. " invalid boolean tag", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += 1"):format(fixedVar))
        return
    end

    if kind == "string" then
        local meta = consumeDecodeVarMeta(metas, cursor, "string")
        local strLen = meta.valueVar
        local strNext = nextTemp(state, "skipStringNext")
        addLine(lines, depth, ("local %s = %s + %s"):format(strNext, varVar, strLen))
        addLine(lines, depth, ("if %s > %s then"):format(strNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(varVar, strNext))
        return
    end

    if kind == "optional" then
        local meta = consumeDecodeVarMeta(metas, cursor, "optional")
        local tagVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Optional type missing value type for canonical skip path")
        end
        addLine(lines, depth, ("if %s ~= 0 then"):format(tagVar))
        emitSkipForType(lines, state, valueType, label, payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth, "end")
        return
    end

    if kind == "array" then
        local meta = consumeDecodeVarMeta(metas, cursor, "array")
        local countVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical skip path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "skipArrayPackedByteCount")
            local packedNext = nextTemp(state, "skipArrayPackedNext")
            addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
            addLine(lines, depth, ("local %s = %s + %s"):format(packedNext, varVar, packedByteCount))
            addLine(lines, depth, ("if %s > %s then"):format(packedNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(varVar, packedNext))
        else
            local indexVar = nextTemp(state, "skipArrayIndex")
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
            emitSkipForType(lines, state, valueType, label .. "[]", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
            addLine(lines, depth, "end")
        end
        return
    end

    if kind == "map" then
        local meta = consumeDecodeVarMeta(metas, cursor, "map")
        local countVar = meta.valueVar
        local keyType = (typeDef.key :: any) :: Ast.Type?
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if keyType == nil or valueType == nil then
            error("Map type missing key/value type for canonical skip path")
        end
        local indexVar = nextTemp(state, "skipMapIndex")
        addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
        emitSkipForType(lines, state, keyType, label .. " key", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        emitSkipForType(lines, state, valueType, label .. " value", payloadVar, payloadLengthVar, varVar, depth + 1, validateLevel, structByName)
        addLine(lines, depth, "end")
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitSkipCanonicalDataForType(
                lines,
                state,
                metas,
                cursor,
                field.type,
                label .. "." .. field.name,
                payloadVar,
                payloadLengthVar,
                fixedVar,
                varVar,
                depth,
                validateLevel,
                structByName
            )
        end
        return
    end

    error(("Unsupported canonical serialized type '%s' in skip data path"):format(kind))
end

local function emitPassthroughValidator(
    lines: { string },
    functionName: string,
    params: { Ast.Param },
    validateLevel: Analyzer.ValidateLevel
)
    local args: { string } = { "passCount" }
    for index = 1, #params do
        args[#args + 1] = ("pass%d"):format(index)
    end

    addLine(lines, 0, ("local function %s(%s)"):format(functionName, join(args)))
    if validateLevel == "Off" then
        addLine(lines, 1, "return true")
        addLine(lines, 0, "end")
        addLine(lines, 0, "")
        return
    end
    addLine(lines, 1, ("if passCount ~= %d then"):format(#params))
    addLine(lines, 2, "return false")
    addLine(lines, 1, "end")

    for index = 1, #params do
        local passVar = ("pass%d"):format(index)
        local typeName = getPassthroughTypeName(params[index])
        addLine(lines, 1, ("if %s == nil then"):format(passVar))
        addLine(lines, 2, "return false")
        addLine(lines, 1, "end")

        if typeName ~= "any" then
            local typeVar = ("passType_%d"):format(index)
            addLine(lines, 1, ("local %s = typeof(%s)"):format(typeVar, passVar))
            addLine(lines, 1, ("if %s ~= %q then"):format(typeVar, typeName))
            addLine(lines, 2, ("if %s ~= \"Instance\" or not %s:IsA(%q) then"):format(typeVar, passVar, typeName))
            addLine(lines, 3, "return false")
            addLine(lines, 2, "end")
            addLine(lines, 1, "end")
        end
    end

    addLine(lines, 1, "return true")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitWriteParamsWithFixedBlocks(
    lines: { string },
    state: EmitState,
    params: { Ast.Param },
    valueExprs: { string },
    bufferVar: string,
    offsetVar: string,
    depth: number,
    structByName: { [string]: Ast.Struct },
    stringLenHints: { [string]: string }?
)
    local writeIndex = 1
    while writeIndex <= #params do
        local blockStartIndex = writeIndex
        local blockBytes = 0
        while writeIndex <= #params do
            local fieldBytes = fixedBytesForType(params[writeIndex].type)
            if fieldBytes == nil then
                break
            end
            blockBytes += fieldBytes
            writeIndex += 1
        end

        if blockBytes > 0 then
            local blockBase = nextTemp(state, "fixedWriteBase")
            addLine(lines, depth, ("local %s = %s"):format(blockBase, offsetVar))
            local blockOffset = 0
            for paramIndex = blockStartIndex, writeIndex - 1 do
                emitWriteFixedToBlock(
                    lines,
                    params[paramIndex].type,
                    valueExprs[paramIndex],
                    bufferVar,
                    blockBase,
                    blockOffset,
                    depth
                )
                local fieldBytes = fixedBytesForType(params[paramIndex].type)
                if fieldBytes == nil then
                    error("Internal fixed write block mismatch")
                end
                blockOffset += fieldBytes
            end
            if writeIndex <= #params then
                addLine(lines, depth, ("%s = %s + %d"):format(offsetVar, blockBase, blockBytes))
            end
        end

        if writeIndex <= #params then
            emitWriteForType(
                lines,
                state,
                params[writeIndex].type,
                valueExprs[writeIndex],
                bufferVar,
                offsetVar,
                depth,
                structByName,
                stringLenHints
            )
            writeIndex += 1
        end
    end
end

local function canEmitFlatSizeType(
    typeDef: Ast.Type,
    structByName: { [string]: Ast.Struct },
    seenStructs: { [string]: boolean }
): boolean
    local kind = normalizeTypeKind(typeDef.kind)
    if PRIMITIVE_BYTES[kind] ~= nil or kind == "bool" or kind == "string" then
        return true
    end
    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if seenStructs[kind] then
            return false
        end
        seenStructs[kind] = true
        for fieldIndex = 1, #structDecl.fields do
            if not canEmitFlatSizeType(structDecl.fields[fieldIndex].type, structByName, seenStructs) then
                seenStructs[kind] = nil
                return false
            end
        end
        seenStructs[kind] = nil
        return true
    end
    return false
end

local function canEmitFlatTopLevelSize(params: { Ast.Param }, structByName: { [string]: Ast.Struct }): boolean
    local seenStructs: { [string]: boolean } = {}
    for index = 1, #params do
        if not canEmitFlatSizeType(params[index].type, structByName, seenStructs) then
            return false
        end
    end
    return true
end

local function emitFlatSizeForType(
    lines: { string },
    state: EmitState,
    typeDef: Ast.Type,
    valueExpr: string,
    label: string,
    terms: { string },
    validateLevel: Analyzer.ValidateLevel,
    stringLenHints: { [string]: string },
    structByName: { [string]: Ast.Struct }
)
    local kind = normalizeTypeKind(typeDef.kind)
    local primitiveBytes = PRIMITIVE_BYTES[kind]
    if primitiveBytes ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, 1, ("if type(%s) ~= \"number\" then"):format(valueExpr))
            emitError(lines, 2, validateLevel, label .. " must be number", "ERR_TYPE")
            addLine(lines, 1, "end")
            local range = INTEGER_RANGES[kind]
            if range ~= nil then
                addLine(lines, 1, ("if %s %% 1 ~= 0 then"):format(valueExpr))
                emitError(lines, 2, validateLevel, label .. " must be an integer", "ERR_SCHEMA")
                addLine(lines, 1, "end")
                addLine(lines, 1, ("if %s < %s or %s > %s then"):format(valueExpr, tostring(range.min), valueExpr, tostring(range.max)))
                emitError(lines, 2, validateLevel, label .. " out of range", "ERR_SCHEMA")
                addLine(lines, 1, "end")
            end
        end
        terms[#terms + 1] = tostring(primitiveBytes)
        return
    end

    if kind == "bool" then
        if isValidateFull(validateLevel) then
            addLine(lines, 1, ("if type(%s) ~= \"boolean\" then"):format(valueExpr))
            emitError(lines, 2, validateLevel, label .. " must be boolean", "ERR_TYPE")
            addLine(lines, 1, "end")
        end
        terms[#terms + 1] = "1"
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local declaredMax = prefixInfo.declaredMax
        local lenVar = nextTemp(state, "stringLen")
        addLine(lines, 1, ("local %s = #%s"):format(lenVar, valueExpr))
        stringLenHints[valueExpr] = lenVar
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, 1, ("if %s > %d then"):format(lenVar, declaredMax))
            emitError(lines, 2, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, 1, "end")
        end
        if prefixInfo.isVarint then
            addLine(lines, 1, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
            emitError(lines, 2, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            terms[#terms + 1] = ("VarUIntSize(%s)"):format(lenVar)
        elseif widthInfo ~= nil then
            terms[#terms + 1] = tostring(widthInfo.bytes)
        else
            error("Internal string length prefix mismatch")
        end
        terms[#terms + 1] = lenVar
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        if isValidateFull(validateLevel) then
            addLine(lines, 1, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, 2, validateLevel, label .. " must be struct table", "ERR_TYPE")
            addLine(lines, 1, "end")
        end
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            emitFlatSizeForType(
                lines,
                state,
                field.type,
                fieldAccessExpr(valueExpr, field.name),
                label .. "." .. field.name,
                terms,
                validateLevel,
                stringLenHints,
                structByName
            )
        end
        return
    end

    error(("Unsupported flat top-level type '%s'"):format(kind))
end

local function emitFlatTopLevelSize(
    lines: { string },
    state: EmitState,
    params: { Ast.Param },
    valueExprs: { string },
    labelPrefix: string,
    totalVar: string,
    baseBytes: number,
    validateLevel: Analyzer.ValidateLevel,
    stringLenHints: { [string]: string },
    structByName: { [string]: Ast.Struct }
)
    local terms: { string } = { tostring(baseBytes) }
    for index = 1, #params do
        local param = params[index]
        emitFlatSizeForType(
            lines,
            state,
            param.type,
            valueExprs[index],
            labelPrefix .. "." .. param.name,
            terms,
            validateLevel,
            stringLenHints,
            structByName
        )
    end
    addLine(lines, 1, ("local %s = %s"):format(totalVar, table.concat(terms, " + ")))
end

local function emitCodecFunctions(
    lines: { string },
    encodeName: string,
    decodeName: string,
    messageIdConst: string,
    messageIdWidth: WidthInfo,
    params: { Ast.Param },
    labelPrefix: string,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct },
    includeEncode: boolean,
    includePayloadVersion: boolean,
    decodeStructMode: DecodeStructMode
)
    local usesCanonicalLayout = paramsHaveVariableLength(params, structByName)
    local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(params, structByName) or 0
    local baseBytes = messageIdWidth.bytes + (includePayloadVersion and 1 or 0)

    if includeEncode then
        local encodeArgs = paramNames(params)
        local canUseFlatSize = (not usesCanonicalLayout) and canEmitFlatTopLevelSize(params, structByName)
        addLine(lines, 0, ("local function %s(%s)"):format(encodeName, join(encodeArgs)))
        local sizeState: EmitState = { tempIndex = 0 }
        local stringLenHints: { [string]: string } = {}

        if usesCanonicalLayout then
            addLine(lines, 1, "local prefixSize = 0")
            addLine(lines, 1, "local varSize = 0")
            for index = 1, #params do
                local param = params[index]
                emitCanonicalSizeForType(
                    lines,
                    sizeState,
                    param.type,
                    encodeArgs[index],
                    labelPrefix .. "." .. param.name,
                    "prefixSize",
                    "varSize",
                    1,
                    validateLevel,
                    structByName,
                    stringLenHints
                )
            end
            if canonicalFixedSize == 0 then
                addLine(lines, 1, ("local totalSize = %d + prefixSize + varSize"):format(baseBytes))
            else
                addLine(lines, 1, ("local totalSize = %d + prefixSize + %d + varSize"):format(baseBytes, canonicalFixedSize))
            end
        elseif canUseFlatSize then
            emitFlatTopLevelSize(
                lines,
                sizeState,
                params,
                encodeArgs,
                labelPrefix,
                "totalSize",
                baseBytes,
                validateLevel,
                stringLenHints,
                structByName
            )
        else
            addLine(lines, 1, ("local totalSize = %d"):format(baseBytes))
            for index = 1, #params do
                local param = params[index]
                emitSizeForType(
                    lines,
                    sizeState,
                    param.type,
                    param.name,
                    labelPrefix .. "." .. param.name,
                    "totalSize",
                    1,
                    validateLevel,
                    structByName,
                    stringLenHints
                )
            end
        end

        addLine(lines, 1, "local payload = create(totalSize)")
        if includePayloadVersion then
            addLine(lines, 1, "writeu8(payload, 0, PAYLOAD_VERSION)")
            addLine(lines, 1, ("%s(payload, 1, %s)"):format(messageIdWidth.writer, messageIdConst))
        else
            addLine(lines, 1, ("%s(payload, 0, %s)"):format(messageIdWidth.writer, messageIdConst))
        end

        if usesCanonicalLayout then
            addLine(lines, 1, ("local prefixOffset = %d"):format(baseBytes))
            addLine(lines, 1, "local fixedOffset = prefixOffset + prefixSize")
            if canonicalFixedSize == 0 then
                addLine(lines, 1, "local varOffset = fixedOffset")
            else
                addLine(lines, 1, ("local varOffset = fixedOffset + %d"):format(canonicalFixedSize))
            end
            local writeState: EmitState = { tempIndex = sizeState.tempIndex }
            for index = 1, #params do
                local param = params[index]
                emitWriteCanonicalForType(
                    lines,
                    writeState,
                    param.type,
                    encodeArgs[index],
                    "payload",
                    "prefixOffset",
                    "fixedOffset",
                    "varOffset",
                    1,
                    structByName,
                    stringLenHints
                )
            end
        else
            addLine(lines, 1, ("local offset = %d"):format(baseBytes))
            local writeState: EmitState = { tempIndex = sizeState.tempIndex }
            emitWriteParamsWithFixedBlocks(lines, writeState, params, encodeArgs, "payload", "offset", 1, structByName, stringLenHints)
        end

        addLine(lines, 1, "return payload")
        addLine(lines, 0, "end")
        addLine(lines, 0, "")
    end

    addLine(lines, 0, ("local function %s(payload, payloadLength, offset)"):format(decodeName))

    local decodeState: EmitState = { tempIndex = 0 }
    local decodePlans = buildDecodedParamPlans(params, structByName, decodeStructMode)
    local decodeLeaves: { DecodedLeaf } = {}
    for planIndex = 1, #decodePlans do
        local leaves = decodePlans[planIndex].leaves
        for leafIndex = 1, #leaves do
            decodeLeaves[#decodeLeaves + 1] = leaves[leafIndex]
            addLine(lines, 1, ("local %s"):format(leaves[leafIndex].targetName))
        end
    end
    local decodeVars = collectDecodedLeafNames(decodePlans)

    if usesCanonicalLayout then
        local prefixCursor = nextTemp(decodeState, "prefixCursor")
        addLine(lines, 1, ("local %s = offset"):format(prefixCursor))
        local decodeMetas: { DecodeVarMeta } = {}
        for leafIndex = 1, #decodeLeaves do
            local leaf = decodeLeaves[leafIndex]
            emitDecodeCanonicalPrefixForType(
                lines,
                decodeState,
                decodeMetas,
                leaf.typeDef,
                labelPrefix .. "." .. leaf.labelSuffix,
                "payload",
                "payloadLength",
                prefixCursor,
                1,
                validateLevel,
                structByName
            )
        end
        local fixedCursor = nextTemp(decodeState, "fixedCursor")
        local varCursor = nextTemp(decodeState, "varCursor")
        addLine(lines, 1, ("local %s = %s"):format(fixedCursor, prefixCursor))
        if canonicalFixedSize == 0 then
            addLine(lines, 1, ("local %s = %s"):format(varCursor, fixedCursor))
        else
            addLine(lines, 1, ("local %s = %s + %d"):format(varCursor, fixedCursor, canonicalFixedSize))
        end
        addLine(lines, 1, ("if %s > payloadLength then"):format(varCursor))
        emitError(lines, 2, validateLevel, labelPrefix .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, 1, "end")
        local metaCursor: DecodeVarCursor = { index = 1 }
        for leafIndex = 1, #decodeLeaves do
            local leaf = decodeLeaves[leafIndex]
            emitDecodeCanonicalDataForType(
                lines,
                decodeState,
                decodeMetas,
                metaCursor,
                leaf.typeDef,
                leaf.targetName,
                labelPrefix .. "." .. leaf.labelSuffix,
                "payload",
                "payloadLength",
                fixedCursor,
                varCursor,
                1,
                validateLevel,
                structByName
            )
        end
        addLine(lines, 1, ("offset = %s"):format(varCursor))
    else
        local decodeIndex = 1
        while decodeIndex <= #decodeLeaves do
            local blockStartIndex = decodeIndex
            local blockBytes = 0
            while decodeIndex <= #decodeLeaves do
                local fieldBytes = fixedBytesForType(decodeLeaves[decodeIndex].typeDef)
                if fieldBytes == nil then
                    break
                end
                blockBytes += fieldBytes
                decodeIndex += 1
            end

            if blockBytes > 0 then
                local blockVar = nextTemp(decodeState, "fixedBlock")
                local blockNext = nextTemp(decodeState, "fixedBlockNext")
                emitReserveInline(
                    lines,
                    1,
                    "offset",
                    "payloadLength",
                    tostring(blockBytes),
                    blockVar,
                    blockNext,
                    validateLevel,
                    labelPrefix
                )
                local blockOffset = 0
                for paramIndex = blockStartIndex, decodeIndex - 1 do
                    local param = decodeLeaves[paramIndex]
                    emitReadFixedFromBlock(
                        lines,
                        decodeState,
                        param.typeDef,
                        param.targetName,
                        labelPrefix .. "." .. param.labelSuffix,
                        "payload",
                        blockVar,
                        blockOffset,
                        1,
                        validateLevel
                    )
                    local fieldBytes = fixedBytesForType(param.typeDef)
                    if fieldBytes == nil then
                        error("Internal decode fixed block mismatch")
                    end
                    blockOffset += fieldBytes
                end
            end

            if decodeIndex <= #decodeLeaves then
                local param = decodeLeaves[decodeIndex]
                emitReadForType(
                    lines,
                    decodeState,
                    param.typeDef,
                    param.targetName,
                    labelPrefix .. "." .. param.labelSuffix,
                    "payload",
                    "payloadLength",
                    "offset",
                    1,
                    validateLevel,
                    structByName
                )
                decodeIndex += 1
            end
        end
    end

    if #decodeVars == 0 then
        addLine(lines, 1, "return offset")
    else
        addLine(lines, 1, ("return %s, offset"):format(join(decodeVars)))
    end
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitSkipFunction(
    lines: { string },
    skipName: string,
    params: { Ast.Param },
    labelPrefix: string,
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
)
    local usesCanonicalLayout = paramsHaveVariableLength(params, structByName)
    local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(params, structByName) or 0

    addLine(lines, 0, ("local function %s(payload, payloadLength, offset)"):format(skipName))

    local skipState: EmitState = { tempIndex = 0 }
    if usesCanonicalLayout then
        local prefixCursor = nextTemp(skipState, "prefixCursor")
        addLine(lines, 1, ("local %s = offset"):format(prefixCursor))
        local decodeMetas: { DecodeVarMeta } = {}
        for index = 1, #params do
            local param = params[index]
            emitDecodeCanonicalPrefixForType(
                lines,
                skipState,
                decodeMetas,
                param.type,
                labelPrefix .. "." .. param.name,
                "payload",
                "payloadLength",
                prefixCursor,
                1,
                validateLevel,
                structByName
            )
        end
        local fixedCursor = nextTemp(skipState, "fixedCursor")
        local varCursor = nextTemp(skipState, "varCursor")
        addLine(lines, 1, ("local %s = %s"):format(fixedCursor, prefixCursor))
        if canonicalFixedSize == 0 then
            addLine(lines, 1, ("local %s = %s"):format(varCursor, fixedCursor))
        else
            addLine(lines, 1, ("local %s = %s + %d"):format(varCursor, fixedCursor, canonicalFixedSize))
        end
        addLine(lines, 1, ("if %s > payloadLength then"):format(varCursor))
        emitError(lines, 2, validateLevel, labelPrefix .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, 1, "end")
        local metaCursor: DecodeVarCursor = { index = 1 }
        for index = 1, #params do
            local param = params[index]
            emitSkipCanonicalDataForType(
                lines,
                skipState,
                decodeMetas,
                metaCursor,
                param.type,
                labelPrefix .. "." .. param.name,
                "payload",
                "payloadLength",
                fixedCursor,
                varCursor,
                1,
                validateLevel,
                structByName
            )
        end
        addLine(lines, 1, ("offset = %s"):format(varCursor))
    else
        for index = 1, #params do
            local param = params[index]
            emitSkipForType(
                lines,
                skipState,
                param.type,
                labelPrefix .. "." .. param.name,
                "payload",
                "payloadLength",
                "offset",
                1,
                validateLevel,
                structByName
            )
        end
    end
    addLine(lines, 1, "return offset")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitQueue(
    lines: { string },
    prefix: string,
    remoteVar: string,
    fireMethod: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    _validateLevel: Analyzer.ValidateLevel
)
    local upper = string.upper(prefix)
    addLine(lines, 0, ("local %s_ARENA_CAPACITY = DEFAULT_ARENA_CAPACITY"):format(upper))
    addLine(lines, 0, ("local %s_ARENA = create(%s_ARENA_CAPACITY)"):format(upper, upper))
    addLine(lines, 0, ("local %s_CURSOR = 0"):format(upper))
    addLine(lines, 0, ("local %s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 0, ("local %s_DROPPED = 0"):format(upper))
    if maxPassArgs > 0 then
        addLine(lines, 0, ("local %s_QUEUE_PASS_COUNT = table.create(DEFAULT_BATCH_CAPACITY, 0)"):format(upper))
        for passIndex = 1, maxPassArgs do
            addLine(lines, 0, ("local %s_QUEUE_PASS_%d = table.create(DEFAULT_BATCH_CAPACITY)"):format(upper, passIndex))
        end
    end
    addLine(lines, 0, "")

    addLine(lines, 0, ("local function Flush%s()"):format(prefix))
    addLine(lines, 1, ("if %s_CURSOR == 0 then"):format(upper))
    addLine(lines, 2, ("%s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("local payloadToSend = create(1 + %s_CURSOR)"):format(upper))
    addLine(lines, 1, "writeu8(payloadToSend, 0, PAYLOAD_VERSION)")
    addLine(lines, 1, "local sourceOffset = 0")
    addLine(lines, 1, "local payloadOffset = 1")
    addLine(lines, 1, ("while sourceOffset < %s_CURSOR do"):format(upper))
    addLine(lines, 2, "local runStart = sourceOffset")
    addLine(lines, 2, ("local messageId = %s(%s_ARENA, sourceOffset)"):format(messageIdWidth.reader, upper))
    addLine(lines, 2, ("sourceOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 2, ("local skip = %s_SKIP[messageId]"):format(upper))
    addLine(lines, 2, ("local firstBodyEnd = skip(%s_ARENA, %s_CURSOR, sourceOffset)"):format(upper, upper))
    addLine(lines, 2, "local runEnd = firstBodyEnd")
    addLine(lines, 2, "local runCount = 1")
    addLine(lines, 2, ("while runEnd < %s_CURSOR do"):format(upper))
    addLine(lines, 3, ("local nextMessageId = %s(%s_ARENA, runEnd)"):format(messageIdWidth.reader, upper))
    addLine(lines, 3, "if nextMessageId ~= messageId then")
    addLine(lines, 4, "break")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("local nextBodyStart = runEnd + %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("runEnd = skip(%s_ARENA, %s_CURSOR, nextBodyStart)"):format(upper, upper))
    addLine(lines, 3, "runCount += 1")
    addLine(lines, 2, "end")
    addLine(lines, 2, ("if runCount * %d > %d + VarUIntSize(runCount) then"):format(messageIdWidth.bytes, messageIdWidth.bytes * 2))
    addLine(lines, 3, ("%s(payloadToSend, payloadOffset, SEGMENT_MARKER_ID)"):format(messageIdWidth.writer))
    addLine(lines, 3, ("payloadOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("%s(payloadToSend, payloadOffset, messageId)"):format(messageIdWidth.writer))
    addLine(lines, 3, ("payloadOffset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, "payloadOffset = WriteVarUInt(payloadToSend, payloadOffset, runCount)")
    addLine(lines, 3, "local copyCursor = sourceOffset")
    addLine(lines, 3, "local bodyEnd = firstBodyEnd")
    addLine(lines, 3, "while true do")
    addLine(lines, 4, "local bodySize = bodyEnd - copyCursor")
    addLine(lines, 4, "if bodySize > 0 then")
    addLine(lines, 5, ("copy(payloadToSend, payloadOffset, %s_ARENA, copyCursor, bodySize)"):format(upper))
    addLine(lines, 5, "payloadOffset += bodySize")
    addLine(lines, 4, "end")
    addLine(lines, 4, "if bodyEnd >= runEnd then")
    addLine(lines, 5, "break")
    addLine(lines, 4, "end")
    addLine(lines, 4, ("copyCursor = bodyEnd + %d"):format(messageIdWidth.bytes))
    addLine(lines, 4, ("bodyEnd = skip(%s_ARENA, %s_CURSOR, copyCursor)"):format(upper, upper))
    addLine(lines, 3, "end")
    addLine(lines, 2, "else")
    addLine(lines, 3, "local runSize = runEnd - runStart")
    addLine(lines, 3, "if runSize > 0 then")
    addLine(lines, 4, ("copy(payloadToSend, payloadOffset, %s_ARENA, runStart, runSize)"):format(upper))
    addLine(lines, 4, "payloadOffset += runSize")
    addLine(lines, 3, "end")
    addLine(lines, 2, "end")
    addLine(lines, 2, "sourceOffset = runEnd")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("if payloadOffset < 1 + %s_CURSOR then"):format(upper))
    addLine(lines, 2, "local compactPayload = create(payloadOffset)")
    addLine(lines, 2, "copy(compactPayload, 0, payloadToSend, 0, payloadOffset)")
    addLine(lines, 2, "payloadToSend = compactPayload")
    addLine(lines, 1, "end")

    if maxPassArgs == 0 then
        addLine(lines, 1, ("%s:%s(payloadToSend)"):format(remoteVar, fireMethod))
    else
        addLine(lines, 1, ("local messageCount = %s_QUEUE_SIZE"):format(upper))
        addLine(lines, 1, "local passCountList = table.create(messageCount, 0)")
        addLine(lines, 1, "for index = 1, messageCount do")
        addLine(lines, 2, ("passCountList[index] = %s_QUEUE_PASS_COUNT[index]"):format(upper))
        addLine(lines, 2, ("%s_QUEUE_PASS_COUNT[index] = 0"):format(upper))
        addLine(lines, 1, "end")

        local passValueLists: { string } = {}
        for passIndex = 1, maxPassArgs do
            local passListName = ("passList_%d"):format(passIndex)
            passValueLists[#passValueLists + 1] = passListName
            addLine(lines, 1, ("local %s = table.create(messageCount)"):format(passListName))
            addLine(lines, 1, "for index = 1, messageCount do")
            addLine(lines, 2, ("%s[index] = %s_QUEUE_PASS_%d[index]"):format(passListName, upper, passIndex))
            addLine(lines, 2, ("%s_QUEUE_PASS_%d[index] = nil"):format(upper, passIndex))
            addLine(lines, 1, "end")
        end

        local callArgs: { string } = { "payloadToSend", "passCountList" }
        for passIndex = 1, #passValueLists do
            callArgs[#callArgs + 1] = passValueLists[passIndex]
        end
        addLine(lines, 1, ("%s:%s(%s)"):format(remoteVar, fireMethod, join(callArgs)))
    end

    addLine(lines, 1, ("%s_CURSOR = 0"):format(upper))
    addLine(lines, 1, ("%s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitEventListener(
    lines: { string },
    isServer: boolean,
    prefix: string,
    remoteVar: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    local upper = string.upper(prefix)
    if isServer then
        if maxPassArgs > 0 then
            addLine(lines, 0, ("%s.OnServerEvent:Connect(function(player, payload, passCountList, ...)"):format(remoteVar))
        else
            addLine(lines, 0, ("%s.OnServerEvent:Connect(function(player, payload)"):format(remoteVar))
        end
    else
        if maxPassArgs > 0 then
            addLine(lines, 0, ("%s.OnClientEvent:Connect(function(payload, passCountList, ...)"):format(remoteVar))
        else
            addLine(lines, 0, ("%s.OnClientEvent:Connect(function(payload)"):format(remoteVar))
        end
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, ("if payloadLength < %d then"):format(1 + messageIdWidth.bytes))
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if readu8(payload, 0) ~= PAYLOAD_VERSION then")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        local passTables: { string } = {}
        for passIndex = 1, maxPassArgs do
            passTables[#passTables + 1] = ("passTable%d"):format(passIndex)
        end
        addLine(lines, 1, ("local %s = ..."):format(join(passTables)))
    end
    addLine(lines, 1, "local offset = 1")
    if maxPassArgs > 0 then
        addLine(lines, 1, "local messageIndex = 0")
    end
    addLine(lines, 1, "while offset < payloadLength do")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 2, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
        addLine(lines, 3, "return")
        addLine(lines, 2, "end")
    end
    addLine(lines, 2, ("local messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 2, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 2, "local segmentCount = 1")
    addLine(lines, 2, "local dispatch")
    addLine(lines, 2, "if messageId == SEGMENT_MARKER_ID then")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 3, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
    else
        addLine(lines, 3, "if offset >= payloadLength then")
    end
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 3, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, "segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)")
    addLine(lines, 3, "if segmentCount < 1 then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "else")
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "end")
    addLine(lines, 2, "for _segmentIndex = 1, segmentCount do")
    if maxPassArgs > 0 then
        addLine(lines, 3, "messageIndex += 1")
        addLine(lines, 3, "local passCount = 0")
        addLine(lines, 3, "if type(passCountList) == \"table\" then")
        addLine(lines, 4, "local rawPassCount = passCountList[messageIndex]")
        addLine(lines, 4, "if type(rawPassCount) == \"number\" then")
        addLine(lines, 5, "passCount = rawPassCount")
        addLine(lines, 4, "end")
        addLine(lines, 3, "end")
        for passIndex = 1, maxPassArgs do
            addLine(lines, 3, ("local messagePass%d = nil"):format(passIndex))
            addLine(lines, 3, ("if type(passTable%d) == \"table\" then"):format(passIndex))
            addLine(lines, 4, ("messagePass%d = passTable%d[messageIndex]"):format(passIndex, passIndex))
            addLine(lines, 3, "end")
        end
    end

    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    callArgs[#callArgs + 1] = "offset"
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("messagePass%d"):format(passIndex)
    end
    addLine(lines, 3, ("local nextOffset = dispatch(%s)"):format(join(callArgs)))
    if maxPassArgs > 0 or isValidateFull(validateLevel) then
        addLine(lines, 3, "if type(nextOffset) ~= \"number\" then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
        addLine(lines, 3, "if nextOffset < offset or nextOffset > payloadLength then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
    end
    addLine(lines, 3, "offset = nextOffset")
    addLine(lines, 2, "end")
    addLine(lines, 1, "end")
    addLine(lines, 0, "end)")
    addLine(lines, 0, "")
end

local function emitFunctionInvoke(
    lines: { string },
    isServer: boolean,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    if isServer then
        addLine(lines, 0, "FunctionRemote.OnServerInvoke = function(player, payload, ...)")
    else
        addLine(lines, 0, "FunctionRemote.OnClientInvoke = function(payload, ...)")
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    emitError(lines, 2, validateLevel, "Function payload must be a buffer", "ERR_TYPE")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, ("if payloadLength < %d then"):format(1 + messageIdWidth.bytes))
    emitError(lines, 2, validateLevel, "Function payload too short", "ERR_BOUNDS")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if readu8(payload, 0) ~= PAYLOAD_VERSION then")
    emitError(lines, 2, validateLevel, "Function payload version mismatch", "ERR_SCHEMA")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("local messageId = %s(payload, 1)"):format(messageIdWidth.reader))
    addLine(lines, 1, "local dispatch = FUNCTION_DISPATCH[messageId]")
    addLine(lines, 1, "if dispatch == nil then")
    emitError(lines, 2, validateLevel, "No function dispatch for message ID", "ERR_SCHEMA")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        addLine(lines, 1, "local passCount = select(\"#\", ...)")
    end
    local passArgs: { string } = {}
    for passIndex = 1, maxPassArgs do
        passArgs[#passArgs + 1] = ("pass%d"):format(passIndex)
    end
    if #passArgs > 0 then
        addLine(lines, 1, ("local %s = ..."):format(join(passArgs)))
    end
    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("pass%d"):format(passIndex)
    end
    addLine(lines, 1, ("return dispatch(%s)"):format(join(callArgs)))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitCommonRuntimePreamble(lines: { string }, schema: Analyzer.AnalyzedSchema, isServer: boolean)
    addLine(lines, 0, "local RunService = game:GetService(\"RunService\")")
    addLine(lines, 0, "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")")
    addLine(lines, 0, "")

    if isServer then
        addLine(lines, 0, "local function FindOrCreateRemote(className, remoteName)")
        addLine(lines, 1, "local existing = ReplicatedStorage:FindFirstChild(remoteName)")
        addLine(lines, 1, "if existing ~= nil then")
        addLine(lines, 2, "if existing.ClassName ~= className then")
        addLine(lines, 3, "error((\"Remote '%s' exists as '%s', expected '%s'\"):format(remoteName, existing.ClassName, className))")
        addLine(lines, 2, "end")
        addLine(lines, 2, "return existing")
        addLine(lines, 1, "end")
        addLine(lines, 1, "local remote = Instance.new(className)")
        addLine(lines, 1, "remote.Name = remoteName")
        addLine(lines, 1, "remote.Parent = ReplicatedStorage")
        addLine(lines, 1, "return remote")
        addLine(lines, 0, "end")
        addLine(lines, 0, "")
        addLine(lines, 0, ("local Reliable = FindOrCreateRemote(\"RemoteEvent\", %q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = FindOrCreateRemote(\"UnreliableRemoteEvent\", %q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = FindOrCreateRemote(\"RemoteFunction\", %q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    else
        addLine(lines, 0, ("local Reliable = ReplicatedStorage:WaitForChild(%q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = ReplicatedStorage:WaitForChild(%q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = ReplicatedStorage:WaitForChild(%q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    end

    addLine(lines, 0, "")
    addLine(lines, 0, "local function WithCount(...)")
    addLine(lines, 1, "return select(\"#\", ...), ...")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local DEFAULT_BATCH_CAPACITY = 2048")
    addLine(lines, 0, "local DEFAULT_ARENA_CAPACITY = 65536")
    addLine(lines, 0, "local create = buffer.create")
    addLine(lines, 0, "local copy = buffer.copy")
    addLine(lines, 0, "local len = buffer.len")
    addLine(lines, 0, "local writeu8 = buffer.writeu8")
    addLine(lines, 0, "local writei8 = buffer.writei8")
    addLine(lines, 0, "local writeu16 = buffer.writeu16")
    addLine(lines, 0, "local writei16 = buffer.writei16")
    addLine(lines, 0, "local writeu32 = buffer.writeu32")
    addLine(lines, 0, "local writei32 = buffer.writei32")
    addLine(lines, 0, "local writef32 = buffer.writef32")
    addLine(lines, 0, "local writef64 = buffer.writef64")
    addLine(lines, 0, "local writestring = buffer.writestring")
    addLine(lines, 0, "local readu8 = buffer.readu8")
    addLine(lines, 0, "local readi8 = buffer.readi8")
    addLine(lines, 0, "local readu16 = buffer.readu16")
    addLine(lines, 0, "local readi16 = buffer.readi16")
    addLine(lines, 0, "local readu32 = buffer.readu32")
    addLine(lines, 0, "local readi32 = buffer.readi32")
    addLine(lines, 0, "local readf32 = buffer.readf32")
    addLine(lines, 0, "local readf64 = buffer.readf64")
    addLine(lines, 0, "local readstring = buffer.readstring")
    addLine(lines, 0, "local band = bit32.band")
    addLine(lines, 0, "local bor = bit32.bor")
    addLine(lines, 0, "local rshift = bit32.rshift")
    addLine(lines, 0, "local lshift = bit32.lshift")
    addLine(lines, 0, "")
end

local function generateRuntime(schema: Analyzer.AnalyzedSchema, isServer: boolean): string
    local validateLevel = schema.validateLevel
    local decodeStructMode = resolveDecodeStruct(schema.options)
    local messages: { MessageInfo } = {}
    local symbolByMessage: { [Analyzer.AnalyzedMessage]: string } = {}
    collectMessages(schema.root, schema.root.name, messages, symbolByMessage)
    local lines: { string } = {
        "--!strict",
        "--!native",
        "--!optimize 2",
        "--!nolint LocalShadow",
        "--#selene: allow(shadowing)",
        isServer and "-- Name: Server" or "-- Name: Client",
        isServer and "-- Purpose: Generated runtime for server networking" or "-- Purpose: Generated runtime for client networking",
        "-- Generated-by: NetRay-Compiler",
        "",
    }

    addLine(lines, 0, "local Types = require(script.Parent.Types)")
    addLine(lines, 0, "type u8 = typeof(Types.u8)")
    addLine(lines, 0, "type i8 = typeof(Types.i8)")
    addLine(lines, 0, "type u16 = typeof(Types.u16)")
    addLine(lines, 0, "type i16 = typeof(Types.i16)")
    addLine(lines, 0, "type u32 = typeof(Types.u32)")
    addLine(lines, 0, "type i32 = typeof(Types.i32)")
    addLine(lines, 0, "type f32 = typeof(Types.f32)")
    addLine(lines, 0, "type f64 = typeof(Types.f64)")
    addLine(lines, 0, ("type NetRoot = typeof(Types.%s)"):format(isServer and "NetServer" or "NetClient"))
    addLine(lines, 0, "type NetStats = typeof(Types.NetStats)")
    addLine(lines, 0, "type Connection = typeof(Types.Connection)")
    for structIndex = 1, #schema.structs do
        local structName = schema.structs[structIndex].name
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(structName, structName))
    end
    for messageIndex = 1, #messages do
        local messageInfo = messages[messageIndex]
        local message = messageInfo.message
        local apiTypeName = isServer and messageServerApiTypeName(messageInfo.apiBase) or messageClientApiTypeName(messageInfo.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(messageInfo.apiBase, message.category)
            or messageClientCallbackTypeName(messageInfo.apiBase, message.category)
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(apiTypeName, apiTypeName))
        addLine(lines, 0, ("type %s = typeof(Types.%s)"):format(callbackTypeName, callbackTypeName))
    end
    addLine(lines, 0, "")

    emitCommonRuntimePreamble(lines, schema, isServer)

    addLine(lines, 0, "local ERR_BOUNDS = \"E_BOUNDS\"")
    addLine(lines, 0, "local ERR_SCHEMA = \"E_SCHEMA\"")
    addLine(lines, 0, "local ERR_TAG = \"E_TAG\"")
    addLine(lines, 0, "local ERR_TYPE = \"E_TYPE\"")
    addLine(lines, 0, "local ERR_PASS = \"E_PASS\"")
    addLine(lines, 0, "local PAYLOAD_VERSION = 1")
    addLine(lines, 0, "local SEGMENT_MARKER_ID = 0")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function VarUIntSize(value)")
    addLine(lines, 1, "if value < 128 then return 1 end")
    addLine(lines, 1, "if value < 16384 then return 2 end")
    addLine(lines, 1, "if value < 2097152 then return 3 end")
    addLine(lines, 1, "if value < 268435456 then return 4 end")
    addLine(lines, 1, "return 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function WriteVarUInt(payload, offset, value)")
    addLine(lines, 1, "if value < 128 then")
    addLine(lines, 2, "writeu8(payload, offset, value)")
    addLine(lines, 2, "return offset + 1")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 16384 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, band(rshift(value, 7), 127))")
    addLine(lines, 2, "return offset + 2")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 2097152 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, band(rshift(value, 14), 127))")
    addLine(lines, 2, "return offset + 3")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 268435456 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 3, band(rshift(value, 21), 127))")
    addLine(lines, 2, "return offset + 4")
    addLine(lines, 1, "end")
    addLine(lines, 1, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 3, bor(band(rshift(value, 21), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 4, band(rshift(value, 28), 15))")
    addLine(lines, 1, "return offset + 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function ReadVarUInt(payload, payloadLength, offset)")
    addLine(lines, 1, "local next1 = offset + 1")
    addLine(lines, 1, "if next1 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b1 = readu8(payload, offset)")
    addLine(lines, 1, "if b1 < 128 then return b1, next1 end")
    addLine(lines, 1, "local next2 = next1 + 1")
    addLine(lines, 1, "if next2 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b2 = readu8(payload, next1)")
    addLine(lines, 1, "local value = band(b1, 127) + lshift(band(b2, 127), 7)")
    addLine(lines, 1, "if b2 < 128 then return value, next2 end")
    addLine(lines, 1, "local next3 = next2 + 1")
    addLine(lines, 1, "if next3 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b3 = readu8(payload, next2)")
    addLine(lines, 1, "value += lshift(band(b3, 127), 14)")
    addLine(lines, 1, "if b3 < 128 then return value, next3 end")
    addLine(lines, 1, "local next4 = next3 + 1")
    addLine(lines, 1, "if next4 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b4 = readu8(payload, next3)")
    addLine(lines, 1, "value += lshift(band(b4, 127), 21)")
    addLine(lines, 1, "if b4 < 128 then return value, next4 end")
    addLine(lines, 1, "local next5 = next4 + 1")
    addLine(lines, 1, "if next5 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b5 = readu8(payload, next4)")
    addLine(lines, 1, "if b5 >= 16 then error(ERR_SCHEMA) end")
    addLine(lines, 1, "value += lshift(b5, 28)")
    addLine(lines, 1, "return value, next5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function CreateConnection(disconnectFn: () -> ()): Connection")
    addLine(lines, 1, "local active = true")
    addLine(lines, 1, "local connection = {} :: any")
    addLine(lines, 1, "connection.Connected = true")
    addLine(lines, 1, "function connection:Disconnect()")
    addLine(lines, 2, "if not active then")
    addLine(lines, 3, "return")
    addLine(lines, 2, "end")
    addLine(lines, 2, "active = false")
    addLine(lines, 2, "connection.Connected = false")
    addLine(lines, 2, "disconnectFn()")
    addLine(lines, 1, "end")
    addLine(lines, 1, "return connection :: Connection")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    local maxReliableId = 0
    local maxUnreliableId = 0
    local maxFunctionId = 0
    for index = 1, #messages do
        local info = messages[index]
        local category = info.message.category
        if category == "reliable" then
            if info.message.id > maxReliableId then
                maxReliableId = info.message.id
            end
        elseif category == "unreliable" then
            if info.message.id > maxUnreliableId then
                maxUnreliableId = info.message.id
            end
        elseif category == "function" then
            if info.message.id > maxFunctionId then
                maxFunctionId = info.message.id
            end
        end
    end

    local reliableMessageIdWidth = getMessageIdWidthInfo(maxReliableId)
    local unreliableMessageIdWidth = getMessageIdWidthInfo(maxUnreliableId)
    local functionMessageIdWidth = getMessageIdWidthInfo(maxFunctionId)

    addLine(lines, 0, ("local MAX_RELIABLE_ID = %d"):format(maxReliableId))
    addLine(lines, 0, ("local MAX_UNRELIABLE_ID = %d"):format(maxUnreliableId))
    addLine(lines, 0, ("local MAX_FUNCTION_ID = %d"):format(maxFunctionId))
    addLine(lines, 0, "local RELIABLE_DISPATCH = table.create(MAX_RELIABLE_ID)")
    addLine(lines, 0, "local UNRELIABLE_DISPATCH = table.create(MAX_UNRELIABLE_ID)")
    addLine(lines, 0, "local RELIABLE_SKIP = table.create(MAX_RELIABLE_ID)")
    addLine(lines, 0, "local UNRELIABLE_SKIP = table.create(MAX_UNRELIABLE_ID)")
    addLine(lines, 0, "local FUNCTION_DISPATCH = table.create(MAX_FUNCTION_ID)")
    addLine(lines, 0, "")

    emitQueue(
        lines,
        "Reliable",
        "Reliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel
    )
    emitQueue(
        lines,
        "Unreliable",
        "Unreliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )

    for index = 1, #messages do
        local info = messages[index]
        local symbol = info.symbol
        local message = info.message
        local messageIdWidth: WidthInfo
        if message.category == "reliable" then
            messageIdWidth = reliableMessageIdWidth
        elseif message.category == "unreliable" then
            messageIdWidth = unreliableMessageIdWidth
        else
            messageIdWidth = functionMessageIdWidth
        end
        local requestNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughParams > 0
        local returnNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughReturns > 0
        local messageIdConst = "MESSAGE_ID_" .. symbol
        local encodeRequestName = "Encode_" .. symbol
        local decodeRequestName = "Decode_" .. symbol
        local requestPassValidator = "ValidatePass_" .. symbol
        local handlerName = "Handler_" .. symbol
        local handlerTokenName = "HandlerToken_" .. symbol
        local responsePassValidator = "ValidateReturnPass_" .. symbol
        local encodeResponseName = "EncodeReturn_" .. symbol
        local decodeResponseName = "DecodeReturn_" .. symbol
        local apiTypeName = isServer and messageServerApiTypeName(info.apiBase) or messageClientApiTypeName(info.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(info.apiBase, message.category)
            or messageClientCallbackTypeName(info.apiBase, message.category)
        local requestDecodePlans = buildDecodedParamPlans(info.serializedParams, schema.structByName, decodeStructMode)
        local requestDecodedVars = collectDecodedLeafNames(requestDecodePlans)

        addLine(lines, 0, ("local %s: %s = {} :: %s"):format(symbol, apiTypeName, apiTypeName))
        addLine(lines, 0, ("local %s = %d"):format(messageIdConst, message.id))
        addLine(lines, 0, "")

        if requestNeedsPassValidation then
            emitPassthroughValidator(lines, requestPassValidator, info.passthroughParams, validateLevel)
        end
        emitCodecFunctions(
            lines,
            encodeRequestName,
            decodeRequestName,
            messageIdConst,
            messageIdWidth,
            info.serializedParams,
            info.fullName,
            validateLevel,
            schema.structByName,
            message.category == "function",
            message.category == "function",
            decodeStructMode
        )

        if message.category == "function" then
            if returnNeedsPassValidation then
                emitPassthroughValidator(lines, responsePassValidator, info.passthroughReturns, validateLevel)
            end
            emitCodecFunctions(
                lines,
                encodeResponseName,
                decodeResponseName,
                messageIdConst,
                messageIdWidth,
                info.serializedReturns,
                info.fullName .. " return",
                validateLevel,
                schema.structByName,
                true,
                true,
                "Table"
            )
        end

        local handlerReturnParams: { Ast.Param } = {}
        if message.category == "function" then
            handlerReturnParams = message.returns or {}
        end
        local handlerParams = expandDecodeParams(message.params, schema.structByName, decodeStructMode)
        local handlerType = callbackTypeExpr(handlerParams, isServer, handlerReturnParams)
        addLine(lines, 0, ("local %s: (%s)? = nil"):format(handlerName, handlerType))
        addLine(lines, 0, ("local %s = 0"):format(handlerTokenName))
        addLine(lines, 0, "")

        if message.category == "reliable" or message.category == "unreliable" then
            local methodName = isServer and "FireAll" or "Fire"
            local allParamSignature = typedParamList(message.params)
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local queueUpper = message.category == "unreliable" and "UNRELIABLE" or "RELIABLE"
            local categoryMaxPass = schema.maxPassArgs[message.category]
            local eventCallbackType = callbackTypeName
            local usesCanonicalLayout = paramsHaveVariableLength(info.serializedParams, schema.structByName)
            local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(info.serializedParams, schema.structByName) or 0
            local canUseFlatSize = (not usesCanonicalLayout) and canEmitFlatTopLevelSize(info.serializedParams, schema.structByName)
            local canEmitFire = canSendEvent(message.from, isServer)
            local canEmitOn = canReceiveEvent(message.from, isServer)
            local skipName = "Skip_" .. symbol

            if canEmitFire then
                emitSkipFunction(lines, skipName, info.serializedParams, info.fullName, validateLevel, schema.structByName)
                local skipDispatchVar = message.category == "unreliable" and "UNRELIABLE_SKIP" or "RELIABLE_SKIP"
                addLine(lines, 0, ("%s[%d] = %s"):format(skipDispatchVar, message.id, skipName))
                addLine(lines, 0, "")
            end

            if canEmitFire then
                addLine(lines, 0, ("function %s.%s(%s): boolean"):format(symbol, methodName, allParamSignature))
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                local fireSizeState: EmitState = { tempIndex = 0 }
                local fireStringLenHints: { [string]: string } = {}
                if usesCanonicalLayout then
                    addLine(lines, 1, "local __nr_prefixSize = 0")
                    addLine(lines, 1, "local __nr_varSize = 0")
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitCanonicalSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_prefixSize",
                            "__nr_varSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, ("local __nr_totalSize = %d + __nr_prefixSize + __nr_varSize"):format(messageIdWidth.bytes))
                    else
                        addLine(
                            lines,
                            1,
                            ("local __nr_totalSize = %d + __nr_prefixSize + %d + __nr_varSize"):format(
                                messageIdWidth.bytes,
                                canonicalFixedSize
                            )
                        )
                    end
                elseif canUseFlatSize then
                    emitFlatTopLevelSize(
                        lines,
                        fireSizeState,
                        info.serializedParams,
                        serializedNames,
                        info.fullName,
                        "__nr_totalSize",
                        messageIdWidth.bytes,
                        validateLevel,
                        fireStringLenHints,
                        schema.structByName
                    )
                else
                    addLine(lines, 1, ("local __nr_totalSize = %d"):format(messageIdWidth.bytes))
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_totalSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                end

                addLine(lines, 1, ("local __nr_base = %s_CURSOR"):format(queueUpper))
                addLine(lines, 1, "local __nr_required = __nr_base + __nr_totalSize")
                addLine(lines, 1, ("if __nr_required > %s_ARENA_CAPACITY then"):format(queueUpper))
                addLine(lines, 2, ("local nextCapacity = %s_ARENA_CAPACITY"):format(queueUpper))
                addLine(lines, 2, "while nextCapacity < __nr_required do")
                addLine(lines, 3, "nextCapacity *= 2")
                addLine(lines, 2, "end")
                addLine(lines, 2, "local nextArena = create(nextCapacity)")
                addLine(lines, 2, ("if %s_CURSOR > 0 then"):format(queueUpper))
                addLine(lines, 3, ("copy(nextArena, 0, %s_ARENA, 0, %s_CURSOR)"):format(queueUpper, queueUpper))
                addLine(lines, 2, "end")
                addLine(lines, 2, ("%s_ARENA = nextArena"):format(queueUpper))
                addLine(lines, 2, ("%s_ARENA_CAPACITY = nextCapacity"):format(queueUpper))
                addLine(lines, 1, "end")

                addLine(lines, 1, ("%s_CURSOR = __nr_required"):format(queueUpper))
                addLine(lines, 1, ("local __nr_payload = %s_ARENA"):format(queueUpper))
                addLine(lines, 1, ("%s(__nr_payload, __nr_base, %s)"):format(messageIdWidth.writer, messageIdConst))
                local fireWriteState: EmitState = { tempIndex = fireSizeState.tempIndex }
                if usesCanonicalLayout then
                    addLine(lines, 1, ("local __nr_prefix = __nr_base + %d"):format(messageIdWidth.bytes))
                    addLine(lines, 1, "local __nr_fixed = __nr_prefix + __nr_prefixSize")
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, "local __nr_var = __nr_fixed")
                    else
                        addLine(lines, 1, ("local __nr_var = __nr_fixed + %d"):format(canonicalFixedSize))
                    end
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitWriteCanonicalForType(
                            lines,
                            fireWriteState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            "__nr_payload",
                            "__nr_prefix",
                            "__nr_fixed",
                            "__nr_var",
                            1,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                else
                    addLine(lines, 1, ("local __nr_p = __nr_base + %d"):format(messageIdWidth.bytes))
                    emitWriteParamsWithFixedBlocks(
                        lines,
                        fireWriteState,
                        info.serializedParams,
                        serializedNames,
                        "__nr_payload",
                        "__nr_p",
                        1,
                        schema.structByName,
                        fireStringLenHints
                    )
                end
                addLine(lines, 1, ("%s_QUEUE_SIZE += 1"):format(queueUpper))
                if categoryMaxPass > 0 then
                    addLine(lines, 1, ("local __nr_slot = %s_QUEUE_SIZE"):format(queueUpper))
                    addLine(lines, 1, ("%s_QUEUE_PASS_COUNT[__nr_slot] = %d"):format(queueUpper, #info.passthroughParams))
                    for passIndex = 1, categoryMaxPass do
                        local passValueExpr = passIndex <= #passthroughNames and passthroughNames[passIndex] or "nil"
                        addLine(lines, 1, ("%s_QUEUE_PASS_%d[__nr_slot] = %s"):format(queueUpper, passIndex, passValueExpr))
                    end
                end
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end

            if canEmitOn then
                addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, eventCallbackType))
                addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
                addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
                addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
                addLine(lines, 1, ("%s = callback"):format(handlerName))
                addLine(lines, 1, "return CreateConnection(function()")
                addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
                addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
                addLine(lines, 3, ("%s = nil"):format(handlerName))
                addLine(lines, 2, "end")
                addLine(lines, 1, "end)")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")

            local dispatchVar = message.category == "unreliable" and "UNRELIABLE_DISPATCH" or "RELIABLE_DISPATCH"
            local signatureArgs: { string } = {}
            if isServer then
                signatureArgs[#signatureArgs + 1] = "player"
            end
            signatureArgs[#signatureArgs + 1] = "payload"
            signatureArgs[#signatureArgs + 1] = "payloadLength"
            signatureArgs[#signatureArgs + 1] = "offset"
            if categoryMaxPass > 0 then
                signatureArgs[#signatureArgs + 1] = "passCount"
            end
            for passIndex = 1, categoryMaxPass do
                signatureArgs[#signatureArgs + 1] = ("pass%d"):format(passIndex)
            end

            addLine(lines, 0, ("%s[%d] = function(%s)"):format(dispatchVar, message.id, join(signatureArgs)))
            if requestNeedsPassValidation then
                local passVarsForValidation: { string } = { "passCount" }
                for passIndex = 1, #info.passthroughParams do
                    passVarsForValidation[#passVarsForValidation + 1] = ("pass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(passVarsForValidation)))
                addLine(lines, 2, "return payloadLength")
                addLine(lines, 1, "end")
            end

            local decodeResultVars: { string } = {}
            for idxVar = 1, #requestDecodedVars do
                decodeResultVars[#decodeResultVars + 1] = requestDecodedVars[idxVar]
            end
            decodeResultVars[#decodeResultVars + 1] = "nextOffset"
            addLine(lines, 1, ("local %s = %s(payload, payloadLength, offset)"):format(join(decodeResultVars), decodeRequestName))
            addLine(lines, 1, ("local callback = %s"):format(handlerName))
            addLine(lines, 1, "if callback == nil then")
            addLine(lines, 2, "return nextOffset")
            addLine(lines, 1, "end")

            local callbackArgs: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
            end
            local serializedIndex = 0
            local passthroughIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    passthroughIndex += 1
                    callbackArgs[#callbackArgs + 1] = ("pass%d"):format(passthroughIndex)
                else
                    serializedIndex += 1
                    local leafNames = requestDecodePlans[serializedIndex].leafNames
                    for leafIndex = 1, #leafNames do
                        callbackArgs[#callbackArgs + 1] = leafNames[leafIndex]
                    end
                end
            end
            addLine(lines, 1, ("callback(%s)"):format(join(callbackArgs)))
            addLine(lines, 1, "return nextOffset")
            addLine(lines, 0, "end")
            addLine(lines, 0, "")
            end
        elseif message.category == "function" then
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local allReturnNames = paramNames(message.returns or {})
            local passthroughReturnNames = paramNames(info.passthroughReturns)
            local functionCallbackType = callbackTypeName
            local functionReturnType = returnTypeExpr(message.returns or {})

            addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, functionCallbackType))
            addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
            addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
            addLine(lines, 1, ("%s = callback"):format(handlerName))
            addLine(lines, 1, "return CreateConnection(function()")
            addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
            addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 3, ("%s = nil"):format(handlerName))
            addLine(lines, 2, "end")
            addLine(lines, 1, "end)")
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local callSignature: { string } = {}
            if isServer then
                callSignature[#callSignature + 1] = "player: Player"
            end
            for indexParam = 1, #message.params do
                local param = message.params[indexParam]
                callSignature[#callSignature + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
            end
            addLine(lines, 0, ("function %s.Call(%s): %s"):format(symbol, join(callSignature), functionReturnType))
            if isServer then
                addLine(lines, 1, "if typeof(player) ~= \"Instance\" or not player:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " server call requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
            end
            if requestNeedsPassValidation then
                addLine(
                    lines,
                    1,
                    ("if not %s(%d%s%s) then"):format(
                        requestPassValidator,
                        #info.passthroughParams,
                        #passthroughNames > 0 and ", " or "",
                        join(passthroughNames)
                    )
                )
                emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, ("local requestPayload = %s(%s)"):format(encodeRequestName, join(serializedNames)))

            local responseCaptureVars: { string } = { "responseCount", "responsePayload" }
            for passIndex = 1, #passthroughReturnNames do
                responseCaptureVars[#responseCaptureVars + 1] = ("responsePass%d"):format(passIndex)
            end

            local invokeArgs: { string } = {}
            if isServer then
                invokeArgs[#invokeArgs + 1] = "player"
            end
            invokeArgs[#invokeArgs + 1] = "requestPayload"
            for passIndex = 1, #passthroughNames do
                invokeArgs[#invokeArgs + 1] = passthroughNames[passIndex]
            end

            if isServer then
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeClient(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            else
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeServer(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            end
            addLine(lines, 1, "if responseCount < 1 then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response missing payload", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            if #passthroughReturnNames > 0 then
                addLine(lines, 1, "local responsePassCount = responseCount - 1")
            end

            if returnNeedsPassValidation then
                local passValidationArgs: { string } = { "responsePassCount" }
                for passIndex = 1, #passthroughReturnNames do
                    passValidationArgs[#passValidationArgs + 1] = ("responsePass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(responsePassValidator, join(passValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " return passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, "if typeof(responsePayload) ~= \"buffer\" then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload must be buffer", "ERR_TYPE")
            addLine(lines, 1, "end")
            addLine(lines, 1, "local responseLength = len(responsePayload)")
            addLine(lines, 1, ("if responseLength < %d then"):format(1 + messageIdWidth.bytes))
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload too short", "ERR_BOUNDS")
            addLine(lines, 1, "end")
            addLine(lines, 1, "if readu8(responsePayload, 0) ~= PAYLOAD_VERSION then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response version mismatch", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local responseId = %s(responsePayload, 1)"):format(messageIdWidth.reader))
            addLine(lines, 1, ("if responseId ~= %s then"):format(messageIdConst))
            emitError(lines, 2, validateLevel, info.fullName .. " function response message ID mismatch", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local decodedReturnVars: { string } = {}
            for indexReturn = 1, #info.serializedReturns do
                decodedReturnVars[#decodedReturnVars + 1] = ("decoded_%s"):format(sanitizeIdentifier(info.serializedReturns[indexReturn].name))
            end
            local decodeReturnCapture: { string } = {}
            for indexVar = 1, #decodedReturnVars do
                decodeReturnCapture[#decodeReturnCapture + 1] = decodedReturnVars[indexVar]
            end
            decodeReturnCapture[#decodeReturnCapture + 1] = "responseOffset"
            addLine(
                lines,
                1,
                ("local %s = %s(responsePayload, responseLength, %d)"):format(
                    join(decodeReturnCapture),
                    decodeResponseName,
                    1 + messageIdWidth.bytes
                )
            )
            addLine(lines, 1, "if responseOffset ~= responseLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            if #allReturnNames > 0 then
                local returnArgs: { string } = {}
                local serialIndex = 0
                local passIndex = 0
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        passIndex += 1
                        returnArgs[#returnArgs + 1] = ("responsePass%d"):format(passIndex)
                    else
                        serialIndex += 1
                        returnArgs[#returnArgs + 1] = decodedReturnVars[serialIndex]
                    end
                end
                addLine(lines, 1, ("return %s"):format(join(returnArgs)))
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local signatureArgs: { string } = {}
            if isServer then
                signatureArgs[#signatureArgs + 1] = "player"
            end
            signatureArgs[#signatureArgs + 1] = "payload"
            signatureArgs[#signatureArgs + 1] = "payloadLength"
            if schema.maxPassArgs.Function > 0 then
                signatureArgs[#signatureArgs + 1] = "passCount"
            end
            for passIndex = 1, schema.maxPassArgs.Function do
                signatureArgs[#signatureArgs + 1] = ("pass%d"):format(passIndex)
            end
            addLine(lines, 0, ("FUNCTION_DISPATCH[%d] = function(%s)"):format(message.id, join(signatureArgs)))
            if requestNeedsPassValidation then
                local inboundPassValidationArgs: { string } = { "passCount" }
                for passIndex = 1, #passthroughNames do
                    inboundPassValidationArgs[#inboundPassValidationArgs + 1] = ("pass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(inboundPassValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " inbound passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end

            local inboundDecodeCapture: { string } = {}
            for indexVar = 1, #requestDecodedVars do
                inboundDecodeCapture[#inboundDecodeCapture + 1] = requestDecodedVars[indexVar]
            end
            inboundDecodeCapture[#inboundDecodeCapture + 1] = "offset"
            addLine(
                lines,
                1,
                ("local %s = %s(payload, payloadLength, %d)"):format(join(inboundDecodeCapture), decodeRequestName, 1 + messageIdWidth.bytes)
            )
            addLine(lines, 1, "if offset ~= payloadLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function payload has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local callback = %s"):format(handlerName))
            addLine(lines, 1, "if callback == nil then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function has no handler", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local callbackArgs: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
            end
            local callbackSerialIndex = 0
            local callbackPassIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    callbackPassIndex += 1
                    callbackArgs[#callbackArgs + 1] = ("pass%d"):format(callbackPassIndex)
                else
                    callbackSerialIndex += 1
                    local leafNames = requestDecodePlans[callbackSerialIndex].leafNames
                    for leafIndex = 1, #leafNames do
                        callbackArgs[#callbackArgs + 1] = leafNames[leafIndex]
                    end
                end
            end

            if #allReturnNames > 0 then
                local callbackResultVars: { string } = {}
                for returnIndex = 1, #allReturnNames do
                    callbackResultVars[#callbackResultVars + 1] = ("callbackRet_%d"):format(returnIndex)
                end
                addLine(lines, 1, ("local %s = callback(%s)"):format(join(callbackResultVars), join(callbackArgs)))

                local responseSerializedArgs: { string } = {}
                local responsePassthroughArgs: { string } = {}
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        responsePassthroughArgs[#responsePassthroughArgs + 1] = callbackResultVars[returnIndex]
                    else
                        responseSerializedArgs[#responseSerializedArgs + 1] = callbackResultVars[returnIndex]
                    end
                end

                if returnNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            responsePassValidator,
                            #responsePassthroughArgs,
                            #responsePassthroughArgs > 0 and ", " or "",
                            join(responsePassthroughArgs)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " handler returned invalid passthrough", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local responsePayload = %s(%s)"):format(encodeResponseName, join(responseSerializedArgs)))
                if #responsePassthroughArgs > 0 then
                    local returnPayload: { string } = { "responsePayload" }
                    for passIndex = 1, #responsePassthroughArgs do
                        returnPayload[#returnPayload + 1] = responsePassthroughArgs[passIndex]
                    end
                    addLine(lines, 1, ("return %s"):format(join(returnPayload)))
                else
                    addLine(lines, 1, "return responsePayload")
                end
            else
                addLine(lines, 1, ("callback(%s)"):format(join(callbackArgs)))
                addLine(lines, 1, ("local responsePayload = %s()"):format(encodeResponseName))
                addLine(lines, 1, "return responsePayload")
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")
        else
            error(("Unsupported message category '%s' for message '%s'"):format(message.category, info.fullName))
        end
    end

    addLine(lines, 0, "local function StepReplication()")
    addLine(lines, 1, "FlushReliable()")
    addLine(lines, 1, "FlushUnreliable()")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "RunService.Heartbeat:Connect(StepReplication)")
    addLine(lines, 0, "")

    emitEventListener(
        lines,
        isServer,
        "Reliable",
        "Reliable",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel
    )
    emitEventListener(
        lines,
        isServer,
        "Unreliable",
        "Unreliable",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )
    emitFunctionInvoke(lines, isServer, schema.maxPassArgs.Function, functionMessageIdWidth, validateLevel)

    addLine(lines, 0, "local Stats: NetStats = {")
    addLine(lines, 1, "GetReliableDropped = function() return RELIABLE_DROPPED end,")
    addLine(lines, 1, "GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,")
    addLine(lines, 1, "GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE end,")
    addLine(lines, 1, "GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    local scopeLines = buildScopeTables(schema.root, 0, true, symbolByMessage)
    appendLines(lines, scopeLines)
    addLine(lines, 0, "")
    addLine(lines, 0, "Net.StepReplication = StepReplication")
    addLine(lines, 0, "Net.Stats = Stats")
    addLine(lines, 0, "local NetTyped: NetRoot = Net")
    addLine(lines, 0, "")
    addLine(lines, 0, "return table.freeze(NetTyped)")

    return concat(lines)
end

local function generateServer(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, true)
end

local function generateClient(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, false)
end

local function emitTupleBoundsComment(lines: { string }, label: string, params: { Ast.Param })
    local bounds: { string } = {}
    for index = 1, #params do
        local param = params[index]
        local boundComment = getStringBoundComment(param.type)
        if boundComment ~= nil then
            bounds[#bounds + 1] = ("%s=%s"):format(param.name, boundComment)
        end
    end
    if #bounds > 0 then
        addLine(lines, 0, ("-- %s bounds: %s"):format(label, join(bounds)))
    end
end

local function emitStructType(lines: { string }, structDef: Ast.Struct, typeName: string)
    addLine(lines, 0, ("export type %s = {"):format(typeName))
    for fieldIndex = 1, #structDef.fields do
        local field = structDef.fields[fieldIndex]
        local fieldLine = ("%s: %s,"):format(field.name, toLuauType(field.type))
        local boundComment = getStringBoundComment(field.type)
        if boundComment ~= nil then
            fieldLine ..= (" -- %s"):format(boundComment)
        end
        addLine(lines, 1, fieldLine)
    end
    addLine(lines, 0, "}")
    addLine(lines, 0, "")
end

local function buildScopeTypeTable(
    scope: Analyzer.AnalyzedScope,
    depth: number,
    isRoot: boolean,
    isServer: boolean,
    infoByMessage: { [Analyzer.AnalyzedMessage]: MessageInfo }
): { string }
    local lines: { string } = {}
    if isRoot then
        lines[#lines + 1] = ("export type %s = {"):format(isServer and "NetServer" or "NetClient")
    else
        lines[#lines + 1] = scope.name .. ": {"
    end

    for index = 1, #scope.messages do
        local msg = scope.messages[index]
        local info = infoByMessage[msg]
        if info ~= nil then
            local apiTypeName = isServer and messageServerApiTypeName(info.apiBase) or messageClientApiTypeName(info.apiBase)
            lines[#lines + 1] = ("%s: %s,"):format(msg.name, apiTypeName)
        end
    end

    for index = 1, #scope.scopes do
        local child = scope.scopes[index]
        local childLines = buildScopeTypeTable(child, depth + 1, false, isServer, infoByMessage)
        for lineIndex = 1, #childLines do
            if lineIndex == #childLines then
                lines[#lines + 1] = childLines[lineIndex] .. ","
            else
                lines[#lines + 1] = childLines[lineIndex]
            end
        end
    end

    if isRoot then
        lines[#lines + 1] = "StepReplication: () -> (),"
        lines[#lines + 1] = "Stats: NetStats,"
    end
    lines[#lines + 1] = "}"
    return indent(lines, depth)
end

local function generateTypes(schema: Analyzer.AnalyzedSchema): string
    local typeBranding = resolveTypeBranding(schema.options)
    local decodeStructMode = resolveDecodeStruct(schema.options)
    local lines: { string } = {
        "--!strict",
        "--!native",
        "--!optimize 2",
        "-- Name: Types",
        "-- Purpose: Generated Luau types for NetRay schema",
        "-- Generated-by: NetRay-Compiler",
        "",
    }

    local messages: { MessageInfo } = {}
    local symbolByMessage: { [Analyzer.AnalyzedMessage]: string } = {}
    local infoByMessage: { [Analyzer.AnalyzedMessage]: MessageInfo } = {}
    collectMessages(schema.root, schema.root.name, messages, symbolByMessage)
    for index = 1, #messages do
        local info = messages[index]
        infoByMessage[info.message] = info
    end

    addLine(lines, 0, "export type TypeBranding = \"Off\" | \"On\"")
    addLine(lines, 0, ("export type ActiveTypeBranding = %q"):format(typeBranding))
    addLine(lines, 0, "export type Brand<T, B> = T & { __brand: B }")
    if typeBranding == "On" then
        addLine(lines, 0, "export type u8 = Brand<number, \"u8\">")
        addLine(lines, 0, "export type i8 = Brand<number, \"i8\">")
        addLine(lines, 0, "export type u16 = Brand<number, \"u16\">")
        addLine(lines, 0, "export type i16 = Brand<number, \"i16\">")
        addLine(lines, 0, "export type u32 = Brand<number, \"u32\">")
        addLine(lines, 0, "export type i32 = Brand<number, \"i32\">")
        addLine(lines, 0, "export type f32 = Brand<number, \"f32\">")
        addLine(lines, 0, "export type f64 = Brand<number, \"f64\">")
    else
        addLine(lines, 0, "export type u8 = number")
        addLine(lines, 0, "export type i8 = number")
        addLine(lines, 0, "export type u16 = number")
        addLine(lines, 0, "export type i16 = number")
        addLine(lines, 0, "export type u32 = number")
        addLine(lines, 0, "export type i32 = number")
        addLine(lines, 0, "export type f32 = number")
        addLine(lines, 0, "export type f64 = number")
    end
    addLine(lines, 0, "")

    addLine(lines, 0, "export type Connection = {")
    addLine(lines, 1, "Connected: boolean,")
    addLine(lines, 1, "Disconnect: (self: Connection) -> (),")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    addLine(lines, 0, "export type EventSender1<T> = {")
    addLine(lines, 1, "Fire: (T) -> boolean,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "export type EventReceiver1<T> = {")
    addLine(lines, 1, "On: ((T) -> ()) -> Connection,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "export type EventDuplex1<T> = EventSender1<T> & EventReceiver1<T>")
    addLine(lines, 0, "")

    addLine(lines, 0, "export type NetStats = {")
    addLine(lines, 1, "GetReliableDropped: () -> number,")
    addLine(lines, 1, "GetUnreliableDropped: () -> number,")
    addLine(lines, 1, "GetReliableQueueSize: () -> number,")
    addLine(lines, 1, "GetUnreliableQueueSize: () -> number,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    for index = 1, #schema.structs do
        local structDef = schema.structs[index]
        emitStructType(lines, structDef, structDef.name)
    end

    for index = 1, #messages do
        local info = messages[index]
        local message = info.message
        local baseName = info.apiBase
        local returns = message.returns or {}
        local clientCallbackTypeName = messageClientCallbackTypeName(baseName, message.category)
        local serverCallbackTypeName = messageServerCallbackTypeName(baseName, message.category)
        local clientApiTypeName = messageClientApiTypeName(baseName)
        local serverApiTypeName = messageServerApiTypeName(baseName)
        local callbackParams = expandDecodeParams(message.params, schema.structByName, decodeStructMode)

        if message.category == "function" then
            local requestTupleTypeName = baseName .. "_RequestTuple"
            local responseTupleTypeName = baseName .. "_ResponseTuple"
            local clientCallTypeName = baseName .. "_ClientCall"
            local serverCallTypeName = baseName .. "_ServerCall"
            local clientHandlerTypeName = baseName .. "_ClientHandler"
            local serverHandlerTypeName = baseName .. "_ServerHandler"

            emitTupleBoundsComment(lines, info.fullName .. " request", message.params)
            addLine(lines, 0, ("export type %s = %s"):format(requestTupleTypeName, tupleTypeExpr(message.params)))
            emitTupleBoundsComment(lines, info.fullName .. " response", returns)
            addLine(lines, 0, ("export type %s = %s"):format(responseTupleTypeName, tupleTypeExpr(returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallTypeName, callbackSignatureTypeExpr(message.params, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallTypeName, callbackSignatureTypeExpr(message.params, true, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientHandlerTypeName, callbackSignatureTypeExpr(callbackParams, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverHandlerTypeName, callbackSignatureTypeExpr(callbackParams, true, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallbackTypeName, callbackTypeExpr(callbackParams, false, returns)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallbackTypeName, callbackTypeExpr(callbackParams, true, returns)))

            addLine(lines, 0, ("export type %s = {"):format(clientApiTypeName))
            addLine(lines, 1, ("On: (%s) -> Connection,"):format(clientCallbackTypeName))
            addLine(lines, 1, ("Call: %s,"):format(clientCallTypeName))
            addLine(lines, 0, "}")
            addLine(lines, 0, ("export type %s = {"):format(serverApiTypeName))
            addLine(lines, 1, ("On: (%s) -> Connection,"):format(serverCallbackTypeName))
            addLine(lines, 1, ("Call: %s,"):format(serverCallTypeName))
            addLine(lines, 0, "}")
        else
            local argsTypeName = baseName .. "_Args"
            local tupleHandlerTypeName = baseName .. "_TupleHandler"
            local clientCanSend = canSendEvent(message.from, false)
            local clientCanReceive = canReceiveEvent(message.from, false)
            local serverCanSend = canSendEvent(message.from, true)
            local serverCanReceive = canReceiveEvent(message.from, true)
            local sendSinglePayloadType: string? = nil
            local receiveSinglePayloadType: string? = nil
            if #message.params == 1 then
                sendSinglePayloadType = toLuauType(message.params[1].type)
            end
            if #callbackParams == 1 then
                receiveSinglePayloadType = toLuauType(callbackParams[1].type)
            end

            emitTupleBoundsComment(lines, info.fullName .. " args", message.params)
            addLine(lines, 0, ("export type %s = %s"):format(argsTypeName, tupleTypeExpr(message.params)))
            addLine(lines, 0, ("export type %s = %s"):format(tupleHandlerTypeName, callbackSignatureTypeExpr(callbackParams, false, EMPTY_PARAMS)))
            addLine(lines, 0, ("export type %s = %s"):format(clientCallbackTypeName, callbackTypeExpr(callbackParams, false, EMPTY_PARAMS)))
            addLine(lines, 0, ("export type %s = %s"):format(serverCallbackTypeName, callbackTypeExpr(callbackParams, true, EMPTY_PARAMS)))

            if sendSinglePayloadType ~= nil
                and receiveSinglePayloadType ~= nil
                and sendSinglePayloadType == receiveSinglePayloadType
                and clientCanSend
                and clientCanReceive
            then
                addLine(lines, 0, ("export type %s = EventDuplex1<%s>"):format(clientApiTypeName, sendSinglePayloadType))
            elseif sendSinglePayloadType ~= nil and clientCanSend and not clientCanReceive then
                addLine(lines, 0, ("export type %s = EventSender1<%s>"):format(clientApiTypeName, sendSinglePayloadType))
            elseif receiveSinglePayloadType ~= nil and not clientCanSend and clientCanReceive then
                addLine(lines, 0, ("export type %s = EventReceiver1<%s>"):format(clientApiTypeName, receiveSinglePayloadType))
            else
                addLine(lines, 0, ("export type %s = {"):format(clientApiTypeName))
                if clientCanSend then
                    addLine(lines, 1, ("Fire: %s,"):format(callableTypeExpr(message.params, false, "boolean")))
                end
                if clientCanReceive then
                    addLine(lines, 1, ("On: (%s) -> Connection,"):format(clientCallbackTypeName))
                end
                addLine(lines, 0, "}")
            end

            addLine(lines, 0, ("export type %s = {"):format(serverApiTypeName))
            if serverCanSend then
                addLine(lines, 1, ("FireAll: %s,"):format(callableTypeExpr(message.params, false, "boolean")))
            end
            if serverCanReceive then
                addLine(lines, 1, ("On: (%s) -> Connection,"):format(serverCallbackTypeName))
            end
            addLine(lines, 0, "}")
        end
        addLine(lines, 0, "")
    end

    local clientScopeTypeLines = buildScopeTypeTable(schema.root, 0, true, false, infoByMessage)
    appendLines(lines, clientScopeTypeLines)
    addLine(lines, 0, "")
    local serverScopeTypeLines = buildScopeTypeTable(schema.root, 0, true, true, infoByMessage)
    appendLines(lines, serverScopeTypeLines)
    addLine(lines, 0, "")
    addLine(lines, 0, "export type Net = NetClient | NetServer")
    addLine(lines, 0, "")

    addLine(lines, 0, "local Types = {")
    addLine(lines, 1, "u8 = (0 :: any) :: u8,")
    addLine(lines, 1, "i8 = (0 :: any) :: i8,")
    addLine(lines, 1, "u16 = (0 :: any) :: u16,")
    addLine(lines, 1, "i16 = (0 :: any) :: i16,")
    addLine(lines, 1, "u32 = (0 :: any) :: u32,")
    addLine(lines, 1, "i32 = (0 :: any) :: i32,")
    addLine(lines, 1, "f32 = (0 :: any) :: f32,")
    addLine(lines, 1, "f64 = (0 :: any) :: f64,")
    addLine(lines, 1, "Connection = ({ Connected = true, Disconnect = function(_self) end } :: any) :: Connection,")
    addLine(
        lines,
        1,
        "NetStats = ({ GetReliableDropped = function() return 0 end, GetUnreliableDropped = function() return 0 end, GetReliableQueueSize = function() return 0 end, GetUnreliableQueueSize = function() return 0 end } :: any) :: NetStats,"
    )
    for structIndex = 1, #schema.structs do
        local structName = schema.structs[structIndex].name
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(structName, structName))
    end
    for messageIndex = 1, #messages do
        local messageInfo = messages[messageIndex]
        local message = messageInfo.message
        local clientCallbackTypeName = messageClientCallbackTypeName(messageInfo.apiBase, message.category)
        local serverCallbackTypeName = messageServerCallbackTypeName(messageInfo.apiBase, message.category)
        local clientApiTypeName = messageClientApiTypeName(messageInfo.apiBase)
        local serverApiTypeName = messageServerApiTypeName(messageInfo.apiBase)
        addLine(lines, 1, ("%s = ((function(...) end) :: any) :: %s,"):format(clientCallbackTypeName, clientCallbackTypeName))
        addLine(lines, 1, ("%s = ((function(...) end) :: any) :: %s,"):format(serverCallbackTypeName, serverCallbackTypeName))
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(clientApiTypeName, clientApiTypeName))
        addLine(lines, 1, ("%s = ({} :: any) :: %s,"):format(serverApiTypeName, serverApiTypeName))
    end
    addLine(lines, 1, "NetClient = ({} :: any) :: NetClient,")
    addLine(lines, 1, "NetServer = ({} :: any) :: NetServer,")
    addLine(lines, 1, "Net = ({} :: any) :: Net,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")
    addLine(lines, 0, "return table.freeze(Types)")
    addLine(lines, 0, "")

    return concat(lines)
end

local function generate(schema: Analyzer.AnalyzedSchema)
    return {
        server = generateServer(schema),
        client = generateClient(schema),
        types = generateTypes(schema),
    }
end

return {
    generate = generate,
}
