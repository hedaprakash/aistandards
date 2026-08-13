Goal for every scenario below: the existing VehicleRecordRecID values on the shared CHS table must not be reset. After each rebuild, compare the CHS identity values before and after, and confirm new rows from each publisher continue from the next free identity.

1. Initial setup (bootstrap) — one-time build, not a deployment window.
Before: pre-create the subscriber table with the published columns only.
Action: run the snapshot at a matching column count.
After: add the identity column to the subscriber.

2. Pause & Resume
Before: pause the log-reader and distribution agents. No write freeze, no drain.
During: deployment runs on the MPS side.
After: resume both agents and let the queued changes replay.

3. Incremental rebuild
Before: freeze publisher writes, stop the log-reader, wait until undelivered = 0, then stop the distribution agent. Tear down subscription, publication, log-reader and distributor.
During: deployment runs.
After: rebuild the distributor, recreate publication and subscription, re-attach with replication support only, release the write freeze.

4. Schema-change rebuild
Before: freeze publisher writes, drain to undelivered = 0, drop the publications.
During: apply the column change on every publisher and on the subscriber, with replicate_ddl = 0.
After: recreate the publication and article, re-attach with no snapshot, release the write freeze.

5. Add publisher — no deployment window on the existing publishers; they stay live throughout.
Before: confirm the new publisher's column count matches the subscriber.
Action: stand up the new publisher with its own distributor and publication.
After: attach the subscription with replication support only.

6. Repeat full reload (re-snapshot)
Before: freeze writes and drain.
Action: re-run the snapshot against the existing subscriber.
After: check the effect on the existing identity values.