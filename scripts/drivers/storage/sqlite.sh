#!/usr/bin/env bash
# sqlite storage driver (built-in, default).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over SQLite. Sourced by the storage facade (lib/storage.sh, agmsg_storage_load),
# so agmsg_db_path / agmsg_sqlite / agmsg_sql_readfile_path from storage.sh are in
# scope. State is an append-only `events` log (canonical JSONL: message_sent /
# message_read). The legacy `messages` table is read **read-only** and UNIONed
# into list_unread / history so an existing store keeps its inbox and history
# after #206 switches call sites onto the contract (§2.4); legacy rows are never
# migrated or mutated here.
#
# Framing (§1.4 / ADR 0003): record-returning ops write data only to stdout and
# fail with a non-zero exit; control ops (check/init/mark_read_batch/compact)
# print a §1.4 status name on stdout. The delivery cursor (§2.2) is the events.seq
# autoincrement, returned as an opaque decimal string. Read-marking is
# recipient-scoped ((team, agent)) and idempotent.

# --- helpers ---------------------------------------------------------------

_sqlite_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# <team> is the storage selector (see agmsg_db_path). Passed explicitly rather
# than held in a driver-wide variable: these run inside command substitutions,
# where an assignment made by a caller would not be visible anyway.
_sqlite_db() { agmsg_db_path "$1"; }
# The quote is a variable, not a \' in the pattern: bash 3.2 keeps the
# backslash of a \' REPLACEMENT and would double a quote into \'\' there while
# producing '' on bash 4+. tests/test_sqlpath.bats holds this equal to the
# forking form it replaces, on the inputs that matter to SQL quoting.
_sqlite_lit() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Run a record-returning query: strip CR but PRESERVE the sqlite exit status
# (pipefail), so a backend failure surfaces as a non-zero return instead of
# being swallowed by tr's exit 0. The backend's error text goes to stderr (a
# separate fd — it never pollutes the JSONL on stdout) so failures are
# debuggable, per §2.1 framing (#203 (1) / review).
_sqlite_data() {
  ( set -o pipefail; agmsg_sqlite "$(_sqlite_db "$1")" "$2" | tr -d '\r' )
}

# The same query, handed over stdin instead of on the command line (#882).
#
# FOR SQL WHOSE LENGTH GROWS WITH THE DATA, and only for that. A command line
# has an operating-system limit and stdin does not, so any statement carrying a
# list of ids -- one `IN (...)` entry per pulled message, per acked message, per
# roster member -- has to arrive this way or it stops working at a size nobody
# chose.
#
# The size that stops it is not large. Windows' CreateProcess caps the command
# line at 32,767 characters; measured on a Windows machine, sqlite3 took 827
# uuids as arguments and refused 837. A pull page carrying its ids twice
# reaches that at about 400 messages, which is under half a default page, so a
# team that had grown past it simply could not be pulled -- the failure the
# report in #882 arrived as.
#
# `-batch` because this is a script rather than a session: without it sqlite3
# reading a non-tty is still willing to treat a malformed line as an
# interactive prompt, and the point of this path is that nobody is watching.
_sqlite_data_stdin() {
  ( set -o pipefail; printf '%s\n' "$2" | agmsg_sqlite -batch "$(_sqlite_db "$1")" | tr -d '\r' )
}

# The receipt state ABI is SQLite-only and opt-in. Sourcing these definitions
# does not run a runtime probe, create state, advertise the complete capability,
# or alter any legacy/bounded read path.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/receipt.sh"

# IN (...) list of "team:agent" pairs.
_sqlite_pair_in() {
  local out="" p t a
  for p in "$@"; do
    t="${p%%:*}"; a="${p#*:}"
    out="${out:+$out,}'$(_sqlite_lit "$t:$a")'"
  done
  printf '%s' "${out:-''}"
}

# --- contract: lifecycle (control ops, §1.4 status on stdout) ---------------

storage_check() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo missing_deps
    return 10
  fi
  echo ok
}

storage_describe() {
  # The selector is optional HERE and only here: describe reports driver
  # metadata, and the capabilities caller has no team to name. The path line
  # is the only team-dependent part, so it is reported only when a specific
  # store was asked about. This is not a second way to reach the store.
  printf 'name=sqlite\n'
  printf 'backend=SQLite (WAL) event log + legacy messages table\n'
  printf 'capabilities=stage1-sync,stage1-resync,stage2-read-state,sqlite-receipt-ack-v1\n'
  [ -z "${1-}" ] || printf 'db=%s\n' "$(_sqlite_db "$1")"
}

# Does a store already exist? (does NOT create one — lets a read call-site answer
# "no messages yet" without lazily initializing a store in a storeless project.)
storage_store_exists() { [ -f "$(_sqlite_db "$1")" ]; }

storage_init() {
  local db; db="$(_sqlite_db "$1")"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  # CREATE TABLE IF NOT EXISTS does nothing to a store that already has the
  # table, so an existing events table never gains legacy_id from the schema
  # below. SQLite has no ADD COLUMN IF NOT EXISTS, and a failing statement
  # aborts the whole batch, so this runs on its own and its failure ("duplicate
  # column name") is the expected outcome on every run after the first.
  if [ -f "$db" ]; then
    agmsg_sqlite "$db" "ALTER TABLE events ADD COLUMN legacy_id INTEGER;" \
      >/dev/null 2>&1 || true
  fi
  agmsg_sqlite "$db" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS events (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      type       TEXT NOT NULL,
      id         TEXT NOT NULL,
      team       TEXT,
      from_agent TEXT,
      to_agent   TEXT,
      body       TEXT,
      msg_id     TEXT,
      agent      TEXT,
      at         TEXT NOT NULL,
      -- The rowid of this event's copy in the legacy messages table, when one
      -- was written. That table is a read interface other software still opens,
      -- so every message is written to both; this column is what lets a reader
      -- tell that the two rows are one message. Without it the UNION queries
      -- below list the same message twice, because the two tables number their
      -- rows in different spaces (UUID vs rowid) and nothing connects them.
      -- (#689. No backticks in here: this SQL sits inside a double-quoted shell
      -- string, where they are command substitution, not quoting.)
      legacy_id  INTEGER
    );
    CREATE INDEX IF NOT EXISTS events_sent ON events(type, team, to_agent, seq);
    CREATE INDEX IF NOT EXISTS events_read ON events(type, team, agent, msg_id);
    -- legacy_id is looked up by value from the other side: every reader that
    -- unions the two tables asks NOT EXISTS(events.legacy_id = messages.id)
    -- per legacy row, and the one-time push projection asks the same question
    -- for every message in the team. Without this index each of those is a
    -- full scan of events, so the cost is messages x events: on a 17,369-message
    -- store with 28,568 events the projection ran 155 s inside one write
    -- transaction (#919) -- holding the store's write lock for the whole of it,
    -- which is what killed the unlock reprocess in #910 -- to insert nothing.
    -- The ALTER above runs first on purpose, so an older store has the column
    -- before this asks for the index on it.
    CREATE INDEX IF NOT EXISTS events_legacy ON events(legacy_id);
    -- id is the value every cross-reference to an event carries, but the
    -- table's key is seq, so a lookup by id is otherwise a full scan of a
    -- table that holds every message body. The sync import pays that scan
    -- once per imported message (the sync_messages projection selects
    -- FROM events WHERE id=...), which made the import batch grow with the
    -- store: 24.6 ms per message on a 21,471-event store, against ~0 with
    -- this index (#910's remaining reprocess drift, measured statement by
    -- statement on a captured import batch).
    CREATE INDEX IF NOT EXISTS events_id ON events(id);
    CREATE TABLE IF NOT EXISTS read_cursors (
      team TEXT NOT NULL,
      agent TEXT NOT NULL,
      local_position INTEGER NOT NULL DEFAULT 0 CHECK(local_position >= 0),
      PRIMARY KEY(team, agent)
    );
    CREATE TABLE IF NOT EXISTS storage_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    -- Legacy store (read-only here). Created so the UNION queries always parse
    -- even on a brand-new install with no pre-event-log data.
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      to_agent TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      read_at TEXT
    );
    -- Phase-3 adoption is intentionally storm-proof. Everything that existed
    -- before the cursor model is treated as already delivered. Legacy rows get
    -- an exact audit marker without mutating read_at; event-log recipients start
    -- at the current global high-water. Fresh stores have no rows, so they start
    -- naturally at cursor zero.
    INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read',
             'read-cursor-v1:' || m.team || ':' || m.to_agent || ':' || m.id,
             m.team,m.to_agent,CAST(m.id AS TEXT),
             strftime('%Y-%m-%dT%H:%M:%SZ','now')
        FROM messages m
       WHERE NOT EXISTS(SELECT 1 FROM storage_metadata
                         WHERE key='read_cursor_v1')
         AND NOT EXISTS(SELECT 1 FROM events r
                         WHERE r.type='message_read' AND r.team=m.team
                           AND r.agent=m.to_agent
                           AND r.msg_id=CAST(m.id AS TEXT));
    INSERT INTO read_cursors(team,agent,local_position)
      SELECT recipients.team,recipients.agent,
             COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)
        FROM (
          SELECT team,to_agent AS agent FROM events
           WHERE type='message_sent' AND team IS NOT NULL AND to_agent IS NOT NULL
          UNION
          SELECT team,to_agent AS agent FROM messages
        ) recipients
       WHERE NOT EXISTS(SELECT 1 FROM storage_metadata
                         WHERE key='read_cursor_v1')
      ON CONFLICT(team,agent) DO UPDATE SET local_position=MAX(
        read_cursors.local_position,excluded.local_position);
    INSERT OR IGNORE INTO storage_metadata(key,value)
      VALUES('read_cursor_v1','1');
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: messages ----------------------------------------------------

