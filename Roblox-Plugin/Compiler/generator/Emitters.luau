--!strict
-- Name: Emitters
-- Purpose: All serialization/deserialization emit functions

local Ast = require(script.Parent.Parent.idl.Ast)
local Analyzer = require(script.Parent.Parent.idl.Analyzer)
local Types = require(script.Parent.Types)
local Utilities = require(script.Parent.Utilities)

type EmitState = Types.EmitState
type WidthInfo = Types.WidthInfo
type LengthPrefixInfo = Types.LengthPrefixInfo
type DecodeStructMode = Types.DecodeStructMode
type DecodedLeaf = Types.DecodedLeaf
type DecodedParamPlan = Types.DecodedParamPlan
type DecodeVarMeta = Types.DecodeVarMeta
type DecodeVarCursor = Types.DecodeVarCursor

local PRIMITIVE_BYTES = Types.PRIMITIVE_BYTES
local PRIMITIVE_WRITERS = Types.PRIMITIVE_WRITERS
local PRIMITIVE_READERS = Types.PRIMITIVE_READERS
local INTEGER_RANGES = Types.INTEGER_RANGES
local MAX_VARINT_LENGTH = Types.MAX_VARINT_LENGTH

local normalizeTypeKind = Utilities.normalizeTypeKind
local isNumericKind = Utilities.isNumericKind
local isValidateFull = Utilities.isValidateFull
local isValidateBasicOrFull = Utilities.isValidateBasicOrFull
local emitError = Utilities.emitError
local addLine = Utilities.addLine
local nextTemp = Utilities.nextTemp
local getStringLengthPrefixInfo = Utilities.getStringLengthPrefixInfo
local getArrayLengthPrefixInfo = Utilities.getArrayLengthPrefixInfo
local getFixedArrayLength = Utilities.getFixedArrayLength
local getMapLengthPrefixInfo = Utilities.getMapLengthPrefixInfo
local fieldAccessExpr = Utilities.fieldAccessExpr
local cacheCollectionHint = Utilities.cacheCollectionHint
local getCollectionHint = Utilities.getCollectionHint
local computeFixedByteSize = Utilities.computeFixedByteSize
local fixedBytesForType = Utilities.fixedBytesForType
local canSingleAdvanceSkipForFixedType = Utilities.canSingleAdvanceSkipForFixedType
local offsetExpr = Utilities.offsetExpr
local widthForBound = Utilities.widthForBound
local join = Utilities.join
local paramNames = Utilities.paramNames
local collectDecodedLeafNames = Utilities.collectDecodedLeafNames
local buildDecodedParamPlans = Utilities.buildDecodedParamPlans
local sanitizeIdentifier = Utilities.sanitizeIdentifier
local getPassthroughTypeName = Utilities.getPassthroughTypeName
local toLuauType = Utilities.toLuauType

local DEFAULT_F32_TYPE: Ast.Type = { kind = "f32" }

local function getEnumValues(typeDef: Ast.Type): { string }
    local values = (typeDef.values :: any) :: { string }?
    if values == nil or #values == 0 then
        error("Enum type is missing values")
    end
    return values
end

