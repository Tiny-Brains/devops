-- jodi's demand view, VERBATIM out of tb-pair-run.json, with the scaling arithmetic on top.
-- `pool`, `played` and `depth` go unreferenced here and are kept anyway: the point of this file is
-- that what runs is what pair computes, and an unreferenced CTE is not executed.
WITH live AS ( SELECT id FROM seasons WHERE game_id = ($1)::uuid AND closed_at IS NULL ), v AS ( SELECT md.id AS model_id, md.weight_class, u.role, max(r.sigma) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS sigma, min(r.matches_played) FILTER (WHERE r.ladder = 'open' OR reach.n > 0) AS played FROM models md JOIN users u ON u.id = md.owner_id JOIN live ON live.id = md.season_id LEFT JOIN ratings r ON r.model_id = md.id LEFT JOIN LATERAL ( SELECT count(*) AS n FROM models o WHERE o.season_id = md.season_id AND o.status = 'active' AND o.weight_class = md.weight_class AND o.id <> md.id ) reach ON true WHERE md.status = 'active' GROUP BY md.id, md.weight_class, u.role ), f AS ( SELECT s.model_id, count(*) AS in_flight FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.game_id = ($1)::uuid AND m.status IN ('pending', 'claimed', 'running', 'finished') GROUP BY s.model_id ), w AS ( SELECT v.model_id, v.weight_class, v.role, v.sigma, v.played, coalesce(f.in_flight, 0) AS in_flight, CASE WHEN v.role = 'baseline' THEN 'baseline' WHEN v.played < ($2)::int THEN 'placement' WHEN v.sigma > ($4)::float8 THEN 'unsettled' ELSE 'settled' END AS state, CASE WHEN v.role = 'baseline' THEN 0 WHEN v.played < ($2)::int THEN ($2)::int WHEN v.sigma > ($4)::float8 THEN ($3)::int ELSE 0 END AS cap FROM v LEFT JOIN f ON f.model_id = v.model_id ), wants AS ( SELECT model_id, weight_class, role, state, sigma, played, in_flight, greatest(cap - in_flight, 0) AS want FROM w ), pool AS ( SELECT md.id AS model_id, md.weight_class, u.role, (SELECT json_agg(json_build_object('ladder', r.ladder, 'mu', r.mu, 'sigma', r.sigma) ORDER BY r.ladder) FROM ratings r WHERE r.model_id = md.id) AS ratings FROM models md JOIN users u ON u.id = md.owner_id JOIN live ON live.id = md.season_id WHERE md.status = 'active' ), played AS ( SELECT s.model_id, m.preset, count(*) AS n FROM match_seats s JOIN matches m ON m.id = s.match_id WHERE m.game_id = ($1)::uuid AND m.status IN ('finished', 'rated') GROUP BY s.model_id, m.preset ), depth AS ( SELECT count(*) AS pending FROM matches WHERE game_id = ($1)::uuid AND status = 'pending' ),
q AS (
    SELECT count(*) FILTER (WHERE m.status = 'pending')                        AS depth,
           count(*) FILTER (WHERE m.status IN ('pending','claimed','running')) AS outstanding,
           coalesce(extract(epoch FROM now() -
                min(m.created_at) FILTER (WHERE m.status = 'pending')), 0)     AS oldest_pending_s
      FROM matches m
      JOIN seasons s ON s.id = m.season_id AND s.closed_at IS NULL
      JOIN games   g ON g.id = m.game_id  AND g.id = ($1)::uuid
     WHERE m.engine_digest = s.engine_digest
), total AS (
    SELECT coalesce(sum(want), 0) AS want FROM wants
)
SELECT total.want, q.depth, q.outstanding, round(q.oldest_pending_s)::int AS oldest_pending_s,
       least(($6)::int, greatest(($5)::int,
           ceil((total.want + q.outstanding)::numeric / ($7)::int)::int
         + CASE WHEN q.oldest_pending_s > ($8)::int THEN 1 ELSE 0 END
       )) AS replicas
  FROM total, q