# The one place a message becomes rows. Every caller that records a
# message_sent goes through this, including the one that lands messages pulled
# from a remote -- mirroring only what this machine sends would leave a reader
# of the legacy table able to see half a conversation, and the half it could not
# see is the one that made this worth doing (#689).
#
# WHAT THIS DOES NOT COVER. Worth stating where the code is, because "we write
# to the legacy table" invites the reading that any external viewer will keep
# working, and three kinds of store are outside it:
#
#   * A team on the jsonl driver has no legacy table to mirror into -- that
#     table is created here and in internal/init-db.sh and nowhere else. Such a
#     team is invisible to those readers and this cannot change that. Measured,
#     not assumed: the jsonl driver's only `messages` references are a field of
#     the sync pull payload.
#   * A team moved to its own store (drivers.partition=per-team) writes to a
#     different file. A viewer pointed at the shared store sees nothing for it,
#     mirrored or not.
#   * Rows that predate this are unmirrored in the other direction -- they exist
#     only in the legacy table -- which is what the UNION in list_unread and
#     history is still for.
#
# WHEN IT ENDS. Not on a date, and not "once everyone upgrades": the readers are
# other people's software and we cannot enumerate them. It ends when someone can
# show that nothing reads the table any more, and until someone does that work
# this is a supported interface rather than a migration step. Written down
# because an unbounded compatibility write with no stated exit becomes permanent
# by default, and then nobody knows whether it is load-bearing.
#
# Both tables in one transaction, and the legacy rowid recorded on the event.
# The correspondence is not bookkeeping: it is what every reader that unions the
# two tables uses to recognise one message rather than list it twice.
_sqlite_message_sent_sql() {
  local team="$1" from="$2" to="$3" body="$4" id="$5" at="$6"
  local tl fl ol bl il al
  tl="$(_sqlite_lit "$team")"; fl="$(_sqlite_lit "$from")"; ol="$(_sqlite_lit "$to")"
  bl="$(_sqlite_lit "$body")"; il="$(_sqlite_lit "$id")"; al="$(_sqlite_lit "$at")"
  printf '%s\n' "
    BEGIN IMMEDIATE;
    INSERT INTO messages (team,from_agent,to_agent,body,created_at)
    VALUES ('$tl','$fl','$ol','$bl','$al');
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at,legacy_id)
    VALUES ('message_sent','$il','$tl','$fl','$ol','$bl','$al',last_insert_rowid());
    COMMIT;
  "
}

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at db; id="$(compat_uuid7)"; at="$(_sqlite_now)"; db="$(_sqlite_db "$team")"
  local insert; insert="$(_sqlite_message_sent_sql "$team" "$from" "$to" "$body" "$id" "$at")"
  # Try the INSERT first and only fall back to storage_init on failure (the #114
  # pattern). Running storage_init — which issues PRAGMA journal_mode=WAL and the
  # CREATE TABLE/INDEX statements — on EVERY send serializes badly under a
  # concurrent first-write fan-out and lost rows past the busy_timeout. The common
  # path is now a single INSERT; only a missing table pays the init + retry.
  # Keep message bodies out of argv. Linux can impose a much smaller effective
  # argv ceiling than macOS, so a valid large local message must travel on
  # sqlite3's stdin rather than as the final command-line SQL argument.
  # -bail, because this is now more than one statement. The CLI's default is to
  # report an error and keep going, so a batch whose second INSERT fails still
  # reaches its COMMIT and commits the first one. Measured: the retry below then
  # inserted the message a second time, leaving one row in the legacy table that
  # no event points at -- exactly the unlinked copy the correspondence exists to
  # prevent.
  if ! printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1; then
    storage_init "$team" >/dev/null
    printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$id"
}

# storage_read_cursor_get <team> <agent> — opaque local read frontier.
storage_read_cursor_get() {
  local team="$1" agent="$2"
  storage_init "$team" >/dev/null || return 13
  _sqlite_data "$team" "SELECT COALESCE((SELECT local_position FROM read_cursors
    WHERE team='$(_sqlite_lit "$team")' AND agent='$(_sqlite_lit "$agent")'),0);"
}

