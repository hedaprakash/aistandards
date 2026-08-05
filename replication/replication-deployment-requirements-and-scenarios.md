# Replication + Deployment: Behavior, Requirements & Caveats

### For Application / Deployment Team review and sign-off

---

## 1. Purpose

This document explains, scenario by scenario, what happens to the CHS
consolidation replication when the application or deployment team changes the
published tables during a deployment window — what is safe, what breaks, and
what the application team must do or avoid.

Please review Section 3 (what happens in each scenario) and confirm the
requirements in Section 4.

## 2. The setup, in plain language

- Several source servers (MPS01, MPS02, MPS03 today; possibly more later) each
  publish their `tblVehicleRecord` into one central table on CHS using SQL Server
  **transactional replication**. Data flows one way: **MPS (publisher) → CHS
  (subscriber).**
- CHS has one extra column the MPS servers do not have: an **IDENTITY column**.
  It gives every row a permanent, unique number and exists only on CHS.
- A downstream process, **TripBld**, reads CHS one row at a time in identity
  order and remembers which identity numbers it has already processed.
- Because of that, **the identity number of an existing row must never change.**
  If it changes, TripBld's tracking breaks. This is the single most important
  constraint on the whole design.
- Deployments are applied on the **MPS (publisher) side** and are **mostly column
  changes** (add / alter / drop column), only occasionally structural.

**Bottom line up front:** for the common case — column changes made on the
publisher with `ALTER TABLE` — replication carries the change to CHS on its own,
with no teardown, no reload, and no risk to identity. The disruptive path
(teardown and rebuild) is only needed for rare *structural* changes, and those
must be coordinated in advance.

**Critical for this topology (please read Section 3.1):** because several
publishers feed the *same* CHS table, a schema change must be propagated through
**one** designated publisher. Running the same `ALTER TABLE` on every publisher
will break replication — the change succeeds once and then fails on the others.

## 3. What happens in each scenario

| # | Scenario | What replication does | Teardown / rebuild needed? | Identity safe? | Application team must… |
|---|----------|-----------------------|----------------------------|----------------|------------------------|
| 1 | **Add a column** on MPS via `ALTER TABLE … ADD` | Propagates from **each** publisher — the first adds it to CHS, the rest fail (error 2705) | No | Yes | Apply via the **single-owner procedure** (§3.1); do not let every publisher propagate |
| 2 | **Alter a column** on MPS via `ALTER TABLE … ALTER COLUMN` | Propagates from each publisher; duplicates collide on CHS | No | Yes | Single-owner procedure (§3.1); ensure the type change is data-compatible so it doesn't fail at CHS |
| 3 | **Drop a column** on MPS via `ALTER TABLE … DROP COLUMN` | Propagates from each publisher (always, even with `replicate_ddl` off); duplicates collide | No | Yes | Single-owner procedure (§3.1); if the column is indexed on CHS, drop that index first |
| 4 | **Several column changes over a long window**, with replication paused | On resume, all changes and data replay in log order; nothing is lost | No (pause only) | Yes | Nothing special; DBA watches publisher log growth (see caveats) |
| 5 | **Structural change**: primary-key change, table rebuild, rename, key/identity change | Cannot carry it; publication/subscription must be dropped and recreated | **Yes** | Only if handled carefully (keep CHS data, re-attach without reload) | **Flag to DBA in advance** and coordinate a window; do not do ad hoc |
| 6 | **Any change made through the SSMS table designer** (even a "column" change) | The designer drops and recreates the table → structural → **breaks replication** | Yes / unplanned breakage | **No — high risk** | **Never use the table designer**; use T-SQL `ALTER TABLE` only |
| 7 | **Schema change applied directly on CHS** (subscriber), or to the identity column | Not expected; can desync the article and break the apply process | Possibly / breakage | **At risk** | Do not change schema on CHS directly; all changes go on MPS; never touch the identity column |
| 8 | **Stop replication for a deployment that does *not* change the published-table schema** | Pause the agents; changes queue in the publisher log and replay on resume | No (pause only) | Yes | Request a **pause**, not a teardown |

### 3.1 Applying the *same* schema change across all publishers (important)

