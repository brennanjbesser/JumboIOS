-- ============================================
-- JUMBO Database Schema for Supabase
-- Run this in the Supabase SQL Editor
-- ============================================

-- Enable UUID extension (usually enabled by default)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- USERS TABLE
-- Stores authenticated users from Apple Sign In
-- ============================================
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    apple_user_id TEXT UNIQUE NOT NULL,
    email TEXT,
    username TEXT,
    avatar_emoji TEXT DEFAULT '🏈',
    karma INTEGER DEFAULT 0,
    is_admin BOOLEAN DEFAULT FALSE,
    is_banned BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index for fast Apple ID lookups
CREATE INDEX IF NOT EXISTS idx_users_apple_user_id ON users(apple_user_id);

-- ============================================
-- POSTS TABLE
-- Main posts and replies
-- ============================================
CREATE TABLE IF NOT EXISTS posts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL CHECK (char_length(content) >= 2 AND char_length(content) <= 280),
    team_id TEXT, -- We'll store team IDs as text (e.g., "NFL_KC")
    parent_id UUID REFERENCES posts(id) ON DELETE CASCADE, -- NULL for top-level posts
    upvotes INTEGER DEFAULT 0,
    downvotes INTEGER DEFAULT 0,
    reply_count INTEGER DEFAULT 0,
    report_count INTEGER DEFAULT 0,
    is_hidden BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_posts_team_id ON posts(team_id);
CREATE INDEX IF NOT EXISTS idx_posts_parent_id ON posts(parent_id);
CREATE INDEX IF NOT EXISTS idx_posts_author_id ON posts(author_id);
CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_is_hidden ON posts(is_hidden) WHERE is_hidden = FALSE;

-- ============================================
-- VOTES TABLE
-- Track user votes on posts. One row per (user_id, post_id) — at most
-- one vote per user per post, regardless of how many times they've
-- toggled it (re-vote / remove / re-vote flips is_active in place).
--
-- Score model (canonical):
--   score = COUNT(*) FILTER (WHERE is_active AND vote_type = 'up')
--         - COUNT(*) FILTER (WHERE is_active AND vote_type = 'down')
--
--   • Each user's row contributes +1, -1, or 0 to the post's score.
--   • Inactive rows (is_active = false) contribute 0.
--   • iOS computes this via `RemoteChatService.fetchVoteCounts`
--     (cold start / sanity check) and via realtime delta math
--     (`handleVoteAction` + `contribution(active:voteType:)`).
--   • `Post.score = post.upvotes - post.downvotes` in the iOS model
--     mirrors the same formula, with the underlying counters set
--     by aggregation (never read from `posts.upvotes/downvotes`).
--
-- Soft-delete model:
--   • removeVote in iOS UPDATEs is_active=false rather than DELETEing
--     the row. Postgres realtime DELETE only delivers the primary key
--     in oldRecord, so a hard delete leaves other devices unable to
--     update their cached counts. UPDATE delivers the full old + new
--     row, which is what the iOS realtime delta math needs.
--   • Vote-count aggregations (iOS + the recalculate trigger) only
--     count rows where is_active = true.
--
-- Wire format for vote_type is 'up' / 'down' (matches iOS
-- `RemoteChatService.wireString(for:)` and the trigger function).
-- The CHECK constraint enforces this at the DB level.
-- ============================================
CREATE TABLE IF NOT EXISTS votes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    post_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    -- Stable chat-room scope. Required by the iOS realtime votes
    -- channel which filters server-side via room_id=eq.<uuid>.
    room_id UUID NOT NULL,
    vote_type TEXT NOT NULL CHECK (vote_type IN ('up', 'down')),
    -- Soft-delete flag — false means the user removed this vote.
    -- Inserts default to true (a fresh vote is active immediately).
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, post_id) -- One row per user per post; iOS upserts
                              -- ON CONFLICT user_id,post_id flipping
                              -- is_active back to true on re-vote.
);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_votes_user_post ON votes(user_id, post_id);
CREATE INDEX IF NOT EXISTS idx_votes_post_id ON votes(post_id);

