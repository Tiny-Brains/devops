-- Seed: the one game, its engine digest placeholder, and the three baselines.
--
-- Runs once, on first initialisation of the volume, after 0001_init.sql and 0002_sessions.sql.
-- Re-running it means `docker compose down -v`. Written to be idempotent anyway, so it can also
-- be applied by hand to a scratch database.
--
-- Everything a competitor owns -- their models, matches and ratings -- is written by Soma, Jodi
-- and Kalam. Nothing below is.

-- ---------------------------------------------------------------------- the game

-- active_engine_digest is a placeholder, and it is deliberately a loud one. Pair refuses to
-- insert a match while it is NULL, and Kalam claims only rows whose engine_digest equals it, so
-- until the real engine exists this value's only job is to be present and obviously wrong. The
-- deploy step overwrites it once the replicas carrying a real engine exist (finding 5 option A):
--
--   UPDATE games SET active_engine_digest = 'sha256:<the plugin's digest>' WHERE slug = 'ants';
INSERT INTO games (slug, name, active_engine_digest)
VALUES ('ants', 'Ants', 'sha256:0000000000000000000000000000000000000000000000000000000000000000')
ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------- season 1

-- jodi/docs/rating-and-seasons.md: every version belongs to a season, so a game needs one before anything can be
-- submitted. Season 1 of a dev stack opens now and takes submissions for a year; it pins the
-- placeholder digest, which the loader's patch overwrites on the first `up` exactly as it does on
-- games. Later seasons are the admin's (POST /v1/games/{game}/seasons) and carry the baselines.
INSERT INTO seasons (game_id, number, engine_digest, submissions_open_at, submissions_close_at)
SELECT g.id, 1, g.active_engine_digest, now(), now() + interval '1 year'
  FROM games g
 WHERE g.slug = 'ants'
   AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = g.id);

-- ----------------------------------------------------------------- the baselines

-- Baselines are competitors (the platform design §7): each one is a user, so that three of them can be told
-- apart on a leaderboard where an entry is displayed as its owner's handle. They never sign in,
-- which is why github_id is null and why users_human_has_github_id exempts the role.
--
-- They exist here because nothing can have a trial opponent until they do: pair's trial insert
-- (jodi/docs/design.md §6.4) seats a verified candidate against `status = 'active'` baseline of its own
-- class where one exists, and against any baseline otherwise.
INSERT INTO users (handle, role) VALUES
    ('baseline-random', 'baseline'),
    ('baseline-greedy', 'baseline'),
    ('baseline-strong', 'baseline')
ON CONFLICT (handle) DO NOTHING;

-- One version each, 'active', so the trial insert can find them.
--
-- The hashes are placeholders. The baselines' real releases are P3's -- they are submitted as
-- ordinary releases with adapters in the axon/docs/design.md dialect, and admission fills these columns for
-- real. Until then the rows exist to make the *pairing* path testable, not the playing one: a
-- match seating one of these would be claimed by Kalam and failed with HASH_MISMATCH, which is
-- itself one of the failure walks P5 has to prove. `adapter` is left null on purpose --
-- models_adapter_matches_hash would otherwise demand the text and the hash agree, and there is no
-- honest text to put there yet.
--
-- All three are 'nano': they are rule-based policies with no weights to speak of. A candidate in
-- a larger class therefore matches no baseline on class and falls through to the "any baseline,
-- fewest in flight" arm of the trial insert, which is the intended behaviour.
INSERT INTO models (owner_id, game_id, season_id, version, repo, release_tag, commit_sha, status,
                    weight_class, size_bytes, param_count, flops_estimate,
                    weights_hash, adapter_hash, evaluator_digest)
SELECT u.id, g.id, s.id, 1,
       'tinybrains/ants-baselines', 'v0-placeholder', NULL, 'active',
       'nano', 0, 0, 0,
       'sha256:placeholder-' || u.handle,
       'sha256:placeholder-' || u.handle || '-adapter',
       'placeholder'
  FROM users u
  CROSS JOIN games g
  JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL      -- the live season: season 1
 WHERE u.role = 'baseline' AND g.slug = 'ants'
   AND NOT EXISTS (SELECT 1 FROM models m WHERE m.owner_id = u.id AND m.game_id = g.id);

-- Two rating rows each -- their class ladder and open -- at the prior, so that a baseline is
-- rated by the matches other people want (jodi/docs/design.md §4) rather than being an unrated void the
-- fold silently drops. The numbers are jodi/docs/design.md §9's provisional prior_mu and prior_sigma;
-- they must stay equal to the [vars] of the same name, since a baseline's first fold reads these
-- as its own prior.
INSERT INTO ratings (model_id, ladder, mu, sigma)
SELECT m.id, l.ladder, 25.0, 8.333333333333334
  FROM models m
  JOIN users u ON u.id = m.owner_id AND u.role = 'baseline'
  CROSS JOIN LATERAL (VALUES (m.weight_class), ('open'::ladder)) AS l (ladder)
ON CONFLICT (model_id, ladder) DO NOTHING;

-- The seed event, seq 0, exactly as promotion writes one. Without it the first fold of a
-- baseline's match would start a chain with no origin, and the audit in 01-verify -- every event
-- beginning where the previous one on its ladder ended -- would have nothing to anchor on.
-- seq 0 carries no match and no `before`, which is what rating_events_seed_shape requires.
INSERT INTO rating_events (model_id, ladder, seq, mu_after, sigma_after)
SELECT r.model_id, r.ladder, 0, r.mu, r.sigma
  FROM ratings r
  JOIN models m ON m.id = r.model_id
  JOIN users u ON u.id = m.owner_id AND u.role = 'baseline'
ON CONFLICT (model_id, ladder, seq) DO NOTHING;
