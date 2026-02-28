--!strict
-- Name: Types
-- Purpose: Shared generator types and constants

local Ast = require(script.Parent.Parent.idl.Ast)
local Analyzer = require(script.Parent.Parent.idl.Analyzer)

export type MessageInfo = {
    message: Analyzer.AnalyzedMessage,
    symbol: string,
    apiBase: string,
    fullName: string,
    serializedParams: { Ast.Param },
    passthroughParams: { Ast.Param },
    serializedReturns: { Ast.Param },
    passthroughReturns: { Ast.Param },
}

export type IntegerRange = {
    min: number,
    max: number,
}

export type EmitState = {
    tempIndex: number,
}

export type WidthInfo = {
    bytes: number,
    writer: string,
    reader: string,
    maxValue: number,
}

export type LengthPrefixInfo = {
    declaredMax: number?,
    isVarint: boolean,
    width: WidthInfo?,
}

export type TypeBrandingMode = "Off" | "On"
export type DecodeStructMode = "Locals" | "Table"

export type DecodedLeaf = {
    labelSuffix: string,
    targetName: string,
    typeDef: Ast.Type,
}

export type DecodedParamPlan = {
    leaves: { DecodedLeaf },
    leafNames: { string },
}

export type DecodeVarMeta = {
    kind: string,
    valueVar: string,
}

export type DecodeVarCursor = {
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
    f16 = 2,
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
    f16 = "writef16",
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
    f16 = "readf16",
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

return {
    EMPTY_PARAMS = EMPTY_PARAMS,
    LUAU_KEYWORDS = LUAU_KEYWORDS,
    PRIMITIVE_BYTES = PRIMITIVE_BYTES,
    PRIMITIVE_WRITERS = PRIMITIVE_WRITERS,
    PRIMITIVE_READERS = PRIMITIVE_READERS,
    INTEGER_RANGES = INTEGER_RANGES,
    MAX_FIXED_LENGTH_BOUND = MAX_FIXED_LENGTH_BOUND,
    MAX_VARINT_LENGTH = MAX_VARINT_LENGTH,
}