-- Partial index for the active-votes aggregation path (the
-- fetchVoteCounts SELECT in iOS). Skips soft-deleted rows entirely
-- so the index stays compact regardless of remove-vote churn.
CREATE INDEX IF NOT EXISTS votes_post_id_active_idx
    ON votes (post_id, vote_type)
 WHERE is_active = true;

-- ============================================
-- REPORTS TABLE
-- User reports on posts
-- ============================================
CREATE TABLE IF NOT EXISTS reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    reporter_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    post_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK (reason IN ('spam', 'harassment', 'hate_speech', 'misinformation', 'inappropriate', 'other')),
    additional_info TEXT,
    is_resolved BOOLEAN DEFAULT FALSE,
    resolution TEXT CHECK (resolution IN ('dismissed', 'post_removed', 'user_warned', 'user_banned')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    UNIQUE(reporter_id, post_id) -- One report per user per post
);

-- Index for admin queries
CREATE INDEX IF NOT EXISTS idx_reports_is_resolved ON reports(is_resolved) WHERE is_resolved = FALSE;

-- ============================================
-- BLOCKED USERS TABLE
-- Track which users have blocked which other users
-- ============================================
CREATE TABLE IF NOT EXISTS blocked_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    blocker_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_blocked_users_blocker ON blocked_users(blocker_id);

-- ============================================
-- USER FOLLOWED TEAMS TABLE
-- Track which teams each user follows
-- ============================================
CREATE TABLE IF NOT EXISTS user_followed_teams (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    team_id TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, team_id)
);

CREATE INDEX IF NOT EXISTS idx_user_followed_teams_user ON user_followed_teams(user_id);

-- ============================================
-- FUNCTIONS
-- ============================================

-- Function to update reply count when a reply is added
CREATE OR REPLACE FUNCTION update_reply_count()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.parent_id IS NOT NULL THEN
        UPDATE posts SET reply_count = reply_count + 1 WHERE id = NEW.parent_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to auto-update reply count
DROP TRIGGER IF EXISTS trigger_update_reply_count ON posts;
CREATE TRIGGER trigger_update_reply_count
    AFTER INSERT ON posts
    FOR EACH ROW
    EXECUTE FUNCTION update_reply_count();

-- Function to decrement reply count when a reply is deleted
CREATE OR REPLACE FUNCTION decrement_reply_count()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.parent_id IS NOT NULL THEN
        UPDATE posts SET reply_count = GREATEST(0, reply_count - 1) WHERE id = OLD.parent_id;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Trigger for reply deletion
DROP TRIGGER IF EXISTS trigger_decrement_reply_count ON posts;
CREATE TRIGGER trigger_decrement_reply_count
    AFTER DELETE ON posts
    FOR EACH ROW
    EXECUTE FUNCTION decrement_reply_count();

-- Function to recalculate vote counts from active vote rows.
--
-- IMPORTANT: this function is the canonical version (also defined,
-- identically, in supabase_migration_vote_count_triggers.sql and
-- updated by supabase_migration_soft_delete_votes.sql). iOS does NOT
-- read `posts.upvotes` / `posts.downvotes` — those columns are kept
-- accurate here only for non-iOS consumers (admin SQL, future REST
-- clients, BI exports). The iOS client derives counts directly from
-- `votes` rows where `is_active = true`.
--
-- Recompute-from-scratch instead of delta math because:
--   • Impossible to drift out of sync.
--   • Soft-delete model means UPDATE fires on is_active toggle, not
--     just vote_type swap — easier to reason about a full recount.
--   • Wire format is 'up' / 'down' (matches iOS); rows where
--     is_active = false do not count.
CREATE OR REPLACE FUNCTION recalculate_post_vote_counts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected_post UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        affected_post := OLD.post_id;
    ELSE
        affected_post := NEW.post_id;
    END IF;

    UPDATE posts
       SET upvotes   = (SELECT COUNT(*)::int FROM votes
                         WHERE post_id = affected_post
                           AND vote_type = 'up'
                           AND is_active = true),
           downvotes = (SELECT COUNT(*)::int FROM votes
                         WHERE post_id = affected_post
                           AND vote_type = 'down'
                           AND is_active = true)
     WHERE id = affected_post;

    -- Edge case: an UPDATE that moved the vote to a different post
    -- requires the OLD post's counts to be refreshed too.
    IF TG_OP = 'UPDATE' AND OLD.post_id IS DISTINCT FROM NEW.post_id THEN
        UPDATE posts
           SET upvotes   = (SELECT COUNT(*)::int FROM votes
                             WHERE post_id = OLD.post_id
                               AND vote_type = 'up'
                               AND is_active = true),
               downvotes = (SELECT COUNT(*)::int FROM votes
                             WHERE post_id = OLD.post_id
                               AND vote_type = 'down'
                               AND is_active = true)
         WHERE id = OLD.post_id;
    END IF;

    RETURN NULL;
