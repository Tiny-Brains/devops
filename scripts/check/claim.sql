-- The wave's claim, exactly as kalam/workflows/tb-wave-run.json issues it, for pgbench.
--
-- Bound values arrive as pgbench variables (`-D digest=...`), which substitute textually and carry
-- their own quotes -- pgbench has no :'var' form and no bind protocol here. Nothing else changed:
-- the same two MATERIALIZED CTEs, the same ORDER BY, the same
-- `FOR UPDATE ... SKIP LOCKED`, the same K. What is measured is the index probe and the row locks,
-- which is what a poll costs when it finds nothing and what it costs when it finds a wave.
--
-- ROLLED BACK, never committed. The point is the COST of a poll under N concurrent pollers, not the
-- draining of a queue: committing would empty it in the first second and measure an empty table for
-- the rest of the run. SKIP LOCKED still does its real work -- each client locks a different row and
-- releases it at the rollback -- so the contention is genuine.
BEGIN;
WITH first AS MATERIALIZED (
    SELECT m.id, m.preset
      FROM matches m
     WHERE m.status = 'pending' AND m.engine_digest = :digest
     ORDER BY (m.trial_version_id IS NOT NULL) DESC,
              EXISTS (SELECT 1 FROM match_seats s
                       WHERE s.match_id = m.id AND s.weights_hash = ANY (:resident::text[])) DESC,
              m.created_at, m.id
     LIMIT 1 FOR UPDATE SKIP LOCKED
), wave AS MATERIALIZED (
    SELECT m.id
      FROM matches m, first f
     WHERE m.status = 'pending' AND m.engine_digest = :digest AND m.preset = f.preset
       AND (m.id = f.id
            OR EXISTS (SELECT 1 FROM match_seats a
                         JOIN match_seats b ON b.weights_hash = a.weights_hash
                        WHERE a.match_id = f.id AND b.match_id = m.id))
     ORDER BY (m.id = f.id) DESC, (m.trial_version_id IS NOT NULL) DESC, m.created_at, m.id
     LIMIT 16 FOR UPDATE OF m SKIP LOCKED
)
UPDATE matches m
   SET status = 'claimed', claim_token = gen_random_uuid(),
       lease_expires_at = now() + 300 * interval '1 second'
  FROM wave WHERE m.id = wave.id;
ROLLBACK;
