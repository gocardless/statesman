# frozen_string_literal: true

# WU0 spike — validate the batched-write win before building anything.
#
# See docs/design/bulk-transitions-plan.md (WU0). This is a throwaway benchmark,
# not production code: it compares four ways of transitioning N parents from
# :initial to :succeeded and reports wall-clock + DB round trips for each.
#
#   (a) loop of transition_to!            — one transaction per object (today's default)
#   (b) loop of transition_to! in one txn — same writes, a single surrounding transaction
#   (c) insert_all, one surrounding txn   — the batched shape WU3 would build
#   (d) insert_all, one txn per batch     — batched, but each chunk commits alone
#
# Why a latency knob? On a local socket a round trip is ~micros, so batching
# barely shows up and you'd wrongly conclude "no-go". The real win is
#   saving ≈ (round trips removed) × (per-round-trip latency)
# so we inject a fixed sleep per DB statement (via an ActiveSupport::Notifications
# subscriber, which is adapter-agnostic) and sweep it. This makes the benchmark
# fully local and reproducible — no remote DB required — while still modelling the
# remote-latency regime the win depends on. Run it against the repo's default
# SQLite, or point DATABASE_URL at a real Postgres/MySQL to confirm.
#
# Runs standalone (no RSpec, no Bundler) so it doesn't drag in the suite's
# mysql2 requirement — it only needs activerecord + pg (or sqlite3). Run it with
# the gems already installed for the project:
#
#   ruby -Ilib -Ispec spec/benchmarks/bulk_transition_bench.rb
#   SIZES=100,1000 LATENCIES_MS=0,0.5,2 ruby -Ilib -Ispec spec/benchmarks/bulk_transition_bench.rb
#   DATABASE_URL=sqlite3::memory: ruby -Ilib -Ispec spec/benchmarks/bulk_transition_bench.rb
#
# Defaults to a local Postgres (postgres://localhost/statesman_bench); override
# with DATABASE_URL to point at MySQL, SQLite, or a remote DB.

# Running outside Bundler, so pin json < 3 before anything loads it — json 3.x
# broke the two-arg JSON.parse that ActiveSupport's serializer relies on.
gem "json", "< 3"

require "benchmark"
require "statesman"
require "active_record"
require "rails" # spec/support/active_record.rb keys migration version off Rails.version

DATABASE_URL = ENV.fetch("DATABASE_URL", "postgres://localhost/statesman_bench")
require "pg" if DATABASE_URL.start_with?("postgres")
require "mysql2" if DATABASE_URL.start_with?("mysql")
require "sqlite3" if DATABASE_URL.start_with?("sqlite")

# The suite's models declare a :secondary connection (SecondaryRecord), so we
# configure primary + secondary pointing at the same DB, exactly like spec_helper.
require "active_record/database_configurations"
url_config = ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.
  new(DATABASE_URL).to_hash.merge(sslmode: "disable")
env = ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
ActiveRecord::Base.configurations = { env => { primary: url_config, secondary: url_config } }
ActiveRecord::Base.establish_connection(:primary)
ActiveRecord::Migration.verbose = false

# Use the ActiveRecord storage adapter (default is Memory).
Statesman.configure { storage_adapter(Statesman::Adapters::ActiveRecord) }

# Load the suite's model + migration definitions (MyActiveRecordModel & co.).
$LOAD_PATH.unshift(File.expand_path("..", __dir__))
require "support/active_record"

SIZES      = ENV.fetch("SIZES", "100,1000,10000").split(",").map { |s| Integer(s) }
LATENCIES  = ENV.fetch("LATENCIES_MS", "0,0.5,2,5").split(",").map { |s| Float(s) }
BATCH_SIZE = Integer(ENV.fetch("BATCH_SIZE", "100"))

# Batch-size sweep (insert_all only): how does chunk size trade off round trips
# against per-statement size? Runs only when BATCH_SWEEP is set; SKIP_MAIN skips
# the three-arm sweep so you can run just this one quickly.
BATCH_SIZES   = ENV.fetch("BATCH_SIZES", "10,25,50,100,250,500,1000").split(",").map { |s| Integer(s) }
BATCH_SWEEP_N = Integer(ENV.fetch("BATCH_SWEEP_N", "10000"))

MODEL      = MyActiveRecordModel
TRANSITION = MyActiveRecordModelTransition
FK         = "my_active_record_model_id"

# --- Round-trip instrumentation -------------------------------------------------
# One subscriber does both jobs. It fires once per executed statement, so the
# count is exact; sleeping here adds latency to the enclosing operation's
# wall-clock. We only bill "real" statements — skip schema introspection and the
# ActiveRecord query cache — and we only bill while State.measuring is true, so
# setup and teardown stay fast.
State = Struct.new(:measuring, :queries, :latency).new(false, 0, 0.0)

ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
  next unless State.measuring

  payload = args.last
  next if payload[:name] == "SCHEMA" || payload[:cached]

  State.queries += 1
  sleep(State.latency) if State.latency.positive?
end

def measure(&block)
  State.queries = 0
  State.measuring = true
  wall = Benchmark.realtime(&block)
  State.measuring = false
  [wall, State.queries]
end

