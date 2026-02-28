--!strict
-- Name: AST
-- Purpose: AST type definitions for NetRay IDL

export type Token = {
    kind: string,
    value: string,
    line: number,
    column: number,
}

export type Type = {
    kind: string,
    name: string?,
    value: any?,
    key: any?,
    min: number?,
    max: number?,
    values: { string }?,
    fields: { any }?,
    variants: { any }?,
    tag: string?,
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
    values: { string }?,
    tag: string?,
    variants: { any }?,
}

export type Set = {
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

export type Decl = Struct | Enum | Set | Event | Function | Scope

export type Schema = {
    options: { Option },
    declarations: { Decl },
}

return {}