# Advance one recipient's local read frontier after a successful driver scan.
# Exact IDs are recorded first; the frontier is then capped immediately before
# the first still-unread addressed message, so a stale/malformed caller cannot
# skip an unseen row merely by presenting a later cursor.
storage_read_cursor_consume() {
  local team="$1" agent="$2" target="$3"; shift 3
  case "$target" in ''|*[!0-9]*) echo runtime_error; return 13 ;; esac
  storage_init "$team" >/dev/null || { echo runtime_error; return 13; }
  local db tl al at id sql=""
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  at="$(_sqlite_now)"
  for id in "$@"; do
    sql="$sql
      INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read','$(_sqlite_lit "$(compat_uuid7)")','$tl','$al',
             '$(_sqlite_lit "$id")','$(_sqlite_lit "$at")'
       WHERE NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team='$tl' AND r.agent='$al' AND r.msg_id='$(_sqlite_lit "$id")');
      -- Mirror the read into the legacy table, through the correspondence
      -- rather than by guessing an id. Without this an external viewer shows
      -- every message unread forever, which is a worse thing to hand someone
      -- than the disagreement it costs (#689).
      UPDATE messages SET read_at='$(_sqlite_lit "$at")'
       WHERE read_at IS NULL
         AND id = (SELECT e.legacy_id FROM events e
                    WHERE e.type='message_sent' AND e.team='$tl'
                      AND e.id='$(_sqlite_lit "$id")' AND e.legacy_id IS NOT NULL);"
  done
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    $sql
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      VALUES('$tl','$al',0);
    UPDATE read_cursors SET local_position=MAX(local_position,COALESCE((
      SELECT MIN(e.seq)-1 FROM events e
       WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
         AND e.seq>read_cursors.local_position
         AND e.seq<=MIN($target,$(_sqlite_highwater))
         AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
           AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
    ),MIN($target,$(_sqlite_highwater))))
    WHERE team='$tl' AND agent='$al';
    COMMIT;" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# storage_list_unread <team> <agent> [--limit N]
# The local cursor is the fast contiguous boundary; exact message_read events
# cover safe out-of-order reads. Legacy rows remain a frozen compatibility path.
storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init "$team" >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "$team" "
    SELECT j FROM (
      SELECT json_object('type','message_sent','id',e.id,'team',e.team,
               'from',e.from_agent,'to',e.to_agent,'body',e.body,'at',e.at) AS j,
             e.at AS ts, 1 AS src, e.seq AS ord
      FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
        AND e.seq>COALESCE((SELECT local_position FROM read_cursors
          WHERE team='$tl' AND agent='$al'),0)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
      UNION ALL
      SELECT json_object('type','message_sent','id',CAST(m.id AS TEXT),'team',m.team,
               'from',m.from_agent,'to',m.to_agent,'body',m.body,'at',m.created_at) AS j,
             m.created_at AS ts, 0 AS src, m.id AS ord
      FROM messages m
      WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=m.team AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
        -- Skip the copy of a message that is already in the event log. Every
        -- message is written to both tables so external readers of the legacy
        -- one keep working (#689); without this the union lists it twice, and
        -- marking one read leaves the other behind because the two branches
        -- number rows in different spaces.
        --
        -- Live space only (seq > 0). A legacy row that was PROJECTED for push
        -- also carries an event, but at a negative seq, deliberately below every
        -- read cursor -- so the events branch above can never return it. Skipping
        -- the legacy row on account of that event would remove the message from
        -- the inbox entirely while history still showed it. Measured: the first
        -- version of this dedupe did exactly that.
        AND NOT EXISTS (SELECT 1 FROM events e2
                         WHERE e2.legacy_id = m.id AND e2.seq > 0)
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# --- bounded read-only facade (#203 fork phase 1) --------------------------
# These helpers deliberately do not call storage_init: a read of a storeless
# project must not create a database, cursor, or migration marker. The SQL
# snapshot also carries a private first-line status marker. Callers capture the
# complete result before emitting any public JSON, so a malformed candidate can
# never produce a partial stdout stream.

_sqlite_bounded_unread_cte() {
  local team="$1" agent="$2" tl al
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  cat <<SQL
WITH unread AS (
  SELECT e.id AS id, e.team AS team, e.from_agent AS from_agent,
         e.to_agent AS to_agent, e.body AS body, e.at AS at,
         e.at AS ts, 1 AS src, e.seq AS ord
    FROM events e
   WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
     AND e.seq>COALESCE((SELECT local_position FROM read_cursors
                           WHERE team='$tl' AND agent='$al'),0)
     AND NOT EXISTS (SELECT 1 FROM events r
                       WHERE r.type='message_read' AND r.team=e.team
                         AND r.agent='$al' AND r.msg_id=e.id)
  UNION ALL
  SELECT CAST(m.id AS TEXT) AS id, m.team AS team, m.from_agent AS from_agent,
         m.to_agent AS to_agent, m.body AS body, m.created_at AS at,
         m.created_at AS ts, 0 AS src, m.id AS ord
    FROM messages m
   WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM events r
                       WHERE r.type='message_read' AND r.team=m.team
                         AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
     AND NOT EXISTS (SELECT 1 FROM events e2
                       WHERE e2.legacy_id=m.id AND e2.seq>0)
)
SQL
}

_sqlite_bounded_list_sql() {
  local team="$1" agent="$2" limit="$3" max_bytes="$4" max_record="$5" cte
  cte="$(_sqlite_bounded_unread_cte "$team" "$agent")"
  cat <<SQL
$cte,
ordered AS (
  SELECT u.*,
         length(CAST(u.body AS BLOB)) AS body_bytes,
         row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n,
         sum(length(CAST(u.body AS BLOB))) OVER
           (ORDER BY u.ts,u.src,u.ord ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           AS cumulative_bytes,
         length(CAST(json_object('type','message_sent','id',u.id,'team',u.team,
           'from',u.from_agent,'to',u.to_agent,'body',u.body,'at',u.at) AS BLOB))
           AS record_bytes
    FROM unread u
),
checks AS (
  SELECT COUNT(*) AS total_count,
         COALESCE(SUM(body_bytes),0) AS total_body_bytes,
         COALESCE(SUM(CASE WHEN typeof(id)!='text'
                              OR typeof(team)!='text'
                              OR typeof(from_agent)!='text'
                              OR typeof(to_agent)!='text'
                              OR typeof(body)!='text'
                              OR typeof(at)!='text' THEN 1 ELSE 0 END),0) AS bad_count,
         COUNT(*)-COUNT(DISTINCT id) AS duplicate_count,
         COALESCE(SUM(CASE WHEN record_bytes>$max_record THEN 1 ELSE 0 END),0)
           AS oversize_count,
         COALESCE(MAX(CASE WHEN n=1 THEN body_bytes END),0) AS first_body_bytes
    FROM ordered
),
state AS (
  SELECT CASE
           WHEN bad_count>0 OR duplicate_count>0 OR oversize_count>0 THEN 'invalid'
           WHEN $limit>0 AND total_count>0 AND first_body_bytes>$max_bytes
             THEN 'overflow_first'
           ELSE 'ok'
         END AS status,
         total_count,total_body_bytes,first_body_bytes
    FROM checks
)
SELECT line FROM (
  SELECT 0 AS phase, 0 AS ord,
         json_object('type','__agmsg_bounded_status','status',status) AS line
    FROM state
  UNION ALL
  SELECT 1, 0,
         json_object('type','bounded_unread_error','reason','body_too_large',
           'id',(SELECT id FROM ordered WHERE n=1),
           'body_bytes',first_body_bytes,'max_body_bytes',$max_bytes,
           'selected_count',0,'selected_body_bytes',0,
           'remaining_count',total_count,'remaining_body_bytes',total_body_bytes)
    FROM state
   WHERE status='overflow_first'
  UNION ALL
  SELECT 1, n,
         json_object('type','message_sent','id',id,'team',team,
           'from',from_agent,'to',to_agent,'body',body,'at',at)
    FROM ordered,state
   WHERE state.status='ok' AND n<=$limit AND cumulative_bytes<=$max_bytes
  UNION ALL
  SELECT 2, 0,
         json_object('type','bounded_unread_result',
           'selected_count',COALESCE(SUM(CASE WHEN n<=$limit
                                                AND cumulative_bytes<=$max_bytes
                                               THEN 1 ELSE 0 END),0),
           'selected_body_bytes',COALESCE(SUM(CASE WHEN n<=$limit
                                                   AND cumulative_bytes<=$max_bytes
                                                  THEN body_bytes ELSE 0 END),0),
           'remaining_count',total_count-COALESCE(SUM(CASE WHEN n<=$limit
                                                            AND cumulative_bytes<=$max_bytes
                                                           THEN 1 ELSE 0 END),0),
           'remaining_body_bytes',total_body_bytes-COALESCE(SUM(CASE WHEN n<=$limit
                                                                       AND cumulative_bytes<=$max_bytes
                                                                      THEN body_bytes ELSE 0 END),0),
           'limit_items',$limit,'max_body_bytes',$max_bytes)
    FROM state
    LEFT JOIN ordered ON 1=1
   WHERE state.status='ok'
   GROUP BY total_count,total_body_bytes
)
ORDER BY phase,ord;
SQL
}

_sqlite_bounded_summary_sql() {
  local team="$1" agent="$2" max_record="$3" tl al
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  cat <<SQL
WITH unread AS (
  SELECT e.id AS id, e.team AS team, e.from_agent AS from_agent,
         e.to_agent AS to_agent, typeof(e.body) AS body_type, e.at AS at,
         e.at AS ts, 1 AS src, e.seq AS ord
    FROM events e
   WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
     AND e.seq>COALESCE((SELECT local_position FROM read_cursors
                           WHERE team='$tl' AND agent='$al'),0)
     AND NOT EXISTS (SELECT 1 FROM events r
                       WHERE r.type='message_read' AND r.team=e.team
                         AND r.agent='$al' AND r.msg_id=e.id)
  UNION ALL
  SELECT CAST(m.id AS TEXT), m.team, m.from_agent, m.to_agent,
         typeof(m.body), m.created_at, m.created_at, 0, m.id
    FROM messages m
   WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                       AND r.team=m.team AND r.agent='$al'
                       AND r.msg_id=CAST(m.id AS TEXT))
     AND NOT EXISTS (SELECT 1 FROM events e2
                       WHERE e2.legacy_id=m.id AND e2.seq>0)
),
ordered AS (
  SELECT u.*, row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n
    FROM unread u
),
summary AS (
  SELECT (SELECT COUNT(*) FROM unread) AS unread_count,
         (SELECT id FROM ordered ORDER BY ts DESC,src DESC,ord DESC LIMIT 1)
           AS newest_id
),
checks AS (
  SELECT COALESCE((SELECT SUM(CASE WHEN id IS NULL OR typeof(id)!='text'
                              OR typeof(team)!='text'
                              OR typeof(from_agent)!='text'
                              OR typeof(to_agent)!='text'
                              OR body_type IS NULL OR body_type!='text'
                              OR typeof(at)!='text'
                         THEN 1 ELSE 0 END) FROM unread),0) AS bad_count,
         (SELECT COUNT(*) FROM unread)-
         (SELECT COUNT(DISTINCT id) FROM unread) AS duplicate_count,
         length(CAST(json_object('type','unread_summary',
           'unread_count',summary.unread_count,'newest_id',summary.newest_id)
           AS BLOB)) AS summary_bytes
    FROM summary
)
SELECT line FROM (
  SELECT 0 AS phase, json_object('type','__agmsg_bounded_status',
                                 'status',CASE WHEN checks.bad_count>0
                                      OR checks.duplicate_count>0
                                      OR checks.summary_bytes>$max_record
                                      THEN 'invalid' ELSE 'ok' END) AS line
    FROM checks
  UNION ALL
  SELECT 1, json_object('type','unread_summary',
         'unread_count',summary.unread_count,'newest_id',summary.newest_id)
    FROM checks CROSS JOIN summary
   WHERE checks.bad_count=0 AND checks.duplicate_count=0
     AND checks.summary_bytes<=$max_record
)
ORDER BY phase;
SQL
}

_sqlite_bounded_show_sql() {
  local team="$1" agent="$2" message_id="$3" max_bytes="$4" max_record="$5"
  local cte tlid; cte="$(_sqlite_bounded_unread_cte "$team" "$agent")"
  tlid="$(_sqlite_lit "$message_id")"
  cat <<SQL
$cte,
target AS (
  SELECT * FROM unread WHERE id='$tlid'
),
checks AS (
  SELECT COUNT(*) AS target_count,
         COALESCE(SUM(CASE WHEN typeof(id)!='text'
                              OR typeof(team)!='text'
                              OR typeof(from_agent)!='text'
                              OR typeof(to_agent)!='text'
                              OR typeof(body)!='text'
                              OR typeof(at)!='text' THEN 1 ELSE 0 END),0) AS bad_count,
         COALESCE(MAX(length(CAST(body AS BLOB))),0) AS body_bytes
         ,COALESCE(MAX(length(CAST(json_object('type','message_sent','id',id,
             'team',team,'from',from_agent,'to',to_agent,'body',body,'at',at)
             AS BLOB))),0) AS record_bytes,
         COALESCE(MAX(length(CAST(json_object('type','bounded_message_error',
             'reason','body_too_large','id',id,'body_bytes',length(CAST(body AS BLOB)),
             'max_body_bytes',$max_bytes) AS BLOB))),0) AS overflow_bytes
    FROM target
),
state AS (
  SELECT CASE
           WHEN bad_count>0 THEN 'invalid'
           WHEN target_count=0 THEN 'not_found'
           WHEN target_count>1 THEN 'ambiguous'
           WHEN body_bytes>$max_bytes AND overflow_bytes>$max_record THEN 'invalid'
           WHEN body_bytes<=$max_bytes AND record_bytes>$max_record THEN 'invalid'
           WHEN body_bytes>$max_bytes THEN 'overflow'
           ELSE 'ok'
         END AS status, target_count,body_bytes
    FROM checks
)
SELECT line FROM (
  SELECT 0 AS phase, 0 AS ord,
         json_object('type','__agmsg_bounded_status','status',status) AS line
    FROM state
  UNION ALL
  SELECT 1, 0,
         json_object('type','bounded_message_error','reason','body_too_large',
           'id',(SELECT id FROM target LIMIT 1),'body_bytes',body_bytes,
           'max_body_bytes',$max_bytes)
    FROM state WHERE status='overflow'
  UNION ALL
  SELECT 1, 0,
         json_object('type','message_sent','id',id,'team',team,
           'from',from_agent,'to',to_agent,'body',body,'at',at)
    FROM target,state WHERE state.status='ok'
)
ORDER BY phase,ord;
SQL
}

# Receipt issuance uses a separate, opt-in statement so ordinary phase-1 reads
# remain byte-for-byte untouched and never probe receipt state. One SELECT
# snapshot emits both public records and private hex-only canonicalization rows.
_sqlite_receipt_list_sql() {
  local team="$1" agent="$2" limit="$3" max_bytes="$4" max_record="$5" cte
  cte="$(_sqlite_bounded_unread_cte "$team" "$agent")"
  cat <<SQL
$cte,
ordered AS (
  SELECT u.*, length(CAST(u.body AS BLOB)) AS body_bytes,
         row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n,
         sum(length(CAST(u.body AS BLOB))) OVER
           (ORDER BY u.ts,u.src,u.ord ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           AS cumulative_bytes,
         length(CAST(json_object('type','message_sent','id',u.id,'team',u.team,
           'from',u.from_agent,'to',u.to_agent,'body',u.body,'at',u.at) AS BLOB))
           AS record_bytes
    FROM unread u
),
checks AS (
  SELECT COUNT(*) AS total_count,
         COALESCE(SUM(body_bytes),0) AS total_body_bytes,
         COALESCE(SUM(CASE WHEN typeof(id)!='text' OR typeof(team)!='text'
                              OR typeof(from_agent)!='text' OR typeof(to_agent)!='text'
                              OR typeof(body)!='text' OR typeof(at)!='text'
                           THEN 1 ELSE 0 END),0) AS bad_count,
         COUNT(*)-COUNT(DISTINCT id) AS duplicate_count,
         COALESCE(SUM(CASE WHEN record_bytes>$max_record THEN 1 ELSE 0 END),0) AS oversize_count,
         COALESCE(MAX(CASE WHEN n=1 THEN body_bytes END),0) AS first_body_bytes
    FROM ordered
),
state AS (
  SELECT CASE WHEN bad_count>0 OR duplicate_count>0 OR oversize_count>0 THEN 'invalid'
              WHEN $limit>0 AND total_count>0 AND first_body_bytes>$max_bytes THEN 'overflow'
              ELSE 'ok' END AS status,total_count,total_body_bytes
    FROM checks
),
selected AS (
  SELECT * FROM ordered,state
   WHERE state.status='ok' AND n<=$limit AND cumulative_bytes<=$max_bytes
),
selection AS (
  SELECT COUNT(*) AS selected_count,COALESCE(SUM(body_bytes),0) AS selected_body_bytes
    FROM selected
),
identity AS (
  SELECT (SELECT value FROM receipt_meta WHERE key='store_generation') AS generation,
         (SELECT value FROM receipt_meta WHERE key='public_key_sha256') AS key_sha256,
         COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0) AS frontier
)
SELECT line FROM (
  SELECT 0 AS phase,0 AS ord,
         json_object('type','__agmsg_bounded_status','status',status) AS line FROM state
  UNION ALL
  SELECT 1,n,json_object('type','message_sent','id',id,'team',team,
         'from',from_agent,'to',to_agent,'body',body,'at',at) FROM selected
  UNION ALL
  SELECT 2,0,json_object('type','bounded_unread_result',
         'selected_count',selection.selected_count,
         'selected_body_bytes',selection.selected_body_bytes,
         'remaining_count',state.total_count-selection.selected_count,
         'remaining_body_bytes',state.total_body_bytes-selection.selected_body_bytes,
         'limit_items',$limit,'max_body_bytes',$max_bytes)
    FROM state,selection WHERE state.status='ok'
  UNION ALL
  SELECT 3,0,'__agmsg_receipt_meta|' || identity.generation || '|' ||
         identity.key_sha256 || '|' || identity.frontier || '|' || selection.selected_count
    FROM state,selection,identity
   WHERE state.status='ok' AND selection.selected_count>0
  UNION ALL
  SELECT 4,n,'__agmsg_receipt_row|' || (n-1) || '|' || lower(hex(CAST(team AS BLOB))) ||
         '|' || lower(hex(CAST(from_agent AS BLOB))) || '|' || lower(hex(CAST(to_agent AS BLOB))) ||
         '|' || lower(hex(CAST(at AS BLOB))) || '|' || CASE src WHEN 1 THEN 'event' ELSE 'legacy' END ||
         '|' || ord || '|' || lower(hex(CAST(id AS BLOB))) || '|' || lower(hex(CAST(body AS BLOB)))
    FROM selected
)
ORDER BY phase,ord;
SQL
}

_sqlite_receipt_show_sql() {
  local team="$1" agent="$2" message_id="$3" max_bytes="$4" max_record="$5"
  local cte id_lit
  cte="$(_sqlite_bounded_unread_cte "$team" "$agent")"
  id_lit="$(_sqlite_lit "$message_id")"
  cat <<SQL
$cte,
ordered AS (
  SELECT u.*,length(CAST(u.body AS BLOB)) AS body_bytes,
         row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n,
         length(CAST(json_object('type','message_sent','id',u.id,'team',u.team,
           'from',u.from_agent,'to',u.to_agent,'body',u.body,'at',u.at) AS BLOB)) AS record_bytes
    FROM unread u
),
checks AS (
  SELECT (SELECT COUNT(*) FROM ordered WHERE id='$id_lit') AS target_count,
         COALESCE((SELECT SUM(CASE WHEN typeof(id)!='text' OR typeof(team)!='text'
                              OR typeof(from_agent)!='text' OR typeof(to_agent)!='text'
                              OR typeof(body)!='text' OR typeof(at)!='text'
                           THEN 1 ELSE 0 END) FROM ordered),0) AS bad_count,
         (SELECT COUNT(*) FROM ordered)-(SELECT COUNT(DISTINCT id) FROM ordered) AS duplicate_count
),
state AS (
  SELECT CASE WHEN bad_count>0 OR duplicate_count>0 THEN 'invalid'
              WHEN target_count!=1 THEN 'not_found'
              WHEN (SELECT n FROM ordered WHERE id='$id_lit')!=1 THEN 'not_prefix'
              WHEN (SELECT body_bytes FROM ordered WHERE id='$id_lit')>$max_bytes THEN 'overflow'
              WHEN (SELECT record_bytes FROM ordered WHERE id='$id_lit')>$max_record THEN 'invalid'
              ELSE 'ok' END AS status FROM checks
),
selected AS (SELECT * FROM ordered,state WHERE id='$id_lit' AND state.status='ok'),
identity AS (
  SELECT (SELECT value FROM receipt_meta WHERE key='store_generation') AS generation,
         (SELECT value FROM receipt_meta WHERE key='public_key_sha256') AS key_sha256,
         COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0) AS frontier
)
SELECT line FROM (
  SELECT 0 AS phase,0 AS ord,
         json_object('type','__agmsg_bounded_status','status',status) AS line FROM state
  UNION ALL
  SELECT 1,n,json_object('type','message_sent','id',id,'team',team,
         'from',from_agent,'to',to_agent,'body',body,'at',at) FROM selected
  UNION ALL
  SELECT 2,0,'__agmsg_receipt_meta|' || identity.generation || '|' ||
         identity.key_sha256 || '|' || identity.frontier || '|1'
    FROM state,identity WHERE state.status='ok'
  UNION ALL
  SELECT 3,n,'__agmsg_receipt_row|0|' || lower(hex(CAST(team AS BLOB))) ||
         '|' || lower(hex(CAST(from_agent AS BLOB))) || '|' || lower(hex(CAST(to_agent AS BLOB))) ||
         '|' || lower(hex(CAST(at AS BLOB))) || '|' || CASE src WHEN 1 THEN 'event' ELSE 'legacy' END ||
         '|' || ord || '|' || lower(hex(CAST(id AS BLOB))) || '|' || lower(hex(CAST(body AS BLOB)))
    FROM selected
)
ORDER BY phase,ord;
SQL
}

# Private acknowledgement snapshot. It emits only canonical hex rows and is
# captured in an owner-only temporary directory by receipt.sh; no public record
# is emitted and the query travels over stdin rather than argv.
_sqlite_receipt_ack_snapshot_sql() {
  local team="$1" agent="$2" selected="$3" cte
  cte="$(_sqlite_bounded_unread_cte "$team" "$agent")"
  cat <<SQL
$cte,
ordered AS (
  SELECT u.*,row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n
    FROM unread u
)
SELECT '__agmsg_receipt_row|' || (n-1) || '|' || lower(hex(CAST(team AS BLOB))) ||
       '|' || lower(hex(CAST(from_agent AS BLOB))) || '|' || lower(hex(CAST(to_agent AS BLOB))) ||
       '|' || lower(hex(CAST(at AS BLOB))) || '|' || CASE src WHEN 1 THEN 'event' ELSE 'legacy' END ||
       '|' || ord || '|' || lower(hex(CAST(id AS BLOB))) || '|' || lower(hex(CAST(body AS BLOB)))
  FROM ordered WHERE n<=$selected ORDER BY n;
SQL
}

# Run the complete ack mutation in one sqlite3 invocation and one IMMEDIATE
# transaction. Expected raw bytes are imported into a TEMP table through SQL
# stdin; opaque IDs and bodies never enter argv or diagnostics.
_sqlite_receipt_ack_transaction() {
  local team="$1" recipient="$2" rows="$3" nonce="$4" payload_sha="$5"
  local generation="$6" key_sha="$7" team_sha="$8" recipient_sha="$9"
  shift 9
  local batch_sha="$1" frame_sha="$2" frontier="$3" issued="$4" expires="$5"
  local db tmp sql gate waiting verdict output error verdict_lit verdict_tmp
  local index team_hex from_hex to_hex at_hex source source_ord id_hex body_hex extra
  local cte tl al result rc=0 selected sqlite_pid attempt claim_rc=0
  db="$(_sqlite_db "$team")" || return 13
  tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agmsg-receipt-sql.XXXXXX" 2>/dev/null)" || return 13
  /bin/chmod 700 "$tmp" 2>/dev/null || { /bin/rm -rf -- "$tmp"; return 13; }
  sql="$tmp/ack.sql"; gate="$tmp/precommit-gate.sh"
  waiting="$tmp/precommit.waiting"; verdict="$tmp/precommit.verdict"
  output="$tmp/sqlite.stdout"; error="$tmp/sqlite.stderr"
  ( umask 077; : >"$sql"; : >"$output"; : >"$error" ) || {
    /bin/rm -rf -- "$tmp"; return 13
  }
  ( umask 077; printf '%s\n' '#!/bin/bash' \
      'set -u' \
      'waiting=${AGMSG_RECEIPT_GATE_WAITING-}' \
      'verdict=${AGMSG_RECEIPT_GATE_VERDICT-}' \
      'case "$waiting:$verdict" in /*:/*) ;; *) exit 1 ;; esac' \
      ': >"$waiting" || exit 1' \
      'attempt=0' \
      'while [ ! -f "$verdict" ]; do' \
      '  attempt=$((attempt + 1)); [ "$attempt" -le 1000 ] || exit 1' \
      '  sleep 0.01' \
      'done' >"$gate" ) || { /bin/rm -rf -- "$tmp"; return 13; }
  /bin/chmod 700 "$gate" 2>/dev/null || { /bin/rm -rf -- "$tmp"; return 13; }
  verdict_lit="$(_sqlite_lit "$verdict")"
  tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$recipient")"
  cte="$(_sqlite_bounded_unread_cte "$team" "$recipient")"
  selected="$(wc -l <"$rows" | /usr/bin/tr -d ' ')"
  {
    printf '.bail on\n.timeout 1000\n'
    printf 'CREATE TEMP TABLE _ack_expected(idx INTEGER PRIMARY KEY,team_hex TEXT,from_hex TEXT,to_hex TEXT,at_hex TEXT,source TEXT,source_ord INTEGER,id_hex TEXT,body_hex TEXT,id_value TEXT,body_value TEXT);\n'
    while IFS='|' read -r index team_hex from_hex to_hex at_hex source source_ord id_hex body_hex extra; do
      [ -z "$extra" ] || return 13
      printf "INSERT INTO _ack_expected VALUES(%s,'%s','%s','%s','%s','%s',%s,'%s','%s',CAST(X'%s' AS TEXT),CAST(X'%s' AS TEXT));\n" \
        "$index" "$team_hex" "$from_hex" "$to_hex" "$at_hex" "$source" \
        "$source_ord" "$id_hex" "$body_hex" "$id_hex" "$body_hex"
    done <"$rows"
    printf 'CREATE TEMP TABLE _ack_guard(value INTEGER CHECK(value=1));\n'
    printf 'BEGIN IMMEDIATE;\n'
    printf "INSERT INTO _ack_guard VALUES((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='claims') THEN 1 ELSE 0 END));\n"
    printf "INSERT INTO _ack_guard VALUES((SELECT CASE WHEN (SELECT value FROM receipt_meta WHERE key='store_generation')='%s' AND (SELECT value FROM receipt_meta WHERE key='public_key_sha256')='%s' THEN 1 ELSE 0 END));\n" "$generation" "$key_sha"
    printf "INSERT INTO _ack_guard VALUES((SELECT CASE WHEN %s<=CAST(strftime('%%s','now') AS INTEGER) AND CAST(strftime('%%s','now') AS INTEGER)<%s THEN 1 ELSE 0 END));\n" "$issued" "$expires"
    printf "INSERT INTO _ack_guard VALUES((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM receipt_nonces WHERE nonce='%s') THEN 1 ELSE 0 END));\n" "$nonce"
    printf '%s, ordered AS (SELECT u.*,row_number() OVER (ORDER BY u.ts,u.src,u.ord) AS n FROM unread u)\n' "$cte"
    printf "INSERT INTO _ack_guard SELECT CASE WHEN
      (SELECT COUNT(*) FROM _ack_expected)=%s
      AND (SELECT COUNT(*) FROM ordered WHERE n<=%s)=%s
      AND NOT EXISTS(
        SELECT 1 FROM _ack_expected x LEFT JOIN ordered o ON o.n=x.idx+1
         WHERE o.n IS NULL
            OR lower(hex(CAST(o.team AS BLOB)))!=x.team_hex
            OR lower(hex(CAST(o.from_agent AS BLOB)))!=x.from_hex
            OR lower(hex(CAST(o.to_agent AS BLOB)))!=x.to_hex
            OR lower(hex(CAST(o.at AS BLOB)))!=x.at_hex
            OR CASE o.src WHEN 1 THEN 'event' ELSE 'legacy' END!=x.source
            OR o.ord!=x.source_ord
            OR lower(hex(CAST(o.id AS BLOB)))!=x.id_hex
            OR lower(hex(CAST(o.body AS BLOB)))!=x.body_hex)
      THEN 1 ELSE 0 END;\n" "$selected" "$selected" "$selected"
    printf "INSERT INTO _ack_guard SELECT CASE WHEN NOT EXISTS(
      SELECT 1 FROM _ack_expected x
      JOIN events e ON x.source='event' AND e.seq=x.source_ord
      LEFT JOIN messages m ON m.id=e.legacy_id
      WHERE e.legacy_id IS NOT NULL AND (
        m.id IS NULL
        OR lower(hex(CAST(m.team AS BLOB)))!=x.team_hex
        OR lower(hex(CAST(m.from_agent AS BLOB)))!=x.from_hex
        OR lower(hex(CAST(m.to_agent AS BLOB)))!=x.to_hex
        OR lower(hex(CAST(m.body AS BLOB)))!=x.body_hex
        OR lower(hex(CAST(m.created_at AS BLOB)))!=x.at_hex))
      THEN 1 ELSE 0 END;\n"
    printf "DELETE FROM receipt_nonces WHERE expires_at < CAST(strftime('%%s','now') AS INTEGER)-86400;\n"
    printf "INSERT INTO receipt_nonces(nonce,payload_sha256,store_generation,team_sha256,recipient_sha256,batch_sha256,frame_sha256,expires_at,committed_at) VALUES('%s','%s','%s','%s','%s','%s','%s',%s,CAST(strftime('%%s','now') AS INTEGER));\n" \
      "$nonce" "$payload_sha" "$generation" "$team_sha" "$recipient_sha" \
      "$batch_sha" "$frame_sha" "$expires"
    printf "INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read','receipt-v1:%s:' || idx,'%s','%s',
             id_value,strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
        FROM _ack_expected ORDER BY idx;\n" "$nonce" "$tl" "$al"
    printf "UPDATE messages SET read_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
      WHERE rowid IN (SELECT source_ord FROM _ack_expected WHERE source='legacy');\n"
    printf "UPDATE messages SET read_at=strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
      WHERE id IN (
        SELECT m.id FROM events e JOIN _ack_expected x
          ON x.source='event' AND e.seq=x.source_ord
         AND lower(hex(CAST(e.id AS BLOB)))=x.id_hex
         AND lower(hex(CAST(e.body AS BLOB)))=x.body_hex
        JOIN messages m ON m.id=e.legacy_id
         AND lower(hex(CAST(m.team AS BLOB)))=x.team_hex
         AND lower(hex(CAST(m.from_agent AS BLOB)))=x.from_hex
         AND lower(hex(CAST(m.to_agent AS BLOB)))=x.to_hex
         AND lower(hex(CAST(m.body AS BLOB)))=x.body_hex
         AND lower(hex(CAST(m.created_at AS BLOB)))=x.at_hex);\n"
    printf "INSERT OR IGNORE INTO read_cursors(team,agent,local_position) VALUES('%s','%s',0);\n" "$tl" "$al"
    printf "UPDATE read_cursors SET local_position=MAX(local_position,MIN(%s,
      COALESCE((SELECT MIN(e.seq)-1 FROM events e
        WHERE e.type='message_sent' AND e.team='%s' AND e.to_agent='%s' AND e.seq<=%s
          AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
            AND r.team=e.team AND r.agent='%s' AND r.msg_id=e.id)),%s)))
      WHERE team='%s' AND agent='%s';\n" "$frontier" "$tl" "$al" "$frontier" "$al" "$frontier" "$tl" "$al"
    # SQLite pauses here with BEGIN IMMEDIATE and every intended write still
    # uncommitted. The parent shell reruns the same closed claim predicate,
    # writes one private allow/deny verdict, and only then lets this stream
    # reach COMMIT. The verdict guard is the only statement between that
    # external recheck and COMMIT; a deny or missing verdict trips .bail on.
    printf '.shell /bin/bash "$AGMSG_RECEIPT_GATE_SCRIPT"\n'
    printf "INSERT INTO _ack_guard VALUES(CASE WHEN CAST(readfile('%s') AS TEXT)='allow' THEN 1 ELSE 0 END);\n" "$verdict_lit"
    printf 'COMMIT;\n'
  } >"$sql" || { /bin/rm -rf -- "$tmp" 2>/dev/null || true; return 13; }

  local AGMSG_RECEIPT_GATE_SCRIPT="$gate"
  local AGMSG_RECEIPT_GATE_WAITING="$waiting"
  local AGMSG_RECEIPT_GATE_VERDICT="$verdict"
  export AGMSG_RECEIPT_GATE_SCRIPT AGMSG_RECEIPT_GATE_WAITING AGMSG_RECEIPT_GATE_VERDICT
  LC_ALL=C agmsg_sqlite -batch "$db" <"$sql" >"$output" 2>"$error" &
  sqlite_pid=$!
  attempt=0
  while [ ! -f "$waiting" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1000 ] || ! kill -0 "$sqlite_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done

  if [ -f "$waiting" ]; then
    if _agmsg_receipt_capability_claim_check "$team"; then
      claim_rc=0
      result=allow
    else
      claim_rc=$?
      result=deny
    fi
    verdict_tmp="${verdict}.tmp.$$"
    if ! ( umask 077; printf '%s' "$result" >"$verdict_tmp" ) ||
       ! /bin/mv -- "$verdict_tmp" "$verdict"; then
      claim_rc=13
      /bin/rm -f -- "$verdict_tmp" 2>/dev/null || true
    fi
  else
    verdict_tmp="${verdict}.tmp.$$"
    ( umask 077; printf '%s' deny >"$verdict_tmp" ) 2>/dev/null &&
      /bin/mv -- "$verdict_tmp" "$verdict" 2>/dev/null || true
  fi

  if wait "$sqlite_pid"; then rc=0; else rc=$?; fi
  result="$(/bin/cat "$output" "$error" 2>/dev/null)"
  if [ "$claim_rc" -ne 0 ]; then
    /bin/rm -rf -- "$tmp" 2>/dev/null || true
    return 76
  fi
  /bin/rm -rf -- "$tmp" 2>/dev/null || return 13
  [ "$rc" -eq 0 ] && [ -z "$result" ] && return 0
  case "$result" in
    *'database is locked'*|*'database table is locked'*|*'database schema is locked'*) return 75 ;;
    *) return 13 ;;
  esac
}


