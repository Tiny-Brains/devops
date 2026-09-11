-- Seed: the one game, its engine-digest placeholder, season 1, and the three baselines.
--
-- Runs once, on first initialisation of the volume, after the migrations. Idempotent anyway, so it
-- can be applied by hand to a scratch database. Everything a competitor owns is written by Soma,
-- Jodi and Kalam; nothing below is.

-- ---------------------------------------------------------------------- the game

-- A deliberately loud placeholder. Pair refuses to insert a match while it is NULL and Kalam
-- claims only rows matching it, so until a real engine exists this value's only job is to be
-- present and obviously wrong. `loader setup` overwrites it.
INSERT INTO games (slug, name, active_engine_digest)
VALUES ('ants', 'Ants', 'sha256:0000000000000000000000000000000000000000000000000000000000000000')
ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------- season 1

-- Every version belongs to a season, so a game needs one before anything can be submitted. This
-- one opens now and takes submissions for a year, pinning the placeholder digest that the loader
-- overwrites on the first `up`. Later seasons are the admin's.
--
-- IT DECLARES NO RULES, and the empty document is the open contest: every block is optional and
-- absent means no limit, except `repo`, whose `enabled` defaults true so a season silent about
-- ownership is not one where anyone may enter anyone's repository.
--
-- It used to name `Tiny-Brains` under repo.allow_orgs, so that the baselines -- three users sharing
-- one repository none of them owns -- were describable by the same rule a competitor is admitted
-- by. They never needed it: they are INSERTed below and never reach soma-models-create, so the rule
-- bought nothing and cost a great deal. An organisation allowance is an allowance to everyone
-- unless the season also names a cohort, which meant any signed-in competitor could enter
-- `Tiny-Brains/ants-baselines` and submit the platform's own baseline release as their own model.
-- season_rules_ok() now refuses the key without `participants`; this line is why.
INSERT INTO seasons (game_id, number, engine_digest, submissions_open_at, submissions_close_at)
SELECT g.id, 1, g.active_engine_digest, now(), now() + interval '1 year'
  FROM games g
 WHERE g.slug = 'ants'
   AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = g.id);

-- ----------------------------------------------------------------- the baselines

-- Baselines are competitors: each is a user, so they can be told apart on a leaderboard that
-- displays an entry as its owner's handle. They never sign in, which is why github_id is null.
-- Three users, three ENTRIES, one shared repository -- which is legal because these rows carry no
-- owner_github_id, and models_repo_uniq is partial on it. Nothing vouched for them: they were
-- INSERTed here rather than created through soma-models-create, which is the only thing that asks
-- GitHub who owns a repository.
-- They exist because nothing has a trial opponent until they do.
--
-- ONE ROW PER ARTIFACT IN `ants-baselines/models/`, and the handle is `baseline.<directory>`, which
-- is what `scripts/dev/seed-baselines.sh` matches on. THE DOT IS THE POINT: a GitHub login is
-- [A-Za-z0-9-], so `baseline.` is a namespace GitHub cannot mint, and users_baseline_handle_reserved
-- requires it. Under the old `baseline-` spelling a real account whose login happened to match --
-- `baseline-nano-bc` was a perfectly mintable login -- could never sign in at all.
--
-- The class must be the class the artifact actually measures into: `ratings` and `rating_events`
-- are keyed by ladder and a ladder IS a weight class, so a baseline cannot be moved between them
-- later -- the seeder checks and refuses.
--
-- Adding a baseline is a line here and a re-run of the seeder. The seeder can also create one this
-- database has never seen, so an existing stack converges without `docker compose down -v`.
-- A temp table for the session, NOT `ON COMMIT DROP`: this file runs statement by statement under
-- autocommit, so an on-commit table would be gone before the next statement could read it.
CREATE TEMP TABLE baseline_roster (handle text, weight_class ladder);
INSERT INTO baseline_roster VALUES
    ('baseline.nano-bc',       'nano'),
    ('baseline.micro-bc',      'micro'),
    -- The method column's control: same class, same data, same parameter count as micro-bc, and no
    -- receptive field at all. It is a weak player on purpose and belongs on the ladder for the same
    -- reason it exists -- the comparison is the artifact.
    ('baseline.micro-percell', 'micro');

