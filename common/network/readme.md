# VLAN Diagram

```mermaid
flowchart LR
  subgraph Legend
    direction LR
	src1[ ] -->|Full Access| snk1[ ]
	style src1 height:0px;
	style snk1 height:0px;
	src2[ ] -.->|Limited Access| snk2[ ]
	style src2 height:0px;
	style snk2 height:0px;	
  end

  WAN(((WAN)))

  MGMT((10 MGMT)) --> MGMT
  MGMT --> WAN

  HOME((20 HOME)) --> HOME
  HOME --> WAN
  HOME --> MGMT
  HOME --> DMZ

  GUEST((30 GUEST)) --> GUEST
  GUEST --> WAN
  GUEST -.-> MGMT
  GUEST --> DMZ

  ADU((31 ADU)) --> ADU
  ADU --> WAN
  ADU -.-> MGMT
  
  IOT((40 IOT)) -.-> IOT
  IOT -.-> WAN

  GAME((41 GAME)) --> GAME
  GAME --> WAN

  SMRT((42 SMRT)) --> SMRT
  SMRT((42 SMRT)) -.-> MGMT
  
  DMZ((100 DMZ)) --> DMZ
  DMZ -.-> MGMT
  DMZ --> WAN
  ```
