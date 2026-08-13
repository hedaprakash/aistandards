Title: Investigate full rebuild vs. incremental rebuild vs. schema change rebuild for MPS → CHS replication

Description

Investigate and define how a full rebuild, an incremental rebuild, and a schema change rebuild each play out for the MPS → CHS consolidation replication, without losing the CHS identity values that downstream processing (TripBld) depends on.

Multiple MPS publishers replicate tblVehicleRecord into a single shared CHS table, which carries an IDENTITY column that must stay stable. Replication is stopped for deployment/maintenance windows; deployments run on the MPS (publisher) side and can require schema changes.

Questions to work through:

Full rebuild — how a drop-and-recreate affects existing CHS identity values, and what's lost if publishers stay live during the window.
Incremental rebuild — how to re-establish replication without reloading the CHS data so identity values are preserved, and the conditions that make it safe.
Schema change rebuild — how publisher-side schema changes behave, including the multi-publisher case where the same DDL is applied across all publishers into one subscriber table, and what procedure is needed.
When each of the three applies during a deployment window (including pause vs. rebuild).
How to simulate/test each path to confirm identity stays intact.

Acceptance Criteria

Each of the three rebuild types (full, incremental, schema change) is documented, including when it applies and how identity is affected.
A recommended approach per type is captured, with reasoning.
The multi-publisher schema change behavior and handling is documented.
A test/simulation plan exists to validate identity preservation across the rebuild types.
Findings are captured in a document suitable for application-team review.


