-- =====================================================================
-- supabase_seed_teams.sql
-- =====================================================================
-- Backfill of public.teams from the bundled iOS TeamData.swift roster.
-- 124 rows total: NFL 32, NBA 30, MLB 30, NHL 32.
--
-- Every `id` here was precomputed in Python using the exact same
-- algorithm iOS uses for `SportsTeam.stableID(league:shortName:)`
-- (TeamData.swift:71–85): SHA-256 of "<league>_<shortName>",
-- truncated to 16 bytes, with v5-shape version + RFC 4122 variant
-- bits set. Those UUIDs are bit-identical to:
--
--   • the IDs every iPhone running JUMBO computes for the same team
--   • the home_team_id / away_team_id values already stored in
--     public.games by supabase_seed_test_games.sql
--
-- so this backfill makes the 5 seeded test games' team references
-- resolve to real public.teams rows the moment it runs. (Verified
-- spot-checks: KC c112d5cd…, BAL 22780759…, GB cd8b1e34…, LAL
-- caa3a5d4…, BOS 87b616fa…, GSW 874945b4… all match the seed file.)
--
-- Idempotent:
--   ON CONFLICT (league, abbreviation) DO UPDATE
-- so re-running this seed updates city/name/colors in place rather
-- than creating duplicates. No DELETEs.
--
-- Column mapping notes (TeamData.swift → public.teams):
--   • SportsTeam.name           → name           (e.g. "Bills")
--   • SportsTeam.shortName      → short_name AND abbreviation
--                                 — iOS uses the 3-letter code as
--                                 both today; the schema has both
--                                 columns so a future migration can
--                                 differentiate (e.g. short_name =
--                                 "Bills", abbreviation = "BUF")
--                                 without breaking the contract.
--   • SportsTeam.city           → city
--   • SportsTeam.league         → league
--   • SportsTeam.primaryColorHex   → primary_color
--   • SportsTeam.secondaryColorHex → secondary_color
--
-- Prerequisite: supabase_migration_teams.sql must have been run.
-- =====================================================================