END;
$$;

-- Trigger for vote changes (INSERT, UPDATE — including is_active
-- toggles — and DELETE). Replaces the legacy `update_vote_counts`
-- trigger which used delta math and the obsolete 'upvote'/'downvote'
-- wire format.
DROP TRIGGER IF EXISTS trigger_update_vote_counts ON votes;
DROP TRIGGER IF EXISTS recalc_post_votes_after_insert ON votes;
DROP TRIGGER IF EXISTS recalc_post_votes_after_update ON votes;
DROP TRIGGER IF EXISTS recalc_post_votes_after_delete ON votes;

CREATE TRIGGER recalc_post_votes_after_insert
    AFTER INSERT ON votes
    FOR EACH ROW
    EXECUTE FUNCTION recalculate_post_vote_counts();

CREATE TRIGGER recalc_post_votes_after_update
    AFTER UPDATE ON votes
    FOR EACH ROW
    EXECUTE FUNCTION recalculate_post_vote_counts();

CREATE TRIGGER recalc_post_votes_after_delete
    AFTER DELETE ON votes
    FOR EACH ROW
    EXECUTE FUNCTION recalculate_post_vote_counts();

-- Function to update report count
CREATE OR REPLACE FUNCTION update_report_count()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE posts SET report_count = report_count + 1 WHERE id = NEW.post_id;
    -- Auto-hide posts with 5+ reports
    UPDATE posts SET is_hidden = TRUE WHERE id = NEW.post_id AND report_count >= 5;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for new reports
DROP TRIGGER IF EXISTS trigger_update_report_count ON reports;
CREATE TRIGGER trigger_update_report_count
    AFTER INSERT ON reports
    FOR EACH ROW
    EXECUTE FUNCTION update_report_count();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Enable RLS on all tables
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_followed_teams ENABLE ROW LEVEL SECURITY;

-- ============================================
-- RLS POLICIES FOR USERS
-- ============================================

-- Anyone can read user profiles (for displaying usernames/avatars)
CREATE POLICY "Users are viewable by everyone"
ON users FOR SELECT
USING (true);

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
ON users FOR UPDATE
USING (apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub')
WITH CHECK (apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub');

-- Users can insert their own profile (on sign up)
CREATE POLICY "Users can insert own profile"
ON users FOR INSERT
WITH CHECK (apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub');

-- ============================================
-- RLS POLICIES FOR POSTS
-- ============================================

-- Anyone can read non-hidden posts
CREATE POLICY "Posts are viewable by everyone"
ON posts FOR SELECT
USING (is_hidden = FALSE OR EXISTS (
    SELECT 1 FROM users WHERE users.id = posts.author_id AND users.is_admin = TRUE
));

-- Authenticated users can create posts
CREATE POLICY "Authenticated users can create posts"
ON posts FOR INSERT
WITH CHECK (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = author_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
        AND users.is_banned = FALSE
    )
);

-- Users can delete their own posts, admins can delete any
CREATE POLICY "Users can delete own posts"
ON posts FOR DELETE
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = posts.author_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
    OR EXISTS (
        SELECT 1 FROM users
        WHERE users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
        AND users.is_admin = TRUE
    )
);

-- ============================================
-- RLS POLICIES FOR VOTES
-- ============================================
--
-- Vote counts are NOT derived from `posts.upvotes` / `posts.downvotes`
-- (those columns are cache/analytics only — see VOTES TABLE comment).
-- iOS computes counts by aggregating `votes` rows where is_active = true
-- via fetchVoteCounts. Any policy that restricts SELECT on `votes` to
-- the requesting user breaks that aggregation; production currently
-- relies on the anon/service key bypassing RLS for the count path.
-- Tighten with care — a SELECT policy stricter than "own row" must be
-- paired with a server-side RPC or view for cross-user count reads.

-- Users can read their own votes (used by preloadVotes for the
-- per-user "have I voted?" lookup).
CREATE POLICY "Users can view own votes"
ON votes FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = votes.user_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
);