local function getEnumWidthInfo(typeDef: Ast.Type): WidthInfo
    local values = getEnumValues(typeDef)
    return widthForBound(#values - 1)
end

local function getSetValues(typeDef: Ast.Type): { string }
    local values = (typeDef.values :: any) :: { string }?
    if values == nil or #values == 0 then
        error("Set type is missing values")
    end
    return values
end

local function getSetByteCount(typeDef: Ast.Type): number
    local values = getSetValues(typeDef)
    return ((#values + 7) // 8)
end

local function getVectorComponentType(typeDef: Ast.Type): Ast.Type
    local componentType = (typeDef.value :: any) :: Ast.Type?
    if componentType == nil then
        return DEFAULT_F32_TYPE
    end
    local componentKind = normalizeTypeKind(componentType.kind)
    if not isNumericKind(componentKind) then
        error("Vector component type must be numeric")
    end
    return componentType
end

local function getCFrameComponentTypes(typeDef: Ast.Type): (Ast.Type, Ast.Type)
    local posType = (typeDef.value :: any) :: Ast.Type?
    local rotType = (typeDef.key :: any) :: Ast.Type?
    if posType == nil then
        posType = DEFAULT_F32_TYPE
    end
    if rotType == nil then
        rotType = posType
    end
    if not isNumericKind(normalizeTypeKind(posType.kind)) then
        error("CFrame position component type must be numeric")
    end
    if not isNumericKind(normalizeTypeKind(rotType.kind)) then
        error("CFrame rotation component type must be numeric")
    end
    return posType, rotType
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
        if isValidateBasicOrFull(validateLevel) then
            local minBound = typeDef.min
            local maxBound = typeDef.max
            if minBound ~= nil then
                addLine(lines, depth, ("if %s < %s then"):format(valueExpr, tostring(minBound)))
                emitError(lines, depth + 1, validateLevel, label .. " below minimum", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
            if maxBound ~= nil then
                addLine(lines, depth, ("if %s > %s then"):format(valueExpr, tostring(maxBound)))
                emitError(lines, depth + 1, validateLevel, label .. " above maximum", "ERR_SCHEMA")
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
        local declaredMin = typeDef.min
        local declaredMax = prefixInfo.declaredMax
        local lenVar = nextTemp(state, "stringLen")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"string\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be string", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        cacheCollectionHint(stringLenHints, depth, "string", valueExpr, lenVar)
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(lenVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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

    if kind == "buffer" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local declaredMin = typeDef.min
        local declaredMax = prefixInfo.declaredMax
        local lenVar = nextTemp(state, "bufferLen")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"buffer\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be buffer", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = len(%s)"):format(lenVar, valueExpr))
        cacheCollectionHint(stringLenHints, depth, "buffer", valueExpr, lenVar)
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(lenVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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
            error("Internal buffer length prefix mismatch")
        end
        return
    end

    if kind == "vector" then
        local componentType = getVectorComponentType(typeDef)
        local componentKind = normalizeTypeKind(componentType.kind)
        local componentBytes = PRIMITIVE_BYTES[componentKind]
        if componentBytes == nil then
            error("Vector component width metadata missing")
        end
        local minBound = typeDef.min
        local maxBound = typeDef.max
        local vectorVar = nextTemp(state, "vectorValue")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"Vector3\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be Vector3", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = %s"):format(vectorVar, valueExpr))
        if isValidateBasicOrFull(validateLevel) and (minBound ~= nil or maxBound ~= nil) then
            local magnitudeVar = nextTemp(state, "vectorMagnitude")
            addLine(lines, depth, ("local %s = %s.Magnitude"):format(magnitudeVar, vectorVar))
            if minBound ~= nil then
                addLine(lines, depth, ("if %s < %s then"):format(magnitudeVar, tostring(minBound)))
                emitError(lines, depth + 1, validateLevel, label .. " magnitude below minimum", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
            if maxBound ~= nil then
                addLine(lines, depth, ("if %s > %s then"):format(magnitudeVar, tostring(maxBound)))
                emitError(lines, depth + 1, validateLevel, label .. " magnitude above maximum", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
        end
        addLine(lines, depth, ("%s += %d"):format(sizeVar, componentBytes * 3))
        return
    end

    if kind == "cframe" then
        local posType, rotType = getCFrameComponentTypes(typeDef)
        local posKind = normalizeTypeKind(posType.kind)
        local rotKind = normalizeTypeKind(rotType.kind)
        local posBytes = PRIMITIVE_BYTES[posKind]
        local rotBytes = PRIMITIVE_BYTES[rotKind]
        if posBytes == nil or rotBytes == nil then
            error("CFrame component width metadata missing")
        end
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"CFrame\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be CFrame", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += %d"):format(sizeVar, posBytes * 3 + rotBytes * 3))
        return
    end

    if kind == "brickcolor" then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"BrickColor\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be BrickColor", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += 2"):format(sizeVar))
        return
    end

    if kind == "color3" then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"Color3\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be Color3", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += 3"):format(sizeVar))
        return
    end

    if kind == "datetime" or kind == "datetimemillis" then
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if typeof(%s) ~= \"DateTime\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be DateTime", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += 8"):format(sizeVar))
        return
    end

    if kind == "enum" then
        local values = getEnumValues(typeDef)
        local widthInfo = getEnumWidthInfo(typeDef)
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"string\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be enum string", "ERR_TYPE")
            addLine(lines, depth, "end")
            local matchVar = nextTemp(state, "enumMatch")
            addLine(lines, depth, ("local %s = false"):format(matchVar))
            for valueIndex = 1, #values do
                addLine(lines, depth, ("if %s == %q then %s = true end"):format(valueExpr, values[valueIndex], matchVar))
            end
            addLine(lines, depth, ("if not %s then"):format(matchVar))
            emitError(lines, depth + 1, validateLevel, label .. " invalid enum value", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += %d"):format(sizeVar, widthInfo.bytes))
        return
    end

    if kind == "set" then
        local byteCount = getSetByteCount(typeDef)
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be set table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s += %d"):format(sizeVar, byteCount))
        return
    end

    if kind == "tagged_enum" then
        local tagField = (typeDef.tag :: any) :: string? or "Type"
        local variants = (typeDef.variants :: any) :: { any }?
        if variants == nil or #variants == 0 then
            error("Tagged enum is missing variants")
        end
        local tagWidth = widthForBound(#variants - 1)
        addLine(lines, depth, ("%s += %d"):format(sizeVar, tagWidth.bytes))
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be tagged enum table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        local tagExpr = fieldAccessExpr(valueExpr, tagField)
        for variantIndex = 1, #variants do
            local variant = variants[variantIndex]
            local fields = (variant.fields :: any) :: { Ast.Param }?
            if variantIndex == 1 then
                addLine(lines, depth, ("if %s == %q then"):format(tagExpr, variant.name))
            else
                addLine(lines, depth, ("elseif %s == %q then"):format(tagExpr, variant.name))
            end
            if fields ~= nil then
                for fieldIndex = 1, #fields do
                    local field = fields[fieldIndex]
                    emitSizeForType(
                        lines,
                        state,
                        field.type,
                        fieldAccessExpr(valueExpr, field.name),
                        label .. "." .. field.name,
                        sizeVar,
                        depth + 1,
                        validateLevel,
                        structByName,
                        stringLenHints
                    )
                end
            end
        end
        addLine(lines, depth, "else")
        emitError(lines, depth + 1, validateLevel, label .. " invalid tagged enum variant", "ERR_TAG")
        addLine(lines, depth, "end")
        return
    end

    if kind == "inline_struct" then
        local fields = (typeDef.fields :: any) :: { Ast.Param }?
        if fields == nil then
            error("Inline struct is missing fields")
        end
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be struct table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        for fieldIndex = 1, #fields do
            local field = fields[fieldIndex]
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Array type is missing value type for %s"):format(label))
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
        local declaredMax = if prefixInfo ~= nil then prefixInfo.declaredMax else nil
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local fixedArrayTotalSize: number? = nil
        if isFixedArray and fixedLength ~= nil then
            local seenStructs: { [string]: boolean } = {}
            fixedArrayTotalSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        end
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        local keyVar = nextTemp(state, "arrayKey")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be array table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        cacheCollectionHint(stringLenHints, depth, "array", valueExpr, lenVar)
        if fixedLength ~= nil then
            addLine(lines, depth, ("if %s ~= %d then"):format(lenVar, fixedLength))
            emitError(lines, depth + 1, validateLevel, label .. " has invalid fixedarray length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        elseif isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(lenVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum array length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        elseif isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
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
        if not isFixedArray then
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
                addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
                emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
                addLine(lines, depth, "end")
                addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(sizeVar, lenVar))
            elseif widthInfo ~= nil then
                addLine(lines, depth, ("%s += %d"):format(sizeVar, widthInfo.bytes))
            else
                error("Internal array length prefix mismatch")
            end
        end
        if fixedArrayTotalSize ~= nil then
            -- Entire fixedarray serialized size is compile-time known
            addLine(lines, depth, ("%s += %d"):format(sizeVar, fixedArrayTotalSize))
        elseif valueKind == "bool" then
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
        local declaredMin = typeDef.min
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
        cacheCollectionHint(stringLenHints, depth, "map", valueExpr, mapCount)
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(mapCount, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum map size", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
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
        local cachedLen = getCollectionHint(stringLenHints, depth, "string", valueExpr)
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

    if kind == "buffer" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local widthInfo = prefixInfo.width
        local cachedLen = getCollectionHint(stringLenHints, depth, "buffer", valueExpr)
        local lenExpr: string
        if cachedLen ~= nil then
            lenExpr = cachedLen
        else
            local lenVar = nextTemp(state, "bufferLen")
            addLine(lines, depth, ("local %s = len(%s)"):format(lenVar, valueExpr))
            lenExpr = lenVar
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, lenExpr))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, lenExpr))
            addLine(lines, depth, ("%s += %d"):format(offsetVar, widthInfo.bytes))
        else
            error("Internal buffer length prefix mismatch")
        end
        addLine(lines, depth, ("copy(%s, %s, %s, 0, %s)"):format(bufferVar, offsetVar, valueExpr, lenExpr))
        addLine(lines, depth, ("%s += %s"):format(offsetVar, lenExpr))
        return
    end

    if kind == "vector" then
        local componentType = getVectorComponentType(typeDef)
        local componentKind = normalizeTypeKind(componentType.kind)
        local componentWriter = PRIMITIVE_WRITERS[componentKind]
        local componentBytes = PRIMITIVE_BYTES[componentKind]
        if componentWriter == nil or componentBytes == nil then
            error("Vector component writer metadata missing")
        end
        local vectorVar = nextTemp(state, "vectorValue")
        addLine(lines, depth, ("local %s = %s"):format(vectorVar, valueExpr))
        addLine(lines, depth, ("%s(%s, %s, %s.X)"):format(componentWriter, bufferVar, offsetVar, vectorVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, componentBytes))
        addLine(lines, depth, ("%s(%s, %s, %s.Y)"):format(componentWriter, bufferVar, offsetVar, vectorVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, componentBytes))
        addLine(lines, depth, ("%s(%s, %s, %s.Z)"):format(componentWriter, bufferVar, offsetVar, vectorVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, componentBytes))
        return
    end

    if kind == "cframe" then
        local posType, rotType = getCFrameComponentTypes(typeDef)
        local posKind = normalizeTypeKind(posType.kind)
        local rotKind = normalizeTypeKind(rotType.kind)
        local posWriter = PRIMITIVE_WRITERS[posKind]
        local rotWriter = PRIMITIVE_WRITERS[rotKind]
        local posBytes = PRIMITIVE_BYTES[posKind]
        local rotBytes = PRIMITIVE_BYTES[rotKind]
        if posWriter == nil or rotWriter == nil or posBytes == nil or rotBytes == nil then
            error("CFrame component writer metadata missing")
        end
        local cframeVar = nextTemp(state, "cframeValue")
        local posVar = nextTemp(state, "cframePosition")
        local rxVar = nextTemp(state, "cframeRx")
        local ryVar = nextTemp(state, "cframeRy")
        local rzVar = nextTemp(state, "cframeRz")
        addLine(lines, depth, ("local %s = %s"):format(cframeVar, valueExpr))
        addLine(lines, depth, ("local %s = %s.Position"):format(posVar, cframeVar))
        addLine(lines, depth, ("%s(%s, %s, %s.X)"):format(posWriter, bufferVar, offsetVar, posVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, posBytes))
        addLine(lines, depth, ("%s(%s, %s, %s.Y)"):format(posWriter, bufferVar, offsetVar, posVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, posBytes))
        addLine(lines, depth, ("%s(%s, %s, %s.Z)"):format(posWriter, bufferVar, offsetVar, posVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, posBytes))
        addLine(lines, depth, ("local %s, %s, %s = %s:ToOrientation()"):format(rxVar, ryVar, rzVar, cframeVar))
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(rotWriter, bufferVar, offsetVar, rxVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, rotBytes))
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(rotWriter, bufferVar, offsetVar, ryVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, rotBytes))
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(rotWriter, bufferVar, offsetVar, rzVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, rotBytes))
        return
    end

    if kind == "brickcolor" then
        addLine(lines, depth, ("writeu16(%s, %s, %s.Number)"):format(bufferVar, offsetVar, valueExpr))
        addLine(lines, depth, ("%s += 2"):format(offsetVar))
        return
    end

    if kind == "color3" then
        local colorVar = nextTemp(state, "colorValue")
        addLine(lines, depth, ("local %s = %s"):format(colorVar, valueExpr))
        addLine(lines, depth, ("writeu8(%s, %s, math.floor(%s.R * 255 +0.5))"):format(bufferVar, offsetVar, colorVar))
        addLine(lines, depth, ("%s += 1"):format(offsetVar))
        addLine(lines, depth, ("writeu8(%s, %s, math.floor(%s.G * 255 +0.5))"):format(bufferVar, offsetVar, colorVar))
        addLine(lines, depth, ("%s += 1"):format(offsetVar))
        addLine(lines, depth, ("writeu8(%s, %s, math.floor(%s.B * 255 +0.5))"):format(bufferVar, offsetVar, colorVar))
        addLine(lines, depth, ("%s += 1"):format(offsetVar))
        return
    end

    if kind == "datetime" then
        addLine(lines, depth, ("writef64(%s, %s, %s.UnixTimestamp)"):format(bufferVar, offsetVar, valueExpr))
        addLine(lines, depth, ("%s += 8"):format(offsetVar))
        return
    end

    if kind == "datetimemillis" then
        addLine(lines, depth, ("writef64(%s, %s, %s.UnixTimestampMillis)"):format(bufferVar, offsetVar, valueExpr))
        addLine(lines, depth, ("%s += 8"):format(offsetVar))
        return
    end

    if kind == "enum" then
        local values = getEnumValues(typeDef)
        local widthInfo = getEnumWidthInfo(typeDef)
        local indexVar = nextTemp(state, "enumIndex")
        addLine(lines, depth, ("local %s = -1"):format(indexVar))
        for valueIndex = 1, #values do
            if valueIndex == 1 then
                addLine(lines, depth, ("if %s == %q then"):format(valueExpr, values[valueIndex]))
            else
                addLine(lines, depth, ("elseif %s == %q then"):format(valueExpr, values[valueIndex]))
            end
            addLine(lines, depth + 1, ("%s = %d"):format(indexVar, valueIndex - 1))
        end
        addLine(lines, depth, "else")
        addLine(lines, depth + 1, "error(ERR_TAG)")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, indexVar))
        addLine(lines, depth, ("%s += %d"):format(offsetVar, widthInfo.bytes))
        return
    end

    if kind == "set" then
        local values = getSetValues(typeDef)
        local byteCount = getSetByteCount(typeDef)
        local bitBase = 1
        local valueCursor = 1
        for _ = 1, byteCount do
            local byteVar = nextTemp(state, "setByte")
            addLine(lines, depth, ("local %s = 0"):format(byteVar))
            for _ = 0, 7 do
                if valueCursor > #values then
                    break
                end
                local flagName = values[valueCursor]
                addLine(lines, depth, ("if %s then"):format(fieldAccessExpr(valueExpr, flagName)))
                addLine(lines, depth + 1, ("%s = bor(%s, %d)"):format(byteVar, byteVar, bitBase))
                addLine(lines, depth, "end")
                bitBase *= 2
                valueCursor += 1
            end
            bitBase = 1
            addLine(lines, depth, ("writeu8(%s, %s, %s)"):format(bufferVar, offsetVar, byteVar))
            addLine(lines, depth, ("%s += 1"):format(offsetVar))
        end
        return
    end

    if kind == "tagged_enum" then
        local tagField = (typeDef.tag :: any) :: string? or "Type"
        local variants = (typeDef.variants :: any) :: { any }?
        if variants == nil or #variants == 0 then
            error("Tagged enum is missing variants")
        end
        local tagExpr = fieldAccessExpr(valueExpr, tagField)
        local widthInfo = widthForBound(#variants - 1)
        for variantIndex = 1, #variants do
            local variant = variants[variantIndex]
            local fields = (variant.fields :: any) :: { Ast.Param }?
            if variantIndex == 1 then
                addLine(lines, depth, ("if %s == %q then"):format(tagExpr, variant.name))
            else
                addLine(lines, depth, ("elseif %s == %q then"):format(tagExpr, variant.name))
            end
            addLine(lines, depth + 1, ("%s(%s, %s, %d)"):format(widthInfo.writer, bufferVar, offsetVar, variantIndex - 1))
            addLine(lines, depth + 1, ("%s += %d"):format(offsetVar, widthInfo.bytes))
            if fields ~= nil then
                for fieldIndex = 1, #fields do
                    local field = fields[fieldIndex]
                    emitWriteForType(
                        lines,
                        state,
                        field.type,
                        fieldAccessExpr(valueExpr, field.name),
                        bufferVar,
                        offsetVar,
                        depth + 1,
                        structByName,
                        stringLenHints
                    )
                end
            end
        end
        addLine(lines, depth, "else")
        addLine(lines, depth + 1, "error(ERR_TAG)")
        addLine(lines, depth, "end")
        return
    end

    if kind == "inline_struct" then
        local fields = (typeDef.fields :: any) :: { Ast.Param }?
        if fields == nil then
            error("Inline struct is missing fields")
        end
        for fieldIndex = 1, #fields do
            local field = fields[fieldIndex]
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for write path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local cachedLen = getCollectionHint(stringLenHints, depth, "array", valueExpr)
        local lenExpr: string
        local indexVar = nextTemp(state, "arrayIndex")
        if cachedLen ~= nil then
            lenExpr = cachedLen
        else
            local lenVar = nextTemp(state, "arrayLen")
            addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
            lenExpr = lenVar
            if fixedLength ~= nil then
                addLine(lines, depth, ("if %s ~= %d then"):format(lenVar, fixedLength))
                addLine(lines, depth + 1, "error(ERR_SCHEMA)")
                addLine(lines, depth, "end")
            end
        end
        if not isFixedArray then
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
                addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, lenExpr))
            elseif widthInfo ~= nil then
                addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, lenExpr))
                addLine(lines, depth, ("%s += %d"):format(offsetVar, widthInfo.bytes))
            else
                error("Internal array length prefix mismatch")
            end
        end
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local valueIndex = nextTemp(state, "arrayValueIndex")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            local packedByte = nextTemp(state, "arrayPackedByte")
            if fixedLength ~= nil then
                local constantPackedBytes = ((fixedLength + 7) // 8)
                addLine(lines, depth, ("local %s = %d"):format(packedByteCount, constantPackedBytes))
            else
                addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, lenExpr))
            end
            addLine(lines, depth, ("local %s = 1"):format(valueIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = 0"):format(packedByte))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            local loopBoundExpr = if fixedLength ~= nil then tostring(fixedLength) else lenExpr
            addLine(lines, depth + 2, ("if %s > %s then"):format(valueIndex, loopBoundExpr))
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
            local loopBoundExpr = if fixedLength ~= nil then tostring(fixedLength) else lenExpr
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, loopBoundExpr))
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
        local cachedCount = getCollectionHint(stringLenHints, depth, "map", valueExpr)
        local countExpr: string
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        if cachedCount ~= nil then
            countExpr = cachedCount
        else
            local mapCount = nextTemp(state, "mapCount")
            local countKey = nextTemp(state, "mapCountKey")
            addLine(lines, depth, ("local %s = 0"):format(mapCount))
            addLine(lines, depth, ("local %s = next(%s, nil)"):format(countKey, valueExpr))
            addLine(lines, depth, ("while %s ~= nil do"):format(countKey))
            addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
            addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(countKey, valueExpr, countKey))
            addLine(lines, depth, "end")
            countExpr = mapCount
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(offsetVar, bufferVar, offsetVar, countExpr))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, offsetVar, countExpr))
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
    validateLevel: Analyzer.ValidateLevel,
    structByName: { [string]: Ast.Struct }
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

    if kind == "fixedarray" then
        local fixedLength = getFixedArrayLength(typeDef)
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("FixedArray type missing value type for fixed read path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local arrayVar = nextTemp(state, "fixedArrayValues")
        addLine(lines, depth, ("local %s = table.create(%d)"):format(arrayVar, fixedLength))

        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "fixedArrayPackedByteCount")
            local packedCursor = nextTemp(state, "fixedArrayPackedCursor")
            local packedIndex = nextTemp(state, "fixedArrayPackedIndex")
            local unpackIndex = nextTemp(state, "fixedArrayUnpackIndex")
            local packedByte = nextTemp(state, "fixedArrayPackedByte")
            local bitIndex = nextTemp(state, "fixedArrayBitIndex")
            local bitMask = nextTemp(state, "fixedArrayBitMask")
            addLine(lines, depth, ("local %s = %d"):format(packedByteCount, ((fixedLength + 7) // 8)))
            addLine(lines, depth, ("local %s = %s"):format(packedCursor, readOffset))
            addLine(lines, depth, ("local %s = 1"):format(unpackIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = readu8(%s, %s)"):format(packedByte, payloadVar, packedCursor))
            addLine(lines, depth + 1, ("%s += 1"):format(packedCursor))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            addLine(lines, depth + 2, ("if %s > %d then"):format(unpackIndex, fixedLength))
            addLine(lines, depth + 3, "break")
            addLine(lines, depth + 2, "end")
            addLine(lines, depth + 2, ("%s[%s] = band(%s, %s) ~= 0"):format(arrayVar, unpackIndex, packedByte, bitMask))
            addLine(lines, depth + 2, ("%s += 1"):format(unpackIndex))
            addLine(lines, depth + 2, ("%s = lshift(%s, 1)"):format(bitMask, bitMask))
            addLine(lines, depth + 1, "end")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(targetVar, arrayVar))
            return
        end

        local seenStructs: { [string]: boolean } = {}
        local elementSize = computeFixedByteSize(valueType, structByName, seenStructs)
        if elementSize == nil then
            error("Internal fixed array decode element size mismatch")
        end
        local indexVar = nextTemp(state, "fixedArrayIndex")
        local valueVar = nextTemp(state, "fixedArrayValue")
        local elementBase = nextTemp(state, "fixedArrayElementBase")
        addLine(lines, depth, ("local %s = %s"):format(elementBase, readOffset))
        addLine(lines, depth, ("for %s = 1, %d do"):format(indexVar, fixedLength))
        addLine(lines, depth + 1, ("local %s"):format(valueVar))
        emitReadFixedFromBlock(
            lines,
            state,
            valueType,
            valueVar,
            label .. "[]",
            payloadVar,
            elementBase,
            0,
            depth + 1,
            validateLevel,
            structByName
        )
        addLine(lines, depth + 1, ("%s[%s] = %s"):format(arrayVar, indexVar, valueVar))
        addLine(lines, depth + 1, ("%s += %d"):format(elementBase, elementSize))
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(targetVar, arrayVar))
        return
    end

    local structDecl = structByName[kind]
    if structDecl ~= nil then
        local structVar = nextTemp(state, "fixedStructValue")
        addLine(lines, depth, ("local %s = {}"):format(structVar))
        local fieldOffset = 0
        for fieldIndex = 1, #structDecl.fields do
            local field = structDecl.fields[fieldIndex]
            local fieldVar = nextTemp(state, "fixedStructField")
            addLine(lines, depth, ("local %s"):format(fieldVar))
            emitReadFixedFromBlock(
                lines,
                state,
                field.type,
                fieldVar,
                label .. "." .. field.name,
                payloadVar,
                blockVar,
                blockOffset + fieldOffset,
                depth,
                validateLevel,
                structByName
            )
            addLine(lines, depth, ("%s[%q] = %s"):format(structVar, field.name, fieldVar))
            local seenFieldStructs: { [string]: boolean } = {}
            local fieldSize = computeFixedByteSize(field.type, structByName, seenFieldStructs)
            if fieldSize == nil then
                error("Internal fixed struct decode field size mismatch")
            end
            fieldOffset += fieldSize
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, structVar))
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
        local declaredMin = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(strLen, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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

    if kind == "buffer" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local dataLen = nextTemp(state, "bufferLen")
        local dataNext = nextTemp(state, "bufferNext")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(dataLen))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(dataLen, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local lenNext = nextTemp(state, "bufferLenNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(lenNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(lenNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(dataLen, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, lenNext))
        else
            error("Internal buffer length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(dataLen, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(dataLen, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = %s + %s"):format(dataNext, offsetVar, dataLen))
        addLine(lines, depth, ("if %s > %s then"):format(dataNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        local bufferVar = nextTemp(state, "bufferValue")
        addLine(lines, depth, ("local %s = create(%s)"):format(bufferVar, dataLen))
        addLine(lines, depth, ("copy(%s, 0, %s, %s, %s)"):format(bufferVar, payloadVar, offsetVar, dataLen))
        addLine(lines, depth, ("%s = %s"):format(targetVar, bufferVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, dataNext))
        return
    end

    if kind == "vector" then
        local componentType = getVectorComponentType(typeDef)
        local componentKind = normalizeTypeKind(componentType.kind)
        local componentReader = PRIMITIVE_READERS[componentKind]
        local componentBytes = PRIMITIVE_BYTES[componentKind]
        if componentReader == nil or componentBytes == nil then
            error("Vector component reader metadata missing")
        end
        local vectorNext = nextTemp(state, "vectorNext")
        local xVar = nextTemp(state, "vectorX")
        local yVar = nextTemp(state, "vectorY")
        local zVar = nextTemp(state, "vectorZ")
        addLine(lines, depth, ("local %s = %s + %d"):format(vectorNext, offsetVar, componentBytes * 3))
        addLine(lines, depth, ("if %s > %s then"):format(vectorNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = %s(%s, %s)"):format(xVar, componentReader, payloadVar, offsetVar))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(yVar, componentReader, payloadVar, offsetVar, componentBytes))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(zVar, componentReader, payloadVar, offsetVar, componentBytes * 2))
        addLine(lines, depth, ("%s = Vector3.new(%s, %s, %s)"):format(targetVar, xVar, yVar, zVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, vectorNext))
        return
    end

    if kind == "cframe" then
        local posType, rotType = getCFrameComponentTypes(typeDef)
        local posKind = normalizeTypeKind(posType.kind)
        local rotKind = normalizeTypeKind(rotType.kind)
        local posReader = PRIMITIVE_READERS[posKind]
        local rotReader = PRIMITIVE_READERS[rotKind]
        local posBytes = PRIMITIVE_BYTES[posKind]
        local rotBytes = PRIMITIVE_BYTES[rotKind]
        if posReader == nil or rotReader == nil or posBytes == nil or rotBytes == nil then
            error("CFrame component reader metadata missing")
        end
        local totalBytes = posBytes * 3 + rotBytes * 3
        local cframeNext = nextTemp(state, "cframeNext")
        local pxVar = nextTemp(state, "cframePX")
        local pyVar = nextTemp(state, "cframePY")
        local pzVar = nextTemp(state, "cframePZ")
        local rxVar = nextTemp(state, "cframeRX")
        local ryVar = nextTemp(state, "cframeRY")
        local rzVar = nextTemp(state, "cframeRZ")
        addLine(lines, depth, ("local %s = %s + %d"):format(cframeNext, offsetVar, totalBytes))
        addLine(lines, depth, ("if %s > %s then"):format(cframeNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = %s(%s, %s)"):format(pxVar, posReader, payloadVar, offsetVar))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(pyVar, posReader, payloadVar, offsetVar, posBytes))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(pzVar, posReader, payloadVar, offsetVar, posBytes * 2))
        local rotBaseOffset = posBytes * 3
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(rxVar, rotReader, payloadVar, offsetVar, rotBaseOffset))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(ryVar, rotReader, payloadVar, offsetVar, rotBaseOffset + rotBytes))
        addLine(lines, depth, ("local %s = %s(%s, %s + %d)"):format(rzVar, rotReader, payloadVar, offsetVar, rotBaseOffset + rotBytes * 2))
        addLine(lines, depth, ("%s = CFrame.new(%s, %s, %s) * CFrame.fromOrientation(%s, %s, %s)"):format(targetVar, pxVar, pyVar, pzVar, rxVar, ryVar, rzVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, cframeNext))
        return
    end

    if kind == "brickcolor" then
        local nextOffset = nextTemp(state, "brickNext")
        local numberVar = nextTemp(state, "brickNumber")
        addLine(lines, depth, ("local %s = %s + 2"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu16(%s, %s)"):format(numberVar, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = BrickColor.new(%s)"):format(targetVar, numberVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "color3" then
        local nextOffset = nextTemp(state, "colorNext")
        local rVar = nextTemp(state, "colorR")
        local gVar = nextTemp(state, "colorG")
        local bVar = nextTemp(state, "colorB")
        addLine(lines, depth, ("local %s = %s + 3"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(rVar, payloadVar, offsetVar))
        addLine(lines, depth, ("local %s = readu8(%s, %s + 1)"):format(gVar, payloadVar, offsetVar))
        addLine(lines, depth, ("local %s = readu8(%s, %s + 2)"):format(bVar, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = Color3.fromRGB(%s, %s, %s)"):format(targetVar, rVar, gVar, bVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "datetime" then
        local nextOffset = nextTemp(state, "dateNext")
        local tsVar = nextTemp(state, "dateSeconds")
        addLine(lines, depth, ("local %s = %s + 8"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readf64(%s, %s)"):format(tsVar, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = DateTime.fromUnixTimestamp(%s)"):format(targetVar, tsVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "datetimemillis" then
        local nextOffset = nextTemp(state, "dateMillisNext")
        local tsVar = nextTemp(state, "dateMillis")
        addLine(lines, depth, ("local %s = %s + 8"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = readf64(%s, %s)"):format(tsVar, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = DateTime.fromUnixTimestampMillis(%s)"):format(targetVar, tsVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "enum" then
        local values = getEnumValues(typeDef)
        local widthInfo = getEnumWidthInfo(typeDef)
        local nextOffset = nextTemp(state, "enumNext")
        local indexVar = nextTemp(state, "enumIndex")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, widthInfo.bytes))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = %s(%s, %s)"):format(indexVar, widthInfo.reader, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        if isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s > %d then"):format(indexVar, #values - 1))
            emitError(lines, depth + 1, validateLevel, label .. " invalid enum index", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        for valueIndex = 1, #values do
            if valueIndex == 1 then
                addLine(lines, depth, ("if %s == %d then"):format(indexVar, valueIndex - 1))
            else
                addLine(lines, depth, ("elseif %s == %d then"):format(indexVar, valueIndex - 1))
            end
            addLine(lines, depth + 1, ("%s = %q"):format(targetVar, values[valueIndex]))
        end
        addLine(lines, depth, "else")
        if isValidateBasicOrFull(validateLevel) then
            emitError(lines, depth + 1, validateLevel, label .. " invalid enum index", "ERR_TAG")
        else
            addLine(lines, depth + 1, ("%s = %q"):format(targetVar, values[1]))
        end
        addLine(lines, depth, "end")
        return
    end

    if kind == "set" then
        local values = getSetValues(typeDef)
        local byteCount = getSetByteCount(typeDef)
        local nextOffset = nextTemp(state, "setNext")
        local setVar = nextTemp(state, "setValue")
        local valueCursor = 1
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, byteCount))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = {}"):format(setVar))
        for byte = 1, byteCount do
            local byteVar = nextTemp(state, "setByte")
            addLine(lines, depth, ("local %s = readu8(%s, %s)"):format(byteVar, payloadVar, offsetExpr(offsetVar, byte - 1)))
            local bitMask = 1
            for bit = 0, 7 do
                if valueCursor > #values then
                    break
                end
                local flagName = values[valueCursor]
                addLine(lines, depth, ("%s[%q] = band(%s, %d) ~= 0"):format(setVar, flagName, byteVar, bitMask))
                bitMask *= 2
                valueCursor += 1
            end
        end
        addLine(lines, depth, ("%s = %s"):format(targetVar, setVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "tagged_enum" then
        local tagField = (typeDef.tag :: any) :: string? or "Type"
        local variants = (typeDef.variants :: any) :: { any }?
        if variants == nil or #variants == 0 then
            error("Tagged enum is missing variants")
        end
        local widthInfo = widthForBound(#variants - 1)
        local tagNext = nextTemp(state, "taggedNext")
        local tagIndex = nextTemp(state, "taggedIndex")
        local taggedVar = nextTemp(state, "taggedValue")
        addLine(lines, depth, ("local %s = %s + %d"):format(tagNext, offsetVar, widthInfo.bytes))
        addLine(lines, depth, ("if %s > %s then"):format(tagNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = %s(%s, %s)"):format(tagIndex, widthInfo.reader, payloadVar, offsetVar))
        addLine(lines, depth, ("local %s = {}"):format(taggedVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, tagNext))
        for variantIndex = 1, #variants do
            local variant = variants[variantIndex]
            local fields = (variant.fields :: any) :: { Ast.Param }?
            if variantIndex == 1 then
                addLine(lines, depth, ("if %s == %d then"):format(tagIndex, variantIndex - 1))
            else
                addLine(lines, depth, ("elseif %s == %d then"):format(tagIndex, variantIndex - 1))
            end
            addLine(lines, depth + 1, ("%s[%q] = %q"):format(taggedVar, tagField, variant.name))
            if fields ~= nil then
                for fieldIndex = 1, #fields do
                    local field = fields[fieldIndex]
                    local fieldVar = nextTemp(state, "taggedField")
                    addLine(lines, depth + 1, ("local %s"):format(fieldVar))
                    emitReadForType(
                        lines,
                        state,
                        field.type,
                        fieldVar,
                        label .. "." .. field.name,
                        payloadVar,
                        payloadLengthVar,
                        offsetVar,
                        depth + 1,
                        validateLevel,
                        structByName
                    )
                    addLine(lines, depth + 1, ("%s[%q] = %s"):format(taggedVar, field.name, fieldVar))
                end
            end
        end
        addLine(lines, depth, "else")
        emitError(lines, depth + 1, validateLevel, label .. " invalid tagged enum variant", "ERR_TAG")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(targetVar, taggedVar))
        return
    end

    if kind == "inline_struct" then
        local fields = (typeDef.fields :: any) :: { Ast.Param }?
        if fields == nil then
            error("Inline struct is missing fields")
        end
        local structVar = nextTemp(state, "structValue")
        addLine(lines, depth, ("local %s = {}"):format(structVar))
        for fieldIndex = 1, #fields do
            local field = fields[fieldIndex]
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for read path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local minLen = typeDef.min
        local maxLen = if prefixInfo ~= nil then prefixInfo.declaredMax else nil
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local fixedArrayTotalSize: number? = nil
        local fixedArrayElementSize: number? = nil
        if isFixedArray and fixedLength ~= nil then
            local seenStructs: { [string]: boolean } = {}
            fixedArrayTotalSize = computeFixedByteSize(typeDef, structByName, seenStructs)
            if fixedArrayTotalSize ~= nil and valueKind ~= "bool" then
                local seenElementStructs: { [string]: boolean } = {}
                fixedArrayElementSize = computeFixedByteSize(valueType, structByName, seenElementStructs)
            end
        end
        local countVar = nextTemp(state, "arrayCount")
        local indexVar = nextTemp(state, "arrayIndex")
        local arrayVar = nextTemp(state, "arrayValues")
        local valueVar = nextTemp(state, "arrayValue")
        if fixedLength ~= nil then
            addLine(lines, depth, ("local %s = %d"):format(countVar, fixedLength))
        else
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
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
        end
        if minLen ~= nil and isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s < %d then"):format(countVar, minLen))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum array length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if maxLen ~= nil and isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo ~= nil and prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = table.create(%s)"):format(arrayVar, countVar))
        if fixedArrayTotalSize ~= nil then
            local arrayBlock = nextTemp(state, "arrayFixedBlock")
            local arrayBlockNext = nextTemp(state, "arrayFixedBlockNext")
            emitReserveInline(
                lines,
                depth,
                offsetVar,
                payloadLengthVar,
                tostring(fixedArrayTotalSize),
                arrayBlock,
                arrayBlockNext,
                validateLevel,
                label
            )
            if valueKind == "bool" then
                local packedByteCount = nextTemp(state, "arrayPackedByteCount")
                local packedCursor = nextTemp(state, "arrayPackedCursor")
                local packedIndex = nextTemp(state, "arrayPackedIndex")
                local unpackIndex = nextTemp(state, "arrayUnpackIndex")
                local packedByte = nextTemp(state, "arrayPackedByte")
                local bitIndex = nextTemp(state, "arrayBitIndex")
                local bitMask = nextTemp(state, "arrayBitMask")
                addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
                addLine(lines, depth, ("local %s = %s"):format(packedCursor, arrayBlock))
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
            else
                if fixedArrayElementSize == nil then
                    error("Internal fixedarray decode element size mismatch")
                end
                local elementBase = nextTemp(state, "arrayElementBase")
                addLine(lines, depth, ("local %s = %s"):format(elementBase, arrayBlock))
                addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
                addLine(lines, depth + 1, ("local %s"):format(valueVar))
                emitReadFixedFromBlock(
                    lines,
                    state,
                    valueType,
                    valueVar,
                    label .. "[]",
                    payloadVar,
                    elementBase,
                    0,
                    depth + 1,
                    validateLevel,
                    structByName
                )
                addLine(lines, depth + 1, ("%s[%s] = %s"):format(arrayVar, indexVar, valueVar))
                addLine(lines, depth + 1, ("%s += %d"):format(elementBase, fixedArrayElementSize))
                addLine(lines, depth, "end")
            end
        elseif valueKind == "bool" then
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
        local minLen = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and minLen ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(countVar, minLen))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum map size", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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
        local declaredMin = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(strLen, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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

    if kind == "buffer" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
        local declaredMax = prefixInfo.declaredMax
        local widthInfo = prefixInfo.width
        local dataLen = nextTemp(state, "skipBufferLen")
        local dataNext = nextTemp(state, "skipBufferNext")
        if prefixInfo.isVarint then
            addLine(lines, depth, ("local %s"):format(dataLen))
            addLine(lines, depth, ("%s, %s = ReadVarUInt(%s, %s, %s)"):format(dataLen, offsetVar, payloadVar, payloadLengthVar, offsetVar))
        elseif widthInfo ~= nil then
            local lenNext = nextTemp(state, "skipBufferLenNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(lenNext, offsetVar, widthInfo.bytes))
            addLine(lines, depth, ("if %s > %s then"):format(lenNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(dataLen, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("%s = %s"):format(offsetVar, lenNext))
        else
            error("Internal buffer length prefix mismatch")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(dataLen, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
            addLine(lines, depth, ("if %s > %d then"):format(dataLen, declaredMax))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds max length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = %s + %s"):format(dataNext, offsetVar, dataLen))
        addLine(lines, depth, ("if %s > %s then"):format(dataNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, dataNext))
        return
    end

    if kind == "vector" then
        local componentType = getVectorComponentType(typeDef)
        local componentKind = normalizeTypeKind(componentType.kind)
        local componentBytes = PRIMITIVE_BYTES[componentKind]
        if componentBytes == nil then
            error("Vector component width metadata missing")
        end
        local nextOffset = nextTemp(state, "skipVectorNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, componentBytes * 3))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "cframe" then
        local posType, rotType = getCFrameComponentTypes(typeDef)
        local posKind = normalizeTypeKind(posType.kind)
        local rotKind = normalizeTypeKind(rotType.kind)
        local posBytes = PRIMITIVE_BYTES[posKind]
        local rotBytes = PRIMITIVE_BYTES[rotKind]
        if posBytes == nil or rotBytes == nil then
            error("CFrame component width metadata missing")
        end
        local nextOffset = nextTemp(state, "skipCFrameNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, posBytes * 3 + rotBytes * 3))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "brickcolor" then
        local nextOffset = nextTemp(state, "skipBrickNext")
        addLine(lines, depth, ("local %s = %s + 2"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "color3" then
        local nextOffset = nextTemp(state, "skipColorNext")
        addLine(lines, depth, ("local %s = %s + 3"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "datetime" or kind == "datetimemillis" then
        local nextOffset = nextTemp(state, "skipDateNext")
        addLine(lines, depth, ("local %s = %s + 8"):format(nextOffset, offsetVar))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "enum" then
        local values = getEnumValues(typeDef)
        local widthInfo = getEnumWidthInfo(typeDef)
        local nextOffset = nextTemp(state, "skipEnumNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, widthInfo.bytes))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        if isValidateBasicOrFull(validateLevel) then
            local indexVar = nextTemp(state, "skipEnumIndex")
            addLine(lines, depth, ("local %s = %s(%s, %s)"):format(indexVar, widthInfo.reader, payloadVar, offsetVar))
            addLine(lines, depth, ("if %s > %d then"):format(indexVar, #values - 1))
            emitError(lines, depth + 1, validateLevel, label .. " invalid enum index", "ERR_TAG")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "set" then
        local byteCount = getSetByteCount(typeDef)
        local nextOffset = nextTemp(state, "skipSetNext")
        addLine(lines, depth, ("local %s = %s + %d"):format(nextOffset, offsetVar, byteCount))
        addLine(lines, depth, ("if %s > %s then"):format(nextOffset, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("%s = %s"):format(offsetVar, nextOffset))
        return
    end

    if kind == "tagged_enum" then
        local variants = (typeDef.variants :: any) :: { any }?
        if variants == nil or #variants == 0 then
            error("Tagged enum is missing variants")
        end
        local widthInfo = widthForBound(#variants - 1)
        local tagNext = nextTemp(state, "skipTaggedNext")
        local tagIndex = nextTemp(state, "skipTaggedIndex")
        addLine(lines, depth, ("local %s = %s + %d"):format(tagNext, offsetVar, widthInfo.bytes))
        addLine(lines, depth, ("if %s > %s then"):format(tagNext, payloadLengthVar))
        emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
        addLine(lines, depth, "end")
        addLine(lines, depth, ("local %s = %s(%s, %s)"):format(tagIndex, widthInfo.reader, payloadVar, offsetVar))
        addLine(lines, depth, ("%s = %s"):format(offsetVar, tagNext))
        for variantIndex = 1, #variants do
            local variant = variants[variantIndex]
            local fields = (variant.fields :: any) :: { Ast.Param }?
            if variantIndex == 1 then
                addLine(lines, depth, ("if %s == %d then"):format(tagIndex, variantIndex - 1))
            else
                addLine(lines, depth, ("elseif %s == %d then"):format(tagIndex, variantIndex - 1))
            end
            if fields ~= nil then
                for fieldIndex = 1, #fields do
                    local field = fields[fieldIndex]
                    emitSkipForType(
                        lines,
                        state,
                        field.type,
                        label .. "." .. field.name,
                        payloadVar,
                        payloadLengthVar,
                        offsetVar,
                        depth + 1,
                        validateLevel,
                        structByName
                    )
                end
            end
        end
        addLine(lines, depth, "else")
        emitError(lines, depth + 1, validateLevel, label .. " invalid tagged enum variant", "ERR_TAG")
        addLine(lines, depth, "end")
        return
    end

    if kind == "inline_struct" then
        local fields = (typeDef.fields :: any) :: { Ast.Param }?
        if fields == nil then
            error("Inline struct is missing fields")
        end
        for fieldIndex = 1, #fields do
            local field = fields[fieldIndex]
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for skip path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local minLen = typeDef.min
        local maxLen = if prefixInfo ~= nil then prefixInfo.declaredMax else nil
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local fixedArraySkipBytes: number? = nil
        if isFixedArray then
            fixedArraySkipBytes = canSingleAdvanceSkipForFixedType(typeDef, validateLevel, structByName)
        end
        local countVar = nextTemp(state, "skipArrayCount")
        local indexVar = nextTemp(state, "skipArrayIndex")
        if fixedLength ~= nil then
            addLine(lines, depth, ("local %s = %d"):format(countVar, fixedLength))
        else
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
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
        end
        if minLen ~= nil and isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s < %d then"):format(countVar, minLen))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum array length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if maxLen ~= nil and isValidateBasicOrFull(validateLevel) then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, maxLen))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if prefixInfo ~= nil and prefixInfo.isVarint then
            addLine(lines, depth, ("if %s > %d then"):format(countVar, MAX_VARINT_LENGTH))
            emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
        if fixedArraySkipBytes ~= nil then
            local fixedSkipNext = nextTemp(state, "skipArrayFixedNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(fixedSkipNext, offsetVar, fixedArraySkipBytes))
            addLine(lines, depth, ("if %s > %s then"):format(fixedSkipNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(offsetVar, fixedSkipNext))
        elseif valueKind == "bool" then
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
        local minLen = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and minLen ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(countVar, minLen))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum map size", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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
    -- FixedArray: variable only if element type is variable-length
    if kind == "fixedarray" then
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        return fixedSize == nil
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
    -- FixedArray with fixed-size elements: compute total serialized size
    if kind == "fixedarray" then
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        return if fixedSize ~= nil then fixedSize else 0
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
        cacheCollectionHint(stringLenHints, depth, "string", valueExpr, lenVar)
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

    if kind == "buffer"
        or kind == "vector"
        or kind == "cframe"
        or kind == "brickcolor"
        or kind == "color3"
        or kind == "datetime"
        or kind == "datetimemillis"
        or kind == "enum"
        or kind == "set"
        or kind == "tagged_enum"
        or kind == "inline_struct"
    then
        emitSizeForType(
            lines,
            state,
            typeDef,
            valueExpr,
            label,
            varSizeVar,
            depth,
            validateLevel,
            structByName,
            stringLenHints
        )
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error(("Array type is missing value type for %s"):format(label))
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
        local declaredMax = if prefixInfo ~= nil then prefixInfo.declaredMax else nil
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local fixedArrayTotalSize: number? = nil
        if isFixedArray and fixedLength ~= nil then
            local seenStructs: { [string]: boolean } = {}
            fixedArrayTotalSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        end
        local lenVar = nextTemp(state, "arrayLen")
        local indexVar = nextTemp(state, "arrayIndex")
        local keyVar = nextTemp(state, "arrayKey")
        if isValidateFull(validateLevel) then
            addLine(lines, depth, ("if type(%s) ~= \"table\" then"):format(valueExpr))
            emitError(lines, depth + 1, validateLevel, label .. " must be array table", "ERR_TYPE")
            addLine(lines, depth, "end")
        end
        addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
        cacheCollectionHint(stringLenHints, depth, "array", valueExpr, lenVar)
        if fixedLength ~= nil then
            addLine(lines, depth, ("if %s ~= %d then"):format(lenVar, fixedLength))
            emitError(lines, depth + 1, validateLevel, label .. " has invalid fixedarray length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        elseif isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(lenVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum array length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        elseif isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
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
        if not isFixedArray then
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
                addLine(lines, depth, ("if %s > %d then"):format(lenVar, MAX_VARINT_LENGTH))
                emitError(lines, depth + 1, validateLevel, label .. " exceeds varint limit", "ERR_SCHEMA")
                addLine(lines, depth, "end")
                addLine(lines, depth, ("%s += VarUIntSize(%s)"):format(prefixSizeVar, lenVar))
            elseif widthInfo ~= nil then
                addLine(lines, depth, ("%s += %d"):format(prefixSizeVar, widthInfo.bytes))
            else
                error("Internal array length prefix mismatch")
            end
        end
        if fixedArrayTotalSize ~= nil then
            -- Entire fixedarray serialized size is compile-time known (already counted in canonical fixed)
            -- No additional size contribution needed (already in fixedBytesForCanonicalType)
        elseif valueKind == "bool" then
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
        local declaredMin = typeDef.min
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
        cacheCollectionHint(stringLenHints, depth, "map", valueExpr, mapCount)
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(mapCount, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum map size", "ERR_SCHEMA")
            addLine(lines, depth, "end")
        end
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
        local cachedLen = getCollectionHint(stringLenHints, depth, "string", valueExpr)
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

    if kind == "buffer"
        or kind == "vector"
        or kind == "cframe"
        or kind == "brickcolor"
        or kind == "color3"
        or kind == "datetime"
        or kind == "datetimemillis"
        or kind == "enum"
        or kind == "set"
        or kind == "tagged_enum"
        or kind == "inline_struct"
    then
        emitWriteForType(lines, state, typeDef, valueExpr, bufferVar, varVar, depth, structByName, stringLenHints)
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

    if kind == "array" or kind == "fixedarray" then
        local isFixedArray = kind == "fixedarray"
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical write path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedLength = if isFixedArray then getFixedArrayLength(typeDef) else nil
        local prefixInfo = if isFixedArray then nil else getArrayLengthPrefixInfo(typeDef)
        local widthInfo = if prefixInfo ~= nil then prefixInfo.width else nil
        local cachedLen = getCollectionHint(stringLenHints, depth, "array", valueExpr)
        local lenExpr: string
        local indexVar = nextTemp(state, "arrayIndex")
        if cachedLen ~= nil then
            lenExpr = cachedLen
        else
            local lenVar = nextTemp(state, "arrayLen")
            addLine(lines, depth, ("local %s = #%s"):format(lenVar, valueExpr))
            lenExpr = lenVar
            if fixedLength ~= nil then
                addLine(lines, depth, ("if %s ~= %d then"):format(lenVar, fixedLength))
                addLine(lines, depth + 1, "error(ERR_SCHEMA)")
                addLine(lines, depth, "end")
            end
        end
        if not isFixedArray then
            if prefixInfo == nil then
                error("Internal array prefix metadata missing")
            elseif prefixInfo.isVarint then
                addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(prefixVar, bufferVar, prefixVar, lenExpr))
            elseif widthInfo ~= nil then
                addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, prefixVar, lenExpr))
                addLine(lines, depth, ("%s += %d"):format(prefixVar, widthInfo.bytes))
            else
                error("Internal array length prefix mismatch")
            end
        end
        if valueKind == "bool" then
            local packedByteCount = nextTemp(state, "arrayPackedByteCount")
            local packedIndex = nextTemp(state, "arrayPackedIndex")
            local valueIndex = nextTemp(state, "arrayValueIndex")
            local bitIndex = nextTemp(state, "arrayBitIndex")
            local bitMask = nextTemp(state, "arrayBitMask")
            local packedByte = nextTemp(state, "arrayPackedByte")
            if fixedLength ~= nil then
                local constantPackedBytes = ((fixedLength + 7) // 8)
                addLine(lines, depth, ("local %s = %d"):format(packedByteCount, constantPackedBytes))
            else
                addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, lenExpr))
            end
            addLine(lines, depth, ("local %s = 1"):format(valueIndex))
            addLine(lines, depth, ("for %s = 1, %s do"):format(packedIndex, packedByteCount))
            addLine(lines, depth + 1, ("local %s = 0"):format(packedByte))
            addLine(lines, depth + 1, ("local %s = 1"):format(bitMask))
            addLine(lines, depth + 1, ("for %s = 1, 8 do"):format(bitIndex))
            local loopBoundExpr = if fixedLength ~= nil then tostring(fixedLength) else lenExpr
            addLine(lines, depth + 2, ("if %s > %s then"):format(valueIndex, loopBoundExpr))
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
            local loopBoundExpr = if fixedLength ~= nil then tostring(fixedLength) else lenExpr
            addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, loopBoundExpr))
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
        local cachedCount = getCollectionHint(stringLenHints, depth, "map", valueExpr)
        local countExpr: string
        local mapKey = nextTemp(state, "mapKey")
        local mapValue = nextTemp(state, "mapValue")
        if cachedCount ~= nil then
            countExpr = cachedCount
        else
            local mapCount = nextTemp(state, "mapCount")
            local countKey = nextTemp(state, "mapCountKey")
            addLine(lines, depth, ("local %s = 0"):format(mapCount))
            addLine(lines, depth, ("local %s = next(%s, nil)"):format(countKey, valueExpr))
            addLine(lines, depth, ("while %s ~= nil do"):format(countKey))
            addLine(lines, depth + 1, ("%s += 1"):format(mapCount))
            addLine(lines, depth + 1, ("%s = next(%s, %s)"):format(countKey, valueExpr, countKey))
            addLine(lines, depth, "end")
            countExpr = mapCount
        end
        if prefixInfo.isVarint then
            addLine(lines, depth, ("%s = WriteVarUInt(%s, %s, %s)"):format(prefixVar, bufferVar, prefixVar, countExpr))
        elseif widthInfo ~= nil then
            addLine(lines, depth, ("%s(%s, %s, %s)"):format(widthInfo.writer, bufferVar, prefixVar, countExpr))
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
    if PRIMITIVE_BYTES[kind] ~= nil
        or kind == "bool"
        or kind == "buffer"
        or kind == "vector"
        or kind == "cframe"
        or kind == "brickcolor"
        or kind == "color3"
        or kind == "datetime"
        or kind == "datetimemillis"
        or kind == "enum"
        or kind == "set"
        or kind == "tagged_enum"
        or kind == "inline_struct"
    then
        return
    end

    if kind == "string" then
        local prefixInfo = getStringLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(lenVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum length", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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

    if kind == "array" or kind == "fixedarray" then
        local countVar: string
        if kind == "fixedarray" then
            countVar = tostring(getFixedArrayLength(typeDef))
        else
            local prefixInfo = getArrayLengthPrefixInfo(typeDef)
            local declaredMin = typeDef.min
            local declaredMax = prefixInfo.declaredMax
            local widthInfo = prefixInfo.width
            countVar = nextTemp(state, "arrayCount")
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
            if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
                addLine(lines, depth, ("if %s < %d then"):format(countVar, declaredMin))
                emitError(lines, depth + 1, validateLevel, label .. " below minimum array length", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
            if isValidateBasicOrFull(validateLevel) and declaredMax ~= nil then
                addLine(lines, depth, ("if %s > %d then"):format(countVar, declaredMax))
                emitError(lines, depth + 1, validateLevel, label .. " exceeds array bound", "ERR_SCHEMA")
                addLine(lines, depth, "end")
            end
        end
        metas[#metas + 1] = {
            kind = "array",
            valueVar = countVar,
        }
        return
    end

    if kind == "map" then
        local prefixInfo = getMapLengthPrefixInfo(typeDef)
        local declaredMin = typeDef.min
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
        if isValidateBasicOrFull(validateLevel) and declaredMin ~= nil then
            addLine(lines, depth, ("if %s < %d then"):format(countVar, declaredMin))
            emitError(lines, depth + 1, validateLevel, label .. " below minimum map size", "ERR_SCHEMA")
            addLine(lines, depth, "end")
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

    if kind == "buffer"
        or kind == "vector"
        or kind == "cframe"
        or kind == "brickcolor"
        or kind == "color3"
        or kind == "datetime"
        or kind == "datetimemillis"
        or kind == "enum"
        or kind == "set"
        or kind == "tagged_enum"
        or kind == "inline_struct"
    then
        emitReadForType(lines, state, typeDef, targetVar, label, payloadVar, payloadLengthVar, varVar, depth, validateLevel, structByName)
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

    if kind == "array" or kind == "fixedarray" then
        local meta = consumeDecodeVarMeta(metas, cursor, "array")
        local countVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical read path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedArrayTotalSize: number? = nil
        local fixedArrayElementSize: number? = nil
        if kind == "fixedarray" then
            local seenStructs: { [string]: boolean } = {}
            fixedArrayTotalSize = computeFixedByteSize(typeDef, structByName, seenStructs)
            if fixedArrayTotalSize ~= nil and valueKind ~= "bool" then
                local seenElementStructs: { [string]: boolean } = {}
                fixedArrayElementSize = computeFixedByteSize(valueType, structByName, seenElementStructs)
            end
        end
        local indexVar = nextTemp(state, "arrayIndex")
        local arrayVar = nextTemp(state, "arrayValues")
        local valueVar = nextTemp(state, "arrayValue")
        addLine(lines, depth, ("local %s = table.create(%s)"):format(arrayVar, countVar))
        if fixedArrayTotalSize ~= nil then
            local arrayBlock = nextTemp(state, "arrayFixedBlock")
            local arrayBlockNext = nextTemp(state, "arrayFixedBlockNext")
            emitReserveInline(
                lines,
                depth,
                varVar,
                payloadLengthVar,
                tostring(fixedArrayTotalSize),
                arrayBlock,
                arrayBlockNext,
                validateLevel,
                label
            )
            if valueKind == "bool" then
                local packedByteCount = nextTemp(state, "arrayPackedByteCount")
                local packedCursor = nextTemp(state, "arrayPackedCursor")
                local packedIndex = nextTemp(state, "arrayPackedIndex")
                local unpackIndex = nextTemp(state, "arrayUnpackIndex")
                local packedByte = nextTemp(state, "arrayPackedByte")
                local bitIndex = nextTemp(state, "arrayBitIndex")
                local bitMask = nextTemp(state, "arrayBitMask")
                addLine(lines, depth, ("local %s = ((%s + 7) // 8)"):format(packedByteCount, countVar))
                addLine(lines, depth, ("local %s = %s"):format(packedCursor, arrayBlock))
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
            else
                if fixedArrayElementSize == nil then
                    error("Internal canonical fixedarray decode element size mismatch")
                end
                local elementBase = nextTemp(state, "arrayElementBase")
                addLine(lines, depth, ("local %s = %s"):format(elementBase, arrayBlock))
                addLine(lines, depth, ("for %s = 1, %s do"):format(indexVar, countVar))
                addLine(lines, depth + 1, ("local %s"):format(valueVar))
                emitReadFixedFromBlock(
                    lines,
                    state,
                    valueType,
                    valueVar,
                    label .. "[]",
                    payloadVar,
                    elementBase,
                    0,
                    depth + 1,
                    validateLevel,
                    structByName
                )
                addLine(lines, depth + 1, ("%s[%s] = %s"):format(arrayVar, indexVar, valueVar))
                addLine(lines, depth + 1, ("%s += %d"):format(elementBase, fixedArrayElementSize))
                addLine(lines, depth, "end")
            end
        elseif valueKind == "bool" then
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

    if kind == "buffer"
        or kind == "vector"
        or kind == "cframe"
        or kind == "brickcolor"
        or kind == "color3"
        or kind == "datetime"
        or kind == "datetimemillis"
        or kind == "enum"
        or kind == "set"
        or kind == "tagged_enum"
        or kind == "inline_struct"
    then
        emitSkipForType(lines, state, typeDef, label, payloadVar, payloadLengthVar, varVar, depth, validateLevel, structByName)
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

    if kind == "array" or kind == "fixedarray" then
        local meta = consumeDecodeVarMeta(metas, cursor, "array")
        local countVar = meta.valueVar
        local valueType = (typeDef.value :: any) :: Ast.Type?
        if valueType == nil then
            error("Array type missing value type for canonical skip path")
        end
        local valueKind = normalizeTypeKind(valueType.kind)
        local fixedArraySkipBytes: number? = nil
        if kind == "fixedarray" then
            fixedArraySkipBytes = canSingleAdvanceSkipForFixedType(typeDef, validateLevel, structByName)
        end
        if fixedArraySkipBytes ~= nil then
            local fixedSkipNext = nextTemp(state, "skipArrayFixedNext")
            addLine(lines, depth, ("local %s = %s + %d"):format(fixedSkipNext, varVar, fixedArraySkipBytes))
            addLine(lines, depth, ("if %s > %s then"):format(fixedSkipNext, payloadLengthVar))
            emitError(lines, depth + 1, validateLevel, label .. " out of bounds", "ERR_BOUNDS")
            addLine(lines, depth, "end")
            addLine(lines, depth, ("%s = %s"):format(varVar, fixedSkipNext))
        elseif valueKind == "bool" then
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
    -- FixedArray with fixed-size elements can be emitted as a constant size term
    if kind == "fixedarray" then
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        return fixedSize ~= nil
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
        cacheCollectionHint(stringLenHints, 1, "string", valueExpr, lenVar)
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

    -- FixedArray with fixed-size elements: emit as a constant size term
    if kind == "fixedarray" then
        local seenStructs: { [string]: boolean } = {}
        local fixedSize = computeFixedByteSize(typeDef, structByName, seenStructs)
        if fixedSize ~= nil then
            if isValidateFull(validateLevel) then
                addLine(lines, 1, ("if type(%s) ~= \"table\" then"):format(valueExpr))
                emitError(lines, 2, validateLevel, label .. " must be array table", "ERR_TYPE")
                addLine(lines, 1, "end")
                local fixedLength = getFixedArrayLength(typeDef)
                local lenVar = nextTemp(state, "arrayLen")
                addLine(lines, 1, ("local %s = #%s"):format(lenVar, valueExpr))
                cacheCollectionHint(stringLenHints, 1, "array", valueExpr, lenVar)
                addLine(lines, 1, ("if %s ~= %d then"):format(lenVar, fixedLength))
                emitError(lines, 2, validateLevel, label .. " has invalid fixedarray length", "ERR_SCHEMA")
                addLine(lines, 1, "end")
            end
            terms[#terms + 1] = tostring(fixedSize)
            return
        end
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
    local foldedConstant = 0
    local dynamicTerms: { string } = {}
    for termIndex = 1, #terms do
        local numericTerm = tonumber(terms[termIndex])
        if numericTerm ~= nil then
            foldedConstant += numericTerm
        else
            dynamicTerms[#dynamicTerms + 1] = terms[termIndex]
        end
    end
    if #dynamicTerms == 0 then
        addLine(lines, 1, ("local %s = %s"):format(totalVar, tostring(foldedConstant)))
    elseif foldedConstant == 0 then
        addLine(lines, 1, ("local %s = %s"):format(totalVar, table.concat(dynamicTerms, " + ")))
    else
        addLine(
            lines,
            1,
            ("local %s = %s + %s"):format(totalVar, tostring(foldedConstant), table.concat(dynamicTerms, " + "))
        )
    end
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
    includeDecode: boolean,
    decodeStructMode: DecodeStructMode
)
    local usesCanonicalLayout = paramsHaveVariableLength(params, structByName)
    local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(params, structByName) or 0
    local baseBytes = messageIdWidth.bytes

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
        addLine(lines, 1, ("%s(payload, 0, %s)"):format(messageIdWidth.writer, messageIdConst))

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

    if includeDecode then
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
                            validateLevel,
                            structByName
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

return {
    emitSizeForType = emitSizeForType,
    emitWriteForType = emitWriteForType,
    emitWriteFixedToBlock = emitWriteFixedToBlock,
    emitReserveInline = emitReserveInline,
    emitReadFixedFromBlock = emitReadFixedFromBlock,
    emitReadForType = emitReadForType,
    emitSkipForType = emitSkipForType,
    emitCanonicalSizeForType = emitCanonicalSizeForType,
    emitWriteCanonicalForType = emitWriteCanonicalForType,
    emitDecodeCanonicalPrefixForType = emitDecodeCanonicalPrefixForType,
    emitDecodeCanonicalDataForType = emitDecodeCanonicalDataForType,
    emitSkipCanonicalDataForType = emitSkipCanonicalDataForType,
    canEmitFlatSizeType = canEmitFlatSizeType,
    canEmitFlatTopLevelSize = canEmitFlatTopLevelSize,
    emitFlatSizeForType = emitFlatSizeForType,
    emitFlatTopLevelSize = emitFlatTopLevelSize,
    emitCodecFunctions = emitCodecFunctions,
    emitSkipFunction = emitSkipFunction,
    emitPassthroughValidator = emitPassthroughValidator,
    emitWriteParamsWithFixedBlocks = emitWriteParamsWithFixedBlocks,
}