_sqlite_receipt_parse_args() {
  local issue=0 arg
  local -a filtered
  filtered=()
  for arg in "$@"; do
    if [ "$arg" = --issue-receipt ]; then
      [ "$issue" -eq 0 ] || {
        printf 'storage: duplicate --issue-receipt option\n' >&2
        return 13
      }
      issue=1
    else
      filtered[${#filtered[@]}]="$arg"
    fi
  done
  _AGMSG_RECEIPT_ISSUE_REQUESTED="$issue"
  _agmsg_bounded_parse_args "${filtered[@]}"
}

_sqlite_receipt_parse_show_args() {
  local issue=0 arg
  local -a filtered
  filtered=()
  for arg in "$@"; do
    if [ "$arg" = --issue-receipt ]; then
      [ "$issue" -eq 0 ] || {
        printf 'storage: duplicate --issue-receipt option\n' >&2
        return 13
      }
      issue=1
    else
      filtered[${#filtered[@]}]="$arg"
    fi
  done
  _AGMSG_RECEIPT_ISSUE_REQUESTED="$issue"
  _agmsg_bounded_parse_show_args "${filtered[@]}"
}

_sqlite_receipt_issue_preflight() {
  local team="$1" recipient="$2"
  if ! agmsg_validate_team_name "$team" >/dev/null 2>&1 ||
     ! agmsg_validate_agent_name "$recipient" >/dev/null 2>&1; then
      _agmsg_receipt_error 'invalid receipt scope'
      return 13
  fi
  _agmsg_receipt_platform || return $?
  _agmsg_receipt_validate_store "$team" || return $?
  agmsg_receipt_resolve_runtime || return $?
  _agmsg_receipt_capability_claim_check "$team" || return $?
  _agmsg_receipt_validate_ready "$team" || return $?
}

# Optional SQLite-only ABI. Success is deliberately silent; every refusal has
# zero stdout and one bounded receipt diagnostic.
storage_ack_receipt() {
  local team="${1-}" recipient="${2-}" flag="${3-}" token="${4-}"
  [ "$#" -eq 4 ] && [ "$flag" = --receipt ] && [ -n "$token" ] || {
    _agmsg_receipt_ack_diagnostic invalid
    return 13
  }
  [ "${#token}" -le 2048 ] || { _agmsg_receipt_ack_diagnostic invalid; return 13; }
  case "$token" in
    *.*) ;;
    *) _agmsg_receipt_ack_diagnostic invalid; return 13 ;;
  esac
  [ -n "${token%%.*}" ] && [ -n "${token#*.}" ] || {
      _agmsg_receipt_ack_diagnostic invalid
      return 13
    }
  case "${token#*.}" in
    *.*) _agmsg_receipt_ack_diagnostic invalid; return 13 ;;
  esac
  if ! agmsg_validate_team_name "$team" >/dev/null 2>&1 ||
     ! agmsg_validate_agent_name "$recipient" >/dev/null 2>&1; then
    _agmsg_receipt_ack_diagnostic scope
    return 13
  fi
  _agmsg_receipt_platform || return $?
  _agmsg_receipt_validate_store "$team" || return $?
  # Preserve the closed shared claim predicate's exact refusal diagnostic.
  _agmsg_receipt_capability_claim_check "$team" || return $?
  _agmsg_receipt_ack "$team" "$recipient" "$token"
}

_sqlite_bounded_public_result() {
  local output="$1" expected="$2" on_overflow="${3:-0}" first rest
  first="$(printf '%s\n' "$output" | sed -n '1p')"
  case "$first" in
    "{\"type\":\"__agmsg_bounded_status\",\"status\":\"$expected\"}")
      rest="$(printf '%s\n' "$output" | tail -n +2)"
      [ -n "$rest" ] || { printf 'storage: bounded read returned no record\n' >&2; return 13; }
      _agmsg_bounded_emit_records "$rest" || return 13
      [ "$on_overflow" -eq 1 ] && return 13
      return 0
      ;;
    *) printf 'storage: bounded read validation failed\n' >&2; return 13 ;;
  esac
}

