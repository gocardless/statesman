## v 0.6.1 21 May 2014
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