-- Users can manage their own votes:
--   • INSERT (vote upsert) → casts a new vote
--   • UPDATE (vote upsert ON CONFLICT) → flips is_active back to true
--     on re-vote, swaps vote_type up↔down, or sets is_active=false
--     (soft-delete via removeVote)
--   • DELETE → not used in the current iOS flow; soft-delete via
--     UPDATE preserves the row so realtime UPDATE oldRecord carries
--     full payload. Policy still permits DELETE for admin/cleanup.
CREATE POLICY "Users can manage own votes"
ON votes FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = votes.user_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = votes.user_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
);

-- ============================================
-- RLS POLICIES FOR REPORTS
-- ============================================

-- Users can create reports
CREATE POLICY "Users can create reports"
ON reports FOR INSERT
WITH CHECK (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = reporter_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
);

-- Admins can view all reports
CREATE POLICY "Admins can view reports"
ON reports FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
        AND users.is_admin = TRUE
    )
);

-- Admins can update reports (resolve them)
CREATE POLICY "Admins can resolve reports"
ON reports FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
        AND users.is_admin = TRUE
    )
);

-- ============================================
-- RLS POLICIES FOR BLOCKED USERS
-- ============================================

-- Users can manage their own blocks
CREATE POLICY "Users can manage own blocks"
ON blocked_users FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = blocked_users.blocker_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = blocked_users.blocker_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
);

-- ============================================
-- RLS POLICIES FOR USER FOLLOWED TEAMS
-- ============================================

-- Users can manage their own followed teams
CREATE POLICY "Users can manage own followed teams"
ON user_followed_teams FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = user_followed_teams.user_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM users
        WHERE users.id = user_followed_teams.user_id
        AND users.apple_user_id = current_setting('request.jwt.claims', true)::json->>'sub'
    )
);

-- ============================================
-- REALTIME SUBSCRIPTIONS
-- Enable realtime for posts AND votes tables.
-- ============================================
--
-- iOS subscribes to two channels per chat room:
--   • posts channel — INSERT events filtered server-side by
--     `room_id=eq.<uuid>`, used to fan out new messages.
--   • votes channel — INSERT / UPDATE / DELETE events filtered
--     by `room_id=eq.<uuid>`, used to drive realtime score deltas.
--     UPDATE events specifically need REPLICA IDENTITY FULL on the
--     votes table so the SDK delivers the full oldRecord (the iOS
--     delta math reads old.is_active and old.vote_type).
--
-- Setup:
--   1. Database > Replication in the Supabase dashboard — enable
--      replication for both `posts` and `votes`.
--   2. Database > Tables > votes > "Replica Identity" → set to FULL.
--
-- Or run (requires superuser):
--   ALTER PUBLICATION supabase_realtime ADD TABLE posts;
--   ALTER PUBLICATION supabase_realtime ADD TABLE votes;
--   ALTER TABLE votes REPLICA IDENTITY FULL;

-- ============================================
-- DONE! Your database is ready.
-- ============================================