-- `ON CONFLICT (lower(handle))`, the expression and not the column: users_handle_uniq is an
-- expression index, and it is only a valid arbiter written the way it was declared.
INSERT INTO users (handle, role) SELECT handle, 'baseline' FROM baseline_roster
ON CONFLICT (lower(handle)) DO NOTHING;

-- One version each, 'active', so the trial insert can find them. The hashes are placeholders: a
-- volume initialises long before any model file exists, so these rows make the PAIRING path
-- testable and not the playing one -- a match seating one fails at the residency barrier, because
-- axon refuses a hash that is not 64 hex characters. scripts/dev/seed-baselines.sh replaces them
-- with the real bytes and the real measurements.
--
-- `adapter` is null on purpose: models_adapter_matches_hash would otherwise demand the text and the
-- hash agree, and there is no honest text yet.
-- One ENTRY per baseline, named for its artifact directory. The name is what tells three models
-- of one repository apart on a ladder, and `micro-percell` is on it for exactly that reason.
INSERT INTO models (owner_id, game_id, name, repo)
SELECT u.id, g.id, substring(b.handle from 'baseline\.(.*)'), 'Tiny-Brains/ants-baselines'
  FROM baseline_roster b
  JOIN users u ON u.handle = b.handle
  CROSS JOIN games g
 WHERE g.slug = 'ants'
   AND NOT EXISTS (SELECT 1 FROM models m WHERE m.owner_id = u.id AND m.game_id = g.id);

INSERT INTO model_versions (model_id, game_id, season_id, version, release_tag, commit_sha, status,
                            weight_class, size_bytes, param_count, infer_us,
                            weights_hash, adapter_hash, evaluator_digest)
SELECT e.id, e.game_id, s.id, 1,
       'v0-placeholder', NULL, 'active',
       b.weight_class, 0, 0, 0,
       'sha256:placeholder-' || u.handle,
       'sha256:placeholder-' || u.handle || '-adapter',
       'placeholder'
  FROM baseline_roster b
  JOIN users u  ON u.handle = b.handle
  JOIN models e ON e.owner_id = u.id
  JOIN games g  ON g.id = e.game_id AND g.slug = 'ants'
  JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL      -- the live season: season 1
 WHERE NOT EXISTS (SELECT 1 FROM model_versions v WHERE v.model_id = e.id);

-- Two rating rows each -- class ladder and open -- at the prior, so a baseline starts in placement
-- like any version (decision 28) rather than being an unrated void the fold silently drops.
-- These MUST stay equal to [vars] prior_mu / prior_sigma; check/configs.sh asserts it.
INSERT INTO ratings (version_id, ladder, mu, sigma)
SELECT v.id, l.ladder, 25.0, 8.333333333333334
  FROM model_versions v
  JOIN models e ON e.id = v.model_id
  JOIN users u ON u.id = e.owner_id AND u.role = 'baseline'
  CROSS JOIN LATERAL (VALUES (v.weight_class), ('open'::ladder)) AS l (ladder)
ON CONFLICT (version_id, ladder) DO NOTHING;

-- seq 0, exactly as promotion writes one. Without it the first fold starts a chain with no origin
-- and the audit has nothing to anchor on. It carries no match and no `before`, as
-- rating_events_seed_shape requires.
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT r.version_id, r.ladder, 0, r.mu, r.sigma
  FROM ratings r
  JOIN model_versions v ON v.id = r.version_id
  JOIN models e ON e.id = v.model_id
  JOIN users u ON u.id = e.owner_id AND u.role = 'baseline'
ON CONFLICT (version_id, ladder, seq) DO NOTHING;