INSERT INTO public.teams (
    id, league, city, name, short_name, abbreviation, primary_color, secondary_color
) VALUES
-- NFL (32)
    ('11994c05-dd06-594a-b2f7-e44200c48021', 'nfl', 'Buffalo', 'Bills', 'BUF', 'BUF', '#00338D', '#C60C30'),
    ('932c5748-6f9e-58d1-bd73-d977c83353c0', 'nfl', 'Miami', 'Dolphins', 'MIA', 'MIA', '#008E97', '#FC4C02'),
    ('14e834e7-c90f-5833-8432-8f44540c370b', 'nfl', 'New England', 'Patriots', 'NE', 'NE', '#002244', '#C60C30'),
    ('018dee72-6d20-53cb-bce6-5b505b3a9210', 'nfl', 'New York', 'Jets', 'NYJ', 'NYJ', '#125740', '#FFFFFF'),
    ('22780759-f816-5ee7-9559-65bbbbc21638', 'nfl', 'Baltimore', 'Ravens', 'BAL', 'BAL', '#241773', '#9E7C0C'),
    ('4bb02b9e-4ee2-57b0-bfae-eb5692126ffe', 'nfl', 'Cincinnati', 'Bengals', 'CIN', 'CIN', '#FB4F14', '#000000'),
    ('d37b36b3-dda2-5a59-ab14-b4efcf02753b', 'nfl', 'Cleveland', 'Browns', 'CLE', 'CLE', '#311D00', '#FF3C00'),
    ('b4619367-b7a7-5af3-ad63-63ccff590e02', 'nfl', 'Pittsburgh', 'Steelers', 'PIT', 'PIT', '#FFB612', '#101820'),
    ('d60de6a3-b7d1-5541-afda-eb4ee63eedc5', 'nfl', 'Houston', 'Texans', 'HOU', 'HOU', '#03202F', '#A71930'),
    ('d0aaa486-6dd7-5965-b782-bbf133512dd5', 'nfl', 'Indianapolis', 'Colts', 'IND', 'IND', '#002C5F', '#A2AAAD'),
    ('52493f6e-e20c-5f51-81df-2b3a2389f587', 'nfl', 'Jacksonville', 'Jaguars', 'JAX', 'JAX', '#006778', '#D7A22A'),
    ('654615cb-5cfa-5923-b53e-97a76f43aac9', 'nfl', 'Tennessee', 'Titans', 'TEN', 'TEN', '#0C2340', '#4B92DB'),
    ('fd15a67d-c95e-5e91-a838-548c809258db', 'nfl', 'Denver', 'Broncos', 'DEN', 'DEN', '#FB4F14', '#002244'),
    ('c112d5cd-de2f-5deb-83c0-436709075975', 'nfl', 'Kansas City', 'Chiefs', 'KC', 'KC', '#E31837', '#FFB81C'),
    ('5db656d5-b847-5aba-b9c9-4123749b904d', 'nfl', 'Las Vegas', 'Raiders', 'LV', 'LV', '#000000', '#A5ACAF'),
    ('6d11c9b4-8791-5b1c-9dc6-bf4d58f1dae5', 'nfl', 'Los Angeles', 'Chargers', 'LAC', 'LAC', '#0080C6', '#FFC20E'),
    ('250d2fad-d7ab-5733-bc88-92f18002094e', 'nfl', 'Dallas', 'Cowboys', 'DAL', 'DAL', '#003594', '#869397'),
    ('d1f84481-ce21-50c5-89a6-d1ae42347614', 'nfl', 'New York', 'Giants', 'NYG', 'NYG', '#0B2265', '#A71930'),
    ('21b63854-e92d-5364-9871-e0c65299083e', 'nfl', 'Philadelphia', 'Eagles', 'PHI', 'PHI', '#004C54', '#A5ACAF'),
    ('bbe8fe9d-aa8b-51de-b24f-82bd530ac503', 'nfl', 'Washington', 'Commanders', 'WAS', 'WAS', '#5A1414', '#FFB612'),
    ('88ce09dc-0da0-545e-ba29-aa82e71f654e', 'nfl', 'Chicago', 'Bears', 'CHI', 'CHI', '#0B162A', '#C83803'),
    ('e9479cf9-7bd1-510f-bea3-b7101401e5c0', 'nfl', 'Detroit', 'Lions', 'DET', 'DET', '#0076B6', '#B0B7BC'),
    ('cd8b1e34-d36c-5103-a828-b52a055b6410', 'nfl', 'Green Bay', 'Packers', 'GB', 'GB', '#203731', '#FFB612'),
    ('045f6330-ccae-501c-a709-2d09145e55f1', 'nfl', 'Minnesota', 'Vikings', 'MIN', 'MIN', '#4F2683', '#FFC62F'),
    ('9d5a4083-76b7-520d-bebf-105047a4a2d8', 'nfl', 'Atlanta', 'Falcons', 'ATL', 'ATL', '#A71930', '#000000'),
    ('04b20671-5f7b-5ee8-8b1d-02793fcc75c8', 'nfl', 'Carolina', 'Panthers', 'CAR', 'CAR', '#0085CA', '#101820'),
    ('bb957862-0feb-527a-8cf7-e5489b50b80b', 'nfl', 'New Orleans', 'Saints', 'NO', 'NO', '#D3BC8D', '#101820'),
    ('4933e099-5f2b-5c67-a7cb-ed36b2307c3f', 'nfl', 'Tampa Bay', 'Buccaneers', 'TB', 'TB', '#D50A0A', '#34302B'),
    ('2bf4b498-d54e-5476-b2cc-db6bed9d63ac', 'nfl', 'Arizona', 'Cardinals', 'ARI', 'ARI', '#97233F', '#000000'),
    ('ad4379c2-213a-50f8-af10-bdd229d0bc76', 'nfl', 'Los Angeles', 'Rams', 'LAR', 'LAR', '#003594', '#FFA300'),
    ('e30be271-101d-53de-9100-b2fbd6edc251', 'nfl', 'San Francisco', '49ers', 'SF', 'SF', '#AA0000', '#B3995D'),
    ('1ebc7038-200c-55d4-ab32-603156c6f50f', 'nfl', 'Seattle', 'Seahawks', 'SEA', 'SEA', '#002244', '#69BE28'),
