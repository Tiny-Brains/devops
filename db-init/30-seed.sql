-- One game, so the leaderboard and /v1/games have something to answer with.
-- Everything else -- models, matches, ratings -- is the game manager's to write.
INSERT INTO games (slug, name) VALUES ('ants', 'Ants') ON CONFLICT DO NOTHING;