# --- Schema + fixture setup (not measured) --------------------------------------
def reset_schema
  %w[my_active_record_models my_active_record_model_transitions].each do |t|
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{t};")
  end
  CreateMyActiveRecordModelMigration.migrate(:up)
  CreateMyActiveRecordModelTransitionMigration.migrate(:up)
  TRANSITION.reset_column_information
end

# Fresh parents with no prior history — the initial state is virtual, so there are
# no transition rows until we create one. Insert directly to keep setup cheap.
def seed_parents(count)
  now = Time.now.utc
  rows = Array.new(count) { { current_state: "initial", created_at: now, updated_at: now } }
  MODEL.insert_all(rows)
  MODEL.order(:id).limit(count).pluck(:id)
end

def clear_data
  TRANSITION.delete_all
  MODEL.delete_all
end

# --- The four arms --------------------------------------------------------------
def arm_loop(ids)
  ids.each { |id| MODEL.find(id).state_machine.transition_to!(:succeeded) }
end

def arm_loop_in_transaction(ids)
  MODEL.transaction do
    ids.each { |id| MODEL.find(id).state_machine.transition_to!(:succeeded) }
  end
end

# One chunk of the batched write: read each parent's current most_recent row
# (here: none, since everyone is at the virtual :initial), then insert_all a batch
# of new transitions. Two statements per chunk instead of ~5 per object.
def insert_all_chunk(chunk, now)
  # Phase A: read current most_recent per parent (the from_state + sort-key basis).
  existing = TRANSITION.where(FK => chunk, most_recent: true).
    pluck(FK, :to_state, :sort_key).
    to_h { |fk, to_state, sort_key| [fk, [to_state, sort_key]] }

  rows = chunk.map do |parent_id|
    from_state, prev_sort_key = existing[parent_id] || ["initial", 0]
    {
      FK => parent_id,
      from_state: from_state,
      to_state: "succeeded",
      sort_key: prev_sort_key + 10,
      metadata: "{}", # insert_all bypasses AR serialization — write raw JSON
      most_recent: true,
      created_at: now,
      updated_at: now,
    }
  end

  TRANSITION.insert_all(rows)
end

# Prototype of the WU3 fast path: all chunks inside ONE surrounding transaction —
# one BEGIN/COMMIT for the whole operation, but one long-held transaction.
def arm_insert_all(ids, batch_size = BATCH_SIZE)
  now = Time.now.utc
  MODEL.transaction do
    ids.each_slice(batch_size) { |chunk| insert_all_chunk(chunk, now) }
  end
end

# Same batched write, but each chunk commits in its OWN transaction — 2 extra
# round trips (BEGIN/COMMIT) per chunk, in exchange for short-lived transactions
# and locks that release between chunks.
def arm_insert_all_txn_per_batch(ids, batch_size = BATCH_SIZE)
  now = Time.now.utc
  ids.each_slice(batch_size) do |chunk|
    MODEL.transaction { insert_all_chunk(chunk, now) }
  end
end

ARMS = {
  "loop" => method(:arm_loop),
  "loop+txn" => method(:arm_loop_in_transaction),
  "insert_all/1txn" => method(:arm_insert_all),
  "insert_all/txn-per-batch" => method(:arm_insert_all_txn_per_batch),
}.freeze

# Optional subset filter, e.g. ONLY_ARMS="insert_all/1txn,insert_all/txn-per-batch"
ONLY_ARMS = ENV["ONLY_ARMS"]&.split(",")&.map(&:strip)

# --- Run the sweep --------------------------------------------------------------

printf("%<n>-8s %<lat>-10s %<arm>-26s %<wall>10s %<queries>10s %<speedup>9s\n",
       n: "N", lat: "lat(ms)", arm: "arm", wall: "wall(s)", queries: "queries", speedup: "vs loop")

reset_schema

unless ENV.key?("SKIP_MAIN")
  SIZES.each do |n|
    LATENCIES.each do |latency_ms|
      State.latency = latency_ms / 1000.0
      baseline = nil

      ARMS.each do |name, arm|
        next if ONLY_ARMS && !ONLY_ARMS.include?(name)

        clear_data
        ids = seed_parents(n)

        wall, queries = measure { arm.call(ids) }
        baseline ||= wall
        speedup = baseline / wall

        printf("%<n>-8d %<lat>-10s %<arm>-26s %<wall>10.3f %<queries>10d %<speedup>8.1fx\n",
               n: n, lat: latency_ms, arm: name, wall: wall, queries: queries, speedup: speedup)
      end
    end
  end
end

# --- Batch-size sweep -----------------------------------------------------------
if ENV.key?("BATCH_SWEEP")

  printf("%<n>-8s %<lat>-10s %<batch>-12s %<wall>10s %<queries>10s\n",
         n: "N", lat: "lat(ms)", batch: "batch", wall: "wall(s)", queries: "queries")

  LATENCIES.each do |latency_ms|
    State.latency = latency_ms / 1000.0
    BATCH_SIZES.each do |bs|
      clear_data
      ids = seed_parents(BATCH_SWEEP_N)

      wall, queries = measure { arm_insert_all(ids, bs) }

      printf("%<n>-8d %<lat>-10s %<batch>-12d %<wall>10.3f %<queries>10d\n",
             n: BATCH_SWEEP_N, lat: latency_ms, batch: bs, wall: wall, queries: queries)
    end
  end
end