storage_unread_summary() {
  local team="$1" agent="$2" db output
  _agmsg_bounded_parse_args || return 13
  db="$(_sqlite_db "$team")" || return 13
  if [ ! -e "$db" ] && [ ! -L "$db" ]; then
    _agmsg_bounded_emit_records '{"type":"unread_summary","unread_count":0,"newest_id":null}'
    return $?
  fi
  if [ ! -f "$db" ] || [ ! -r "$db" ]; then
    printf 'storage: SQLite store is not a readable regular file\n' >&2
    return 13
  fi
  output="$(_sqlite_data "$team" "$(_sqlite_bounded_summary_sql "$team" "$agent" "$_AGMSG_BOUNDED_MAX_RECORD_BYTES")")" || return 13
  _sqlite_bounded_public_result "$output" ok
}

storage_list_unread_bounded() {
  local team="$1" agent="$2" db output
  shift 2
  _sqlite_receipt_parse_args "$@" || return 13
  db="$(_sqlite_db "$team")" || return 13
  if [ "$_AGMSG_RECEIPT_ISSUE_REQUESTED" -eq 1 ]; then
    [ -f "$db" ] && [ -r "$db" ] || {
      _agmsg_receipt_error 'receipt state is not initialized'
      return 13
    }
    _sqlite_receipt_issue_preflight "$team" "$agent" || return $?
    output="$(_sqlite_data "$team" "$(_sqlite_receipt_list_sql "$team" "$agent" "$_AGMSG_BOUNDED_LIMIT" "$_AGMSG_BOUNDED_MAX_BODY_BYTES" "$_AGMSG_BOUNDED_MAX_RECORD_BYTES")")" || return 13
    case "$(printf '%s\n' "$output" | sed -n '1p')" in
      '{"type":"__agmsg_bounded_status","status":"ok"}') ;;
      *) _agmsg_receipt_error 'receipt snapshot validation failed'; return 13 ;;
    esac
    printf '%s\n' "$output" | tail -n +2 | _agmsg_receipt_issue_stream "$team" "$agent"
    return $?
  fi
  if [ ! -e "$db" ] && [ ! -L "$db" ]; then
    _agmsg_bounded_emit_records "{\"type\":\"bounded_unread_result\",\"selected_count\":0,\"selected_body_bytes\":0,\"remaining_count\":0,\"remaining_body_bytes\":0,\"limit_items\":$_AGMSG_BOUNDED_LIMIT,\"max_body_bytes\":$_AGMSG_BOUNDED_MAX_BODY_BYTES}"
    return $?
  fi
  if [ ! -f "$db" ] || [ ! -r "$db" ]; then
    printf 'storage: SQLite store is not a readable regular file\n' >&2
    return 13
  fi
  output="$(_sqlite_data "$team" "$(_sqlite_bounded_list_sql "$team" "$agent" "$_AGMSG_BOUNDED_LIMIT" "$_AGMSG_BOUNDED_MAX_BODY_BYTES" "$_AGMSG_BOUNDED_MAX_RECORD_BYTES")")" || return 13
  if [ "$(printf '%s\n' "$output" | sed -n '1p')" = '{"type":"__agmsg_bounded_status","status":"overflow_first"}' ]; then
    _sqlite_bounded_public_result "$output" overflow_first 1
    return $?
  fi
  _sqlite_bounded_public_result "$output" ok
}