-- NBA (30)
    ('87b616fa-f2a0-5466-a7ea-a6a5d36f51b8', 'nba', 'Boston', 'Celtics', 'BOS', 'BOS', '#007A33', '#BA9653'),
    ('59612c15-88e3-502b-84cf-0c1c6d88d64a', 'nba', 'Brooklyn', 'Nets', 'BKN', 'BKN', '#000000', '#FFFFFF'),
    ('4c9cbfa5-a846-50ae-b43a-120ec02b6d45', 'nba', 'New York', 'Knicks', 'NYK', 'NYK', '#006BB6', '#F58426'),
    ('5b0e5c30-9989-576c-ada6-2e4e84d2a3ca', 'nba', 'Philadelphia', '76ers', 'PHI', 'PHI', '#006BB6', '#ED174C'),
    ('9f297645-b0ef-50cc-abfe-7b65562f9782', 'nba', 'Toronto', 'Raptors', 'TOR', 'TOR', '#CE1141', '#000000'),
    ('ac58ffa5-17b1-5386-a3cc-a9731b70b9fb', 'nba', 'Chicago', 'Bulls', 'CHI', 'CHI', '#CE1141', '#000000'),
    ('96a5b630-fd8a-5eb9-bcff-ced95a171ecb', 'nba', 'Cleveland', 'Cavaliers', 'CLE', 'CLE', '#860038', '#FDBB30'),
    ('553f7bc7-e256-57a5-8722-9968e7698461', 'nba', 'Detroit', 'Pistons', 'DET', 'DET', '#C8102E', '#1D42BA'),
    ('26d2427f-cf29-5499-8593-4ad74b1e2d2b', 'nba', 'Indiana', 'Pacers', 'IND', 'IND', '#002D62', '#FDBB30'),
    ('899af24b-0bd1-5b6c-9a72-94087aba78da', 'nba', 'Milwaukee', 'Bucks', 'MIL', 'MIL', '#00471B', '#EEE1C6'),
    ('ac76f74d-082d-55ec-bc9b-5907b2d55b0d', 'nba', 'Atlanta', 'Hawks', 'ATL', 'ATL', '#E03A3E', '#C1D32F'),
    ('2052480e-1e9b-5c16-a378-89c0c4a65f7f', 'nba', 'Charlotte', 'Hornets', 'CHA', 'CHA', '#1D1160', '#00788C'),
    ('c33af5d9-1884-5261-a8ac-39dc5668aca3', 'nba', 'Miami', 'Heat', 'MIA', 'MIA', '#98002E', '#F9A01B'),
    ('ddb4fd7f-8e75-50fc-b719-30be503ef9bb', 'nba', 'Orlando', 'Magic', 'ORL', 'ORL', '#0077C0', '#C4CED4'),
    ('52654d39-6578-5da1-b09a-6a11086cff36', 'nba', 'Washington', 'Wizards', 'WAS', 'WAS', '#002B5C', '#E31837'),
    ('1f912870-8efd-55d6-86db-df661344bb32', 'nba', 'Denver', 'Nuggets', 'DEN', 'DEN', '#0E2240', '#FEC524'),
    ('987080cf-0edf-54f2-9e78-d6526ab43858', 'nba', 'Minnesota', 'Timberwolves', 'MIN', 'MIN', '#0C2340', '#236192'),
    ('87a9013a-5fb0-5e12-97ae-8bd4aa41613a', 'nba', 'Oklahoma City', 'Thunder', 'OKC', 'OKC', '#007AC1', '#EF3B24'),
    ('58db9beb-20cf-5a7a-8eee-b1f6368b5005', 'nba', 'Portland', 'Trail Blazers', 'POR', 'POR', '#E03A3E', '#000000'),
    ('20c8b172-9b87-5fd6-9237-bfedfd8b6752', 'nba', 'Utah', 'Jazz', 'UTA', 'UTA', '#002B5C', '#00471B'),
    ('874945b4-cf49-5905-b0c1-3696573117ca', 'nba', 'Golden State', 'Warriors', 'GSW', 'GSW', '#1D428A', '#FFC72C'),
    ('e07e7287-5cd4-52cc-b6dd-a145863c0ac4', 'nba', 'Los Angeles', 'Clippers', 'LAC', 'LAC', '#C8102E', '#1D428A'),
    ('caa3a5d4-9bc7-5e6d-b922-4a040fa569dc', 'nba', 'Los Angeles', 'Lakers', 'LAL', 'LAL', '#552583', '#FDB927'),
    ('694fc072-d7da-568d-b7c6-acce2b1c2a4e', 'nba', 'Phoenix', 'Suns', 'PHX', 'PHX', '#1D1160', '#E56020'),
    ('ae86d8d8-6cb0-5e5e-a1bd-45e7353bcd80', 'nba', 'Sacramento', 'Kings', 'SAC', 'SAC', '#5A2D81', '#63727A'),
    ('aabac732-8086-51de-9c74-845761ee3bc2', 'nba', 'Dallas', 'Mavericks', 'DAL', 'DAL', '#00538C', '#002B5E'),
    ('6eedbc66-313f-52f9-b29d-20ad47eda5d0', 'nba', 'Houston', 'Rockets', 'HOU', 'HOU', '#CE1141', '#000000'),
    ('3b566336-d116-5b50-92c4-be68e9413ff7', 'nba', 'Memphis', 'Grizzlies', 'MEM', 'MEM', '#5D76A9', '#12173F'),
    ('619ba0e4-db50-5214-bbe5-af1f08f3699f', 'nba', 'New Orleans', 'Pelicans', 'NOP', 'NOP', '#0C2340', '#C8102E'),
    ('f58ed9a7-33e8-5af0-8595-51810345049d', 'nba', 'San Antonio', 'Spurs', 'SAS', 'SAS', '#C4CED4', '#000000'),
