# VLAN Diagram

```mermaid
flowchart LR

  WAN(((WAN)))

  subgraph Network
    MGMT((10 MGMT))
    HOME((20 HOME))
    GUEST((30 GUEST))
    ADU((31 ADU))
    IOT((40 IOT))
    GAME((41 GAME))
    SMRT((42 SMRT))
    DMZ((100 DMZ))
  end

  MGMT --> WAN
  MGMT --> MGMT

  HOME  --> HOME
  HOME --> WAN
  HOME --> MGMT
  HOME --> DMZ

  GUEST --> WAN
  GUEST -.-> MGMT

  ADU  --> ADU
  ADU --> WAN
  ADU -.-> MGMT

  IOT -.-> IOT
  IOT -.-> WAN

  GAME --o GAME
  GAME --> WAN

  SMRT --> SMRT
  SMRT -.-> MGMT

  DMZ --> DMZ
  DMZ --> WAN
  DMZ -.-> MGMT
  WAN ==> DMZ

  subgraph Legend
    direction LR
	src1[ ] -->|Full Access| snk1[ ]
	style src1 height:0px;
	style snk1 height:0px;
	src2[ ] -.->|Limited Access| snk2[ ]
	style src2 height:0px;
	style snk2 height:0px;
	src3[ ] --o|UPnP| snk3[ ]
	style src3 height:0px;
	style snk3 height:0px;
	src4[ ] ==>|Wireguard| snk4[ ]
	style src4 height:0px
	style snk4 height:0px;
  end
```
