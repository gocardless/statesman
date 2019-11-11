## v5.0.0, 11th November 2019

- Adds new syntax and restrictions to ActiveRecordQueries [PR#358](https://github.com/gocardless/statesman/pull/358). With the introduction of this, defining `self.transition_class` or `self.initial_state` is deprecated and will be removed in the next major release.

## v4.1.4, 11th November 2019

- Reverts the breaking changes from [PR#358](https://github.com/gocardless/statesman/pull/358) & `v4.1.3` that where included in the last minor release. If you have changed your code to work with these changes `v5.0.0` will be a copy of `v4.1.3` with a bugfix applied.

## v4.1.3, 6th November 2019

- Add accessible from / to state attributes on the `TransitionFailedError` to avoid parsing strings [@ahjmorton](https://github.com/gocardless/statesman/pull/367)
- Add `after_transition_failure` mechanism [@credric-cordenier](https://github.com/gocardless/statesman/pull/366)

## v4.1.2, 17th August 2019

- Add support for Rails 6 [@greysteil](https://github.com/gocardless/statesman/pull/360)

## v4.1.1, 6th July 2019

- Fix statesman index detection for indexes that start t-z [@hmarr](https://github.com/gocardless/statesman/pull/354)
- Correct access of metadata via `state_machine` [@glenpike](https://github.com/gocardless/statesman/pull/349)

## v4.1.0, 10 April 2019

- Add better support for mysql (and others) in `transition_conflict_error?` [@greysteil](https://github.com/greysteil) (https://github.com/gocardless/statesman/pull/342)

## v4.0.0, 22 February 2019

- Forces Statesman to use a new transactions with `requires_new: true` (https://github.com/gocardless/statesman/pull/249)
- Fixes an issue with `after_commit` transition blocks that where being
    executed even if the transaction rolled back. ([patch](https://github.com/gocardless/statesman/pull/338) by [@matid](https://github.com/matid))

## v3.5.0, 2 November 2018

- Expose `most_recent_transition_join` - ActiveRecords `or` requires that both
    sides of the query match up. Exposing this methods makes things easier if
    one side of the `or` uses `in_state` or `not_in_state`. (patch by [@adambutler](https://github.com/adambutler))
- Various Readme and CI related changes.

## v3.4.1, 14 February 2018 ❤️

- Support ActiveRecord transition classes which don't include `Statesman::Adapters::ActiveRecordTransition`, and thus don't have a `.updated_timestamp_column` method (see #310 for further details) (patch by [@timrogers](https://github.com/timrogers))

## v3.4.0, 12 February 2018

- When unsetting the `most_recent` flag during a transition, don't assume that transitions have an `updated_at` attribute, but rather allow the "updated timestamp column" to be re-configured or disabled entirely (patch by [@timrogers](https://github.com/timrogers))

## v3.3.0, 5 January 2018

- Touch `updated_at` on transitions when unsetting `most_recent` flag (patch by [@NGMarmaduke](https://github.com/NGMarmaduke))
- Fix `force_reload` for ActiveRecord models with loaded transitions (patch by [@jacobpgn](https://github.com/))

## v3.2.0, 27 November 2017

- Allow specifying metadata with `Machine#allowed_transitions` (patch by [@vvondra](https://github.com/vvondra))

## v3.1.0, 1 September 2017

- Add support for Rails 5.0.x and 5.1.x (patch by [@kenchan0130](https://github.com/kenchan0130) and [@timrogers](https://github.com/timrogers))
- Run tests in CircleCI instead of TravisCI (patch by [@timrogers](https://github.com/timrogers))
- Update Rubocop and fix offences (patch by [@timrogers](https://github.com/timrogers))

## v3.0.0, 3 July 2017

*Breaking changes*

- Drop support for Rails < 4.2
- Drop support for Ruby < 2.2

For details on our compatibility policy, see `docs/COMPATIBILITY.md`.

*Changes*

- Better handling of custom transition association names (patch by [@greysteil](https://github.com/greysteil))
- Add foreign keys to transition table generator (patch by [@greysteil](https://github.com/greysteil))
- Support partial indexes in transition table update generator (patch by [@kenchan0130](https://github.com/kenchan0130))

## v2.0.1, 29 March 2016

- Add support for Rails 5 (excluding Mongoid adapter)

## v2.0.0, 5 January 2016

- No changes from v2.0.0.rc1

## v2.0.0.rc1, 23 December 2015

*Breaking changes*

- Unset most_recent after before transitions
  - TL;DR: set `autosave: false` on the `has_many` association between your parent and transition model and this change will almost certainly not affect your integration
  - Previously the `most_recent` flag would be set to `false` on all transitions during any `before_transition` callbacks
  - After this change, the `most_recent` flag will still be `true` for the previous transition during these callbacks
  - Whilst this behaviour is almost certainly what your integration already expected, as a result of it any attempt to save the new, as yet unpersisted, transition during a `before_transition` callback will result in a uniqueness error. In particular, if you have not set `autosave: false` on the `has_many` association between your parent and transition model then any attempt to save the parent model during a `before_transition` will result in an error
- Require a most_recent column on transition tables
  - The `most_recent` column, added in v1.2.0, is now required on all transition tables
  - This greatly speeds up queries on large tables
  - A zero-downtime migration path is outlined in the changelog for v1.2.0. You should use that migration path **before** upgrading to v2.0.0
- Increase default initial sort key to 10
- Drop support for Ruby 1.9.3, which reached end-of-life in February 2015
- Move support for events to a companion gem
  - Previously, Statesman supported the use of "events" to trigger transitions
  - To keep Statesman lightweight we've moved event functionality into the `statesman-events` gem
  - If you are using events, add `statesman-events` to your gemfile and include `Statesman::Events` in your state machines

*Changes*

- Add after_destroy hook to ActiveRecord transition model templates
- Add `in_state?` instance method to `Statesman::Machine`
- Add `force_reload` option to `Statesman::Machine#last_transition`

## v1.3.1, 2 July 2015

- Fix `in_state` queries with a custom `transition_name` (patch by [0tsuki](https://github.com/0tsuki))
- Fix `backfill_most_recent` rake task for databases that support partial indexes (patch by [greysteil](https://github.com/greysteil))

## v1.3.0, 20 June 2015

- Rename `last_transition` alias in `ActiveRecordQueries` to `most_recent_#{model_name}`, to allow merging of two such queries (patch by [@isaacseymour](https://github.com/isaacseymour))

## v1.2.5, 17 June 2015

- Make `backfill_most_recent` rake task db-agnostic (patch by [@timothyp](https://github.com/timothyp))

## v1.2.4, 16 June 2015

- Clarify error messages when misusing `Statesman::Adapters::ActiveRecordTransition` (patch by [@isaacseymour](https://github.com/isaacseymour))

## v1.2.3, 14 April 2015

- Fix use of most_recent column in MySQL (partial indexes aren't supported) (patch by [@greysteil](https://github.com/greysteil))

## v1.2.2, 24 March 2015

- Add support for namespaced transition models (patch by [@DanielWright](https://github.com/DanielWright))

## v1.2.1, 24 March 2015

- Add support for Postgres 9.4's `jsonb` column type (patch by [@isaacseymour](https://github.com/isaacseymour))

## v1.2.0, 18 March 2015

*Changes*

- Add a `most_recent` column to transition tables to greatly speed up queries (ActiveRecord adapter only).
  - All queries are backwards-compatible, so everything still works without the new column.
  - The upgrade path is:
    - Generate and run a migration for adding the column, by running `rails generate statesman:add_most_recent <ParentModel> <TransitionModel>`.
    - Backfill the `most_recent` column on old records by running `rake statesman:backfill_most_recent[ParentModel] `.
    - Add constraints and indexes to the transition table that make use of the new field, by running `rails g statesman:add_constraints_to_most_recent <ParentModel> <TransitionModel>`.
  - The upgrade path has been designed to be zero-downtime, even on large tables. As a result, please note that queries will only use the `most_recent` field after the constraints have been added.
- `ActiveRecordQueries.{not_,}in_state` now accepts an array of states.


## v1.1.0, 9 December 2014
*Fixes*

- Support for Rails 4.2.0.rc2:
  - Remove use of serialized_attributes when using 4.2+. (patch by [@greysteil](https://github.com/greysteil))
  - Use reflect_on_association rather than directly using the reflections hash. (patch by [@timrogers](https://github.com/timrogers))
- Fix `ActiveRecordQueries.in_state` when `Model.initial_state` is defined as a symbol. (patch by [@isaacseymour](https://github.com/isaacseymour))

*Changes*

- Transition metadata now defaults to `{}` rather than `nil`. (patch by [@greysteil](https://github.com/greysteil))

## v1.0.0, 21 November 2014

No changes from v1.0.0.beta2

## v1.0.0.beta2, 10 October 2014
*Breaking changes*

- Rename `ActiveRecordModel` to `ActiveRecordQueries`, to reflect the fact that it mixes in some helpful scopes, but is not required.

## v1.0.0.beta1, 9 October 2014
*Breaking changes*

- Classes which include `ActiveRecordModel` must define an `initial_state` class method.

*Fixes*

- `ActiveRecordModel.in_state` and `ActiveRecordModel.not_in_state` now handle inital states correctly (patch by [@isaacseymour](https://github.com/isaacseymour))

*Additions*

- Transition tables created by generated migrations have `NOT NULL` constraints on `to_state`, `sort_key` and foreign key columns (patch by [@greysteil](https://github.com/greysteil))
- `before_transition` and `after_transition` allow an array of to states (patch by [@isaacseymour](https://github.com/isaacseymour))

## v0.8.3, 2 September 2014
*Fixes*

- Optimisation for Machine#available_events (patch by [@pacso](https://github.com/pacso))

## v0.8.2, 2 September 2014
*Fixes*

- Stop generating a default value for the metadata column if using MySQL.

## v0.8.1, 19 August 2014
*Fixes*

- Adds check in Machine#transition to make sure the 'to' state is not an empty array (patch by [@barisbalic](https://github.com/barisbalic))

## v0.8.0, 29 June 2014
*Additions*

- Events. Machines can now define events as a logical grouping of transitions (patch by [@iurimatias](https://github.com/iurimatias))
- Retries. Individual transitions can be executed with a retry policy by wrapping the method call in a `Machine.retry_conflicts {}` block (patch by [@greysteil](https://github.com/greysteil))

## v0.7.0, 25 June 2014
*Additions*

- `Adapters::ActiveRecord` now handles `ActiveRecord::RecordNotUnique` errors explicitly and re-raises with a `Statesman::TransitionConflictError` if it is due to duplicate sort_keys (patch by [@greysteil](https://github.com/greysteil))

## v0.6.1, 21 May 2014
*Fixes*
- Fixes an issue where the wrong transition was passed to after_transition callbacks for the second and subsequent transition of a given state machine (patch by [@alan](https://github.com/alan))

## v0.6.0, 19 May 2014
*Additions*
- Generators now handle namespaced classes (patch by [@hrmrebecca](https://github.com/hrmrebecca))

*Changes*
- `Machine#transition_to` now only swallows Statesman generated errors. An exception in your guard or callback will no longer be caught by Statesman (patch by [@paulspringett](https://github.com/paulspringett))

## v0.5.0, 27 March 2014
*Additions*
- Scope methods. Adds a module which can be mixed in to an ActiveRecord model to provide `.in_state` and `.not_in_state` query scopes.
- Adds `Machine#after_initialize` hook (patch by [@att14](https://github.com/att14))

*Fixes*
- Added MongoidTransition to the autoload statements, fixing [#29](https://github.com/gocardless/statesman/issues/29) (patch by [@tomclose](https://github.com/tomclose))

## v0.4.0, 27 February 2014
*Additions*
- Adds after_commit flag to after_transition for callbacks to be executed after the transaction has been
committed on the ActiveRecord adapter. These callbacks will still be executed on non transactional adapters.

## v0.3.0, 20 February 2014
*Additions*
- Adds Machine#allowed_transitions method (patch by [@prikha](https://github.com/prikha))

## v0.2.1, 31 December 2013
*Fixes*
- Don't add attr_accessible to generated transition model if running in Rails 4

## v0.2.0, 16 December 2013
*Additions*
- Adds Ruby 1.9.3 support (patch by [@jakehow](https://github.com/jakehow))
- All Mongo dependent tests are tagged so they can be excluded from test runs

*Changes*
- Specs now crash immediately if Mongo is not running

## v0.1.0, 5 November 2013

*Additions*
- Adds Mongoid adapter and generators (patch by [@dluxemburg](https://github.com/dluxemburg))

*Changes*
- Replaces `config#transition_class` with `Statesman::Adapters::ActiveRecordTransition` mixin. (inspired by [@cjbell88](https://github.com/cjbell88))
- Renames the active record transition generator from `statesman:transition` to `statesman:active_record_transition`.
- Moves to using `require_relative` internally where possible to avoid stomping on application load paths.

## v0.0.1, 28 October 2013.
- Initial release