-- MLB (30)
    ('f062826c-46c9-58b8-8c14-33d37babfbe5', 'mlb', 'Baltimore', 'Orioles', 'BAL', 'BAL', '#DF4601', '#000000'),
    ('56520c93-515b-5317-b747-065d516ccdb4', 'mlb', 'Boston', 'Red Sox', 'BOS', 'BOS', '#BD3039', '#0C2340'),
    ('341e8ba8-6b2b-528a-b1f6-2230be44e1c2', 'mlb', 'New York', 'Yankees', 'NYY', 'NYY', '#003087', '#E4002C'),
    ('059724c9-442f-5585-93f5-523859d7636b', 'mlb', 'Tampa Bay', 'Rays', 'TB', 'TB', '#092C5C', '#8FBCE6'),
    ('d7201f36-2e32-5ee2-a912-7f1aa8f7a0c8', 'mlb', 'Toronto', 'Blue Jays', 'TOR', 'TOR', '#134A8E', '#E8291C'),
    ('cd9be283-ee12-5983-a8d3-3afa1a3f8542', 'mlb', 'Chicago', 'White Sox', 'CWS', 'CWS', '#27251F', '#C4CED4'),
    ('0094b51e-b6cf-571f-9356-387bbd452876', 'mlb', 'Cleveland', 'Guardians', 'CLE', 'CLE', '#00385D', '#E50022'),
    ('689db5fe-4a79-5d3e-80ec-02a4cfd1727a', 'mlb', 'Detroit', 'Tigers', 'DET', 'DET', '#0C2340', '#FA4616'),
    ('01d38a1c-11b2-5426-a585-565ca0596618', 'mlb', 'Kansas City', 'Royals', 'KC', 'KC', '#004687', '#BD9B60'),
    ('50d4d600-c394-514b-ab1e-25ba53ebc572', 'mlb', 'Minnesota', 'Twins', 'MIN', 'MIN', '#002B5C', '#D31145'),
    ('5acf8858-a701-5700-88af-e2bb20ba4fe4', 'mlb', 'Houston', 'Astros', 'HOU', 'HOU', '#002D62', '#EB6E1F'),
    ('c1c51594-d91c-5937-bf86-8271c0522dcf', 'mlb', 'Los Angeles', 'Angels', 'LAA', 'LAA', '#BA0021', '#003263'),
    ('7b4666e2-e7cf-5092-aa1d-fab388657e57', 'mlb', 'Oakland', 'Athletics', 'OAK', 'OAK', '#003831', '#EFB21E'),
    ('7c1126b7-b5b3-582c-b43b-24637eec88c7', 'mlb', 'Seattle', 'Mariners', 'SEA', 'SEA', '#0C2C56', '#005C5C'),
    ('0f84c545-da0c-5ff0-bdcc-392034640655', 'mlb', 'Texas', 'Rangers', 'TEX', 'TEX', '#003278', '#C0111F'),
    ('8d7e8dc1-d56c-5190-b9b8-06ee2d26505d', 'mlb', 'Atlanta', 'Braves', 'ATL', 'ATL', '#CE1141', '#13274F'),
    ('9ec438f9-db0c-5131-9131-1922106a7bce', 'mlb', 'Miami', 'Marlins', 'MIA', 'MIA', '#00A3E0', '#EF3340'),
    ('f41b7f44-bbf1-5d8f-999d-9eec9454a78a', 'mlb', 'New York', 'Mets', 'NYM', 'NYM', '#002D72', '#FF5910'),
    ('2464726d-81f6-5f3b-b61a-704bdcc36577', 'mlb', 'Philadelphia', 'Phillies', 'PHI', 'PHI', '#E81828', '#002D72'),
    ('7589c2ef-250c-5457-8cbb-51a580831109', 'mlb', 'Washington', 'Nationals', 'WAS', 'WAS', '#AB0003', '#14225A'),
    ('4b0df026-4d39-5c94-9315-0e98e68aab97', 'mlb', 'Chicago', 'Cubs', 'CHC', 'CHC', '#0E3386', '#CC3433'),
    ('491f448e-1730-526a-9590-126c89e6ab33', 'mlb', 'Cincinnati', 'Reds', 'CIN', 'CIN', '#C6011F', '#000000'),
    ('50e524e1-36ef-5a10-9e67-8e0cafb07cf8', 'mlb', 'Milwaukee', 'Brewers', 'MIL', 'MIL', '#12284B', '#B6922E'),
    ('175be0df-b239-514f-9256-6ed1b64106b9', 'mlb', 'Pittsburgh', 'Pirates', 'PIT', 'PIT', '#27251F', '#FDB827'),
    ('a10cbb48-d64d-569c-bf2c-432eba66c20f', 'mlb', 'St. Louis', 'Cardinals', 'STL', 'STL', '#C41E3A', '#0C2340'),
    ('c97a2f68-2760-5e47-a5f3-4f3096b65a24', 'mlb', 'Arizona', 'Diamondbacks', 'ARI', 'ARI', '#A71930', '#E3D4AD'),
    ('c2512ae2-35d2-50a1-85bd-0e5550567792', 'mlb', 'Colorado', 'Rockies', 'COL', 'COL', '#33006F', '#C4CED4'),
    ('1b5b3610-92f8-5466-a76b-114ad4a197ac', 'mlb', 'Los Angeles', 'Dodgers', 'LAD', 'LAD', '#005A9C', '#EF3E42'),
    ('6511cc9f-3c25-502a-a42f-a4bddcdc634e', 'mlb', 'San Diego', 'Padres', 'SD', 'SD', '#2F241D', '#FFC425'),
    ('822bf54c-218f-51fd-a053-0c2440236b31', 'mlb', 'San Francisco', 'Giants', 'SF', 'SF', '#FD5A1E', '#27251F'),
