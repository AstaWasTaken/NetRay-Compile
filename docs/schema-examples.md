---
title: Schema Examples
layout: default
nav_order: 10
---

## Minimal Event
```idl
event reliable Ping(u16 id);
```

## Block Event with Struct Payload
```idl
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
```idl
event Position {
  From: Both,
  Type: Unreliable,
  Call: ManyAsync,
  Data: (u16, f32, f32),
}
```

## Function Request/Response
```idl
function GetDealers {
  Yield: SingleSync,
  Data: (u16),
  Return: (u8, string<100>),
}
```

## Nested Scopes
```idl
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
```idl
option Validate = Full;
option TypeBranding = On;
option DecodeStruct = Table;
```

## Passthrough Example
```idl
function InspectPlayer {
  Data: (passthrough Player),
  Return: (string<32>),
}
```

## Full Example
```idl
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
