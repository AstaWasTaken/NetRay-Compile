--!strict
-- Name: AST
-- Purpose: AST type definitions for NetRay IDL
-- Generated-by: NetRay-Compiler (authored)

export type Token = {
    kind: string,
    value: string,
    line: number,
    column: number,
}

export type Type = {
    kind: string,
    value: Type?,
    key: Type?,
    max: number?,
}

export type Param = {
    name: string,
    type: Type,
}

export type Struct = {
    name: string,
    fields: { Param },
}

export type Enum = {
    name: string,
    values: { string },
}

export type Event = {
    name: string,
    params: { Param },
    reliability: string,
    from: string?,
    call: string?,
}

export type Function = {
    name: string,
    params: { Param },
    returns: { Param },
    yieldMode: string?,
}

export type Scope = {
    name: string,
    declarations: { Decl },
}

export type Option = {
    name: string,
    value: string,
}

export type Decl = Struct | Enum | Event | Function | Scope

export type Schema = {
    options: { Option },
    declarations: { Decl },
}

return {}