storage_get_message_bounded() {
  local team="$1" agent="$2" message_id="$3" db output first rest
  shift 3
  [ -n "$message_id" ] || { printf 'storage: message id is required\n' >&2; return 13; }
  _sqlite_receipt_parse_show_args "$@" || return 13
  db="$(_sqlite_db "$team")" || return 13
  if [ "$_AGMSG_RECEIPT_ISSUE_REQUESTED" -eq 1 ]; then
    [ -f "$db" ] && [ -r "$db" ] || {
      _agmsg_receipt_error 'receipt state is not initialized'
      return 13
    }
    _sqlite_receipt_issue_preflight "$team" "$agent" || return $?
    # The opaque ID is already the public show selector, but it still must not
    # be copied into sqlite3's process argv. The receipt-only statement goes
    # over stdin; ordinary phase-1 show remains byte-for-byte unchanged.
    output="$(_sqlite_data_stdin "$team" "$(_sqlite_receipt_show_sql "$team" "$agent" "$message_id" "$_AGMSG_BOUNDED_MAX_BODY_BYTES" "$_AGMSG_BOUNDED_MAX_RECORD_BYTES")")" || return 13
    case "$(printf '%s\n' "$output" | sed -n '1p')" in
      '{"type":"__agmsg_bounded_status","status":"ok"}') ;;
      *) _agmsg_receipt_error 'receipt show requires the first unread row'; return 13 ;;
    esac
    printf '%s\n' "$output" | tail -n +2 | _agmsg_receipt_issue_stream "$team" "$agent"
    return $?
  fi
  if [ ! -e "$db" ] && [ ! -L "$db" ]; then
    printf 'storage: message not found\n' >&2
    return 13
  fi
  if [ ! -f "$db" ] || [ ! -r "$db" ]; then
    printf 'storage: SQLite store is not a readable regular file\n' >&2
    return 13
  fi
  output="$(_sqlite_data "$team" "$(_sqlite_bounded_show_sql "$team" "$agent" "$message_id" "$_AGMSG_BOUNDED_MAX_BODY_BYTES" "$_AGMSG_BOUNDED_MAX_RECORD_BYTES")")" || return 13
  first="$(printf '%s\n' "$output" | sed -n '1p')"
  case "$first" in
    '{"type":"__agmsg_bounded_status","status":"ok"}')
      rest="$(printf '%s\n' "$output" | tail -n +2)"
      [ -n "$rest" ] || { printf 'storage: bounded show returned no record\n' >&2; return 13; }
      _agmsg_bounded_emit_records "$rest" || return 13
      ;;
    '{"type":"__agmsg_bounded_status","status":"overflow"}')
      rest="$(printf '%s\n' "$output" | tail -n +2)"
      [ -n "$rest" ] || { printf 'storage: bounded show overflow missing metadata\n' >&2; return 13; }
      _agmsg_bounded_emit_records "$rest" || return 13
      return 13
      ;;
    *) printf 'storage: message not found or malformed\n' >&2; return 13 ;;
  esac
}