Because all MPS publishers replicate into **one shared CHS table**, each
publication delivers its schema changes independently. If the same
`ALTER TABLE` is run on every publisher, the first one applies the change to CHS
successfully, and every other one then tries to repeat a change that is already
there — the distribution agent fails (e.g. "column names must be unique",
error 2705) and that subscription stalls.

**The change still has to be made on every publisher** (each keeps its own local
schema), but only **one** publication may carry it to CHS. The rest must be
prevented from propagating it:

- **Add column:** set `replicate_ddl = 0` on the non-owner publications before the
  change; add-column respects that flag and will not propagate from them.
- **Alter / drop column:** these propagate **regardless** of `replicate_ddl`, so
  turning the flag off is not enough. The DBA must handle the duplicates
  explicitly — for example, remove the column from the non-owner articles first,
  or remove the duplicate DDL commands in the distributor so they never reach CHS.

Practical effect for the application team: **submit each schema change once, and
let the DBA run it through the single designated publisher.** Do not run the same
change independently against all publishers expecting replication to de-duplicate
it — it will not.

## 4. Requirements for the application / deployment team to confirm

1. All schema changes to published tables are made **on the MPS publisher**, using
   **T-SQL `ALTER TABLE` statements only**.
2. **No** changes are made through the SSMS table designer or any tool that drops
   and recreates a table behind the scenes.
3. Column-level changes (add / alter / drop) are the standard path. **Any
   structural change** (primary-key change, rename, table rebuild, key or identity
   change) is **flagged to the DBA team in advance** so a coordinated window can be
   planned.
4. When dropping a column that may be indexed on CHS, the drop of the
   subscriber-side index is coordinated **first**.
5. **No** schema changes are made directly on CHS (the subscriber), and nothing
   touches the CHS identity column.
6. Schema changes are propagated to CHS through **one designated publisher only**
   (see Section 3.1). The same change is applied on every publisher for its local
   schema, but the application team submits it as a single coordinated change and
   does **not** run it independently against all publishers expecting replication
   to de-duplicate it. (Which publisher "owns" propagation, and the `replicate_ddl`
   settings behind it, are DBA-owned.)
7. For the rare structural-change window, the publisher side can **stop writes for
   the coordinated period** (or accept the agreed gap-handling). Confirm this is
   acceptable.
8. `ALTER COLUMN` type changes are **data-compatible** — they will not fail when
   converting existing rows at CHS.

## 5. Caveats and failure modes

- **Pause cost (Scenarios 4 and 8).** While replication is paused, the publisher's
  transaction log cannot shrink and will grow for the length of the window — the
  MPS servers need disk headroom. Very long pauses also risk the distributor's
  default **72-hour** cleanup removing a backlog; the DBA monitors this.
- **Re-attach trusts you (Scenario 5).** The "keep the data and re-attach without
  reloading" method does **not** verify that CHS actually matches the publishers —
  it assumes they are in sync. Any drift at the moment of re-attach is **not
  detected**; replication silently diverges and later updates or deletes can start
  failing. That is why the structural path must fully drain and verify before
  re-attaching.
- **Incompatible `ALTER COLUMN` (Scenario 2).** If a column type change cannot
  convert existing rows at CHS, the replicated command fails and replication
  stalls until it is resolved.
- **Version syntax.** The DDL must use syntax supported by the SQL Server version
  running on CHS.
- **Temporal tables.** If `tblVehicleRecord` is (or becomes) system-versioned,
  column changes require turning system-versioning off and back on — a special
  handling case, not the normal flow.
- **The GUI trap (Scenario 6), restated because it is the most common mistake.** A
  change that looks small can silently become a full table rebuild when done
  through a designer, which breaks replication even though it was "just a column."

## 6. Open items to confirm before this is final

- Confirm the current `replicate_ddl` setting on each publication (expected: on).
- Confirm whether `tblVehicleRecord` is, or will become, a temporal table.
- Confirm the behavior if an Availability Group failover happens mid-window
  (publisher redirection), if the topology uses AGs.
- Confirm that the DBA teardown/rebuild procedure used for structural changes
  **keeps the CHS data (does not reload it)**, so identity survives.