-- NHL (32)
    ('398777ec-685a-5e2f-b63e-92384f404ab1', 'nhl', 'Boston', 'Bruins', 'BOS', 'BOS', '#FFB81C', '#000000'),
    ('e5f346f0-d43d-5f45-8226-ad3e38fe6433', 'nhl', 'Buffalo', 'Sabres', 'BUF', 'BUF', '#002654', '#FCB514'),
    ('11b25e24-bb27-5310-8aa6-dfdf6de1193c', 'nhl', 'Detroit', 'Red Wings', 'DET', 'DET', '#CE1126', '#FFFFFF'),
    ('76ca2040-b1f4-5322-8c92-9aa44a89e501', 'nhl', 'Florida', 'Panthers', 'FLA', 'FLA', '#041E42', '#C8102E'),
    ('d1ff3032-089e-535d-aef2-9ccafbc2af45', 'nhl', 'Montreal', 'Canadiens', 'MTL', 'MTL', '#AF1E2D', '#192168'),
    ('089c1250-62ee-5abd-be78-4553ffff580e', 'nhl', 'Ottawa', 'Senators', 'OTT', 'OTT', '#C52032', '#C2912C'),
    ('8140ec6b-2c5b-59a0-a7da-824df368801c', 'nhl', 'Tampa Bay', 'Lightning', 'TB', 'TB', '#002868', '#FFFFFF'),
    ('de80c6fa-0da5-54db-aca1-c690a9bcb727', 'nhl', 'Toronto', 'Maple Leafs', 'TOR', 'TOR', '#00205B', '#FFFFFF'),
    ('826d349f-dfe2-5fd6-b85f-6be7e17a9bf0', 'nhl', 'Carolina', 'Hurricanes', 'CAR', 'CAR', '#CC0000', '#000000'),
    ('e97a09b8-8f6a-56e3-a9e8-456b7130744c', 'nhl', 'Columbus', 'Blue Jackets', 'CBJ', 'CBJ', '#002654', '#CE1126'),
    ('29fbad49-a4d8-5490-92df-a55ed3709ea8', 'nhl', 'New Jersey', 'Devils', 'NJ', 'NJ', '#CE1126', '#000000'),
    ('d8acebdf-de7b-592d-9b34-7e5022908fb5', 'nhl', 'New York', 'Islanders', 'NYI', 'NYI', '#00539B', '#F47D30'),
    ('c31f8a46-07fa-5150-8e83-3880b11aa141', 'nhl', 'New York', 'Rangers', 'NYR', 'NYR', '#0038A8', '#CE1126'),
    ('6b4acc2e-5706-5560-9710-25791ecbaae8', 'nhl', 'Philadelphia', 'Flyers', 'PHI', 'PHI', '#F74902', '#000000'),
    ('14ed4dc4-c2b3-5c34-98ee-3a6c21c09959', 'nhl', 'Pittsburgh', 'Penguins', 'PIT', 'PIT', '#000000', '#FCB514'),
    ('8d68c4f8-623a-582b-b8ef-d2bb6180ccfd', 'nhl', 'Washington', 'Capitals', 'WAS', 'WAS', '#C8102E', '#041E42'),
    ('378f0574-208a-5a9c-aa2c-7f5fc8bdd81d', 'nhl', 'Arizona', 'Coyotes', 'ARI', 'ARI', '#8C2633', '#E2D6B5'),
    ('ccba440c-8ec0-5d71-8d6e-33880f4d0b33', 'nhl', 'Chicago', 'Blackhawks', 'CHI', 'CHI', '#CF0A2C', '#000000'),
    ('37ed5b13-55ee-5d02-9aea-763a98e16dfd', 'nhl', 'Colorado', 'Avalanche', 'COL', 'COL', '#6F263D', '#236192'),
    ('480f810a-4312-54cc-9e1e-3980f39bb9c1', 'nhl', 'Dallas', 'Stars', 'DAL', 'DAL', '#006847', '#8F8F8C'),
    ('146008c9-391f-5d64-9e49-2a38f6b28b89', 'nhl', 'Minnesota', 'Wild', 'MIN', 'MIN', '#154734', '#A6192E'),
    ('e603989a-4727-5acf-8b04-efb201e0bd82', 'nhl', 'Nashville', 'Predators', 'NSH', 'NSH', '#FFB81C', '#041E42'),
    ('01c8b4c4-026d-55a4-a930-3956c5f7b342', 'nhl', 'St. Louis', 'Blues', 'STL', 'STL', '#002F87', '#FCB514'),
    ('59eeca27-b7f5-5adb-9e52-3cfb44075acc', 'nhl', 'Winnipeg', 'Jets', 'WPG', 'WPG', '#041E42', '#004C97'),
    ('e31df8ea-b24a-5cd1-a67b-659529a93b7b', 'nhl', 'Anaheim', 'Ducks', 'ANA', 'ANA', '#F47A38', '#B9975B'),
    ('87642736-213c-5d7f-9d7f-21e5ebdecaac', 'nhl', 'Calgary', 'Flames', 'CGY', 'CGY', '#C8102E', '#F1BE48'),
    ('010f541c-5778-5bf6-ab51-dc4de199bb37', 'nhl', 'Edmonton', 'Oilers', 'EDM', 'EDM', '#041E42', '#FF4C00'),
    ('69f73db1-6711-51de-ad30-398421e5fe55', 'nhl', 'Los Angeles', 'Kings', 'LA', 'LA', '#111111', '#A2AAAD'),
    ('49fa35a1-a032-5e17-b76f-a55b53539c9a', 'nhl', 'San Jose', 'Sharks', 'SJ', 'SJ', '#006D75', '#EA7200'),
    ('6f2c24ae-013b-5560-93c4-83548e3ee65b', 'nhl', 'Seattle', 'Kraken', 'SEA', 'SEA', '#001628', '#99D9D9'),
    ('4deca3fd-80f2-5679-aeb9-b9b45fbbe59c', 'nhl', 'Vancouver', 'Canucks', 'VAN', 'VAN', '#00205B', '#00843D'),
    ('87645952-ec79-5f88-82db-973af2d8cfa7', 'nhl', 'Vegas', 'Golden Knights', 'VGK', 'VGK', '#B4975A', '#333F42')
ON CONFLICT (league, abbreviation) DO UPDATE SET
    -- Note: id is intentionally NOT updated. Per the deterministic
    -- UUID contract, (league, abbreviation) → id is a fixed
    -- one-way mapping; the only way the existing id could differ
    -- is if it was inserted incorrectly, in which case the seed's
    -- new value should NOT clobber it (would break FKs in
    -- public.games and any future references).
    city            = EXCLUDED.city,
    name            = EXCLUDED.name,
    short_name      = EXCLUDED.short_name,
    primary_color   = EXCLUDED.primary_color,
    secondary_color = EXCLUDED.secondary_color,
    updated_at      = NOW();