# storage_mark_read_batch <team> <agent> <id> [<id> ...]  (control op)
storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || { echo ok; return 0; }
  local tip; tip=$(storage_watch_tip "$team:$agent") || { echo runtime_error; return 13; }
  storage_read_cursor_consume "$team" "$agent" "$tip" "$@"
}

# --- contract: delivery cursor ---------------------------------------------

# The delivery tip is the monotonic AUTOINCREMENT high-water (largest rowid ever
# assigned to `events`), read from sqlite_sequence — NOT MAX(seq) over live rows.
# A DELETE-based storage_compact can lower MAX(seq) (e.g. by coalescing the
# tail message_read) but never the high-water, so a cursor issued before a
# compaction stays valid and a fresh tip never moves backwards (§2.7 cursor-safe).
_sqlite_highwater() {
  printf "COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)"
}

storage_watch_tip() {
  local team; team="$(agmsg_pair_team "$@")" || return 13
  storage_init "$team" >/dev/null
  _sqlite_data "$team" "SELECT $(_sqlite_highwater);"
}

storage_watch_after() {
  local cursor="$1"; shift
  local team; team="$(agmsg_pair_team "$@")" || return 13
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local pairs; pairs="$(_sqlite_pair_in "$@")"
  # The message scan and the trailing-cursor (high-water) read MUST observe the
  # same snapshot, or a row inserted between the two statements would advance the
  # cursor past a message the scan never returned — a silent skip. A deferred read
  # transaction pins one WAL snapshot across both SELECTs, so the emitted cursor
  # never runs ahead of what the scan saw (§2.2 "never skip").
  _sqlite_data "$team" "
    BEGIN;
    SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                       'to',to_agent,'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND seq > $cursor
      AND (team || ':' || to_agent) IN ($pairs)
      AND NOT EXISTS(SELECT 1 FROM events r
        WHERE r.type='message_read' AND r.team=events.team
          AND r.agent=events.to_agent AND r.msg_id=events.id)
    ORDER BY seq ASC;
    SELECT json_object('type','cursor','cursor',
                       CAST(MAX($cursor, $(_sqlite_highwater)) AS TEXT));
    COMMIT;
  "
}

