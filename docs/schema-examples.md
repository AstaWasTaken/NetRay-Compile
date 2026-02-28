# Schema Examples

## Minimal Event
```rust
event reliable Ping(u16 id);
```

## Block Event with Struct Payload
```rust
struct PingData {
  id: u16,
  latency: u16,
}

event Ping {
  From: Client,
  Type: Reliable,
  Call: ManySync,
  Data: PingData,
}
```

## Tuple Payload Event
```rust
event Position {
  From: Both,
  Type: Unreliable,
  Call: ManyAsync,
  Data: (u16, f32, f32),
}
```

## Function Request/Response
```rust
function GetDealers {
  Yield: SingleSync,
  Data: (u16),
  Return: (u8, string<100>),
}
```

## Polling Receive Mode
```rust
event Snapshot {
  From: Server,
  Type: Unreliable,
  Call: Polling,
  Data: (u16, f32, f32),
}
```

## Nested Scopes
```rust
scope Gameplay {
  scope Cars {
    event Spawned {
      From: Server,
      Type: Reliable,
      Data: u16,
    }
  }
}
```

## Options
```rust
option Validate = Full;
option TypeBranding = On;
option DecodeStruct = Table;
```

## Passthrough Example
```rust
function InspectPlayer {
  Data: (passthrough Player),
  Return: (string<32>),
}
```

## Full Example
```rust
option Validate = Basic;

scope Gameplay {
  struct Entities {
    brand: string<100>,
    carName: string<100>,
    carId: u16,
    available: bool,
    dealers: u8,
    price: f64,
  }

  event CarsUpdateStruct {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: Entities,
  }

  event CarsTuple {
    From: Both,
    Type: Unreliable,
    Call: ManyAsync,
    Data: (u16, string<100>, bool),
  }

  function GetDealers {
    Yield: SingleSync,
    Data: (u16),
    Return: (u8, string<100>),
  }
}
```

## Entities Example (Current `schemas/entities.idl`)
```rust
struct Entities {
  brand: string,
  carName: string,
  carId: u16,
  available: boolean,
  dealers: u8,
  price: f64
}

event MyEvent {
  From: Client,
  Type: Reliable,
  Call: SingleSync,
  Data: Entities
}

function Ping {
  Yield: SingleSync,
  Data: (f64),
  Return: (f64),
}
```