# --- contract: history -----------------------------------------------------

# storage_history <team> [agent] [--limit N]  — events ∪ legacy in time order.
# With <agent>, only rows where that agent is sender or recipient; omit it (empty)
# for the whole team (§2.1 G3 — an additive widening, existing callers unchanged).
storage_history() {
  local team="$1"; shift
  local agent="" limit=""
  # <agent> is optional: consume a leading NON-flag argument as the agent (an
  # empty string is allowed and also means team-wide). A leading --flag means no
  # agent was given. This is what makes `storage_history <team> --limit N` and
  # `storage_history <team>` parse correctly per the §2.1 contract (review).
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then agent="$1"; shift; fi
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init "$team" >/dev/null
  local tl al afilter; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  if [ -n "$agent" ]; then
    afilter="AND (to_agent='$al' OR from_agent='$al')"
  else
    afilter=""
  fi
  # --limit returns the most RECENT N (inner DESC + LIMIT), re-sorted to
  # chronological order for output — the intuitive "recent history" semantics,
  # not the oldest N.
  _sqlite_data "$team" "
    SELECT j FROM (
      SELECT j, ts, src, ord FROM (
        SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                 'to',to_agent,'body',body,'at',at) AS j, at AS ts, 1 AS src, seq AS ord
        FROM events
        WHERE type='message_sent' AND team='$tl' $afilter
        UNION ALL
        SELECT json_object('type','message_sent','id',CAST(id AS TEXT),'team',team,
                 'from',from_agent,'to',to_agent,'body',body,'at',created_at) AS j,
               created_at AS ts, 0 AS src, id AS ord
        FROM messages
        WHERE team='$tl' $afilter
          -- The event log already carries the mirrored copy (#689); listing
          -- both shows one message twice.
          AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id = messages.id)
      )
      ORDER BY ts DESC, src DESC, ord DESC ${limit:+LIMIT $limit}
    )
    ORDER BY ts ASC, src ASC, ord ASC;
  "
}

# --- contract: export / import / compact -----------------------------------

storage_export() {
  local team="$1" file="$2"
  storage_init "$team" >/dev/null
  # Forward-compat (§2.3): only the v1 event types are projected. A WHERE filter
  # (not just a CASE) keeps unknown-type rows out entirely, so they never surface
  # as a NULL → blank line on stdout, matching list_unread/history/watch_after.
  _sqlite_data "$team" "
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events
    WHERE type IN ('message_sent','message_read')
    ORDER BY seq ASC;
  " > "$file"
}

storage_import() {
  # `selector`, not `team`: the loop below reuses `team` for the team named by
  # each imported RECORD, which is a different thing from the store being
  # written to. Sharing one name here would read as if they had to match.
  local selector="$1" file="$2" db; db="$(_sqlite_db "$selector")"
  [ -f "$file" ] || return 1
  storage_init "$selector" >/dev/null
  local line t id team frm to body msg_id agent at
  j() { sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t=$(j type); id=$(j id); team=$(j team); at=$(j at)
    if [ "$t" = message_sent ]; then
      frm=$(j from); to=$(j to); body=$(j body)
      # Same utility as a live send, so an imported store presents the same
      # legacy view as the store it came from (#689).
      printf '%s\n' "$(_sqlite_message_sent_sql "$team" "$frm" "$to" "$body" "$id" "$at")" \
        | agmsg_sqlite -bail "$db" >/dev/null 2>&1
    elif [ "$t" = message_read ]; then
      agent=$(j agent); msg_id=$(j msg_id)
      agmsg_sqlite "$db" "INSERT INTO events (type,id,team,agent,msg_id,at)
        VALUES ('message_read','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$agent")','$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$at")');
        UPDATE messages SET read_at='$(_sqlite_lit "$at")'
         WHERE read_at IS NULL
           AND id = (SELECT e.legacy_id FROM events e
                      WHERE e.type='message_sent' AND e.team='$(_sqlite_lit "$team")'
                        AND e.id='$(_sqlite_lit "$msg_id")' AND e.legacy_id IS NOT NULL);" \
        >/dev/null 2>&1
    fi
  done < "$file"
}

# Internal (§2.7): coalesce duplicate message_read markers, keeping the earliest. (control op)
storage_compact() {
  local db; db="$(_sqlite_db "$1")"
  agmsg_sqlite "$db" "
    DELETE FROM events WHERE type='message_read' AND seq NOT IN (
      SELECT MIN(seq) FROM events WHERE type='message_read'
      GROUP BY team, agent, msg_id);
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# Optional Stage-1 remote synchronization extension. Keep the
# implementation separate from the local storage ABI so local-only callers do
# not pay its jq/base64 dependency cost.
# shellcheck disable=SC1090
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sqlite-sync.sh"
