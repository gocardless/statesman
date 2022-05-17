<p align="center"><img src="https://user-images.githubusercontent.com/110275/106792848-96e4ee80-664e-11eb-8fd1-16ff24b41eb2.png" alt="Statesman" width="512"></p>

A statesmanlike state machine library.

For our policy on compatibility with Ruby and Rails versions, see [COMPATIBILITY.md](docs/COMPATIBILITY.md).

[![Gem Version](https://badge.fury.io/rb/statesman.svg)](http://badge.fury.io/rb/statesman)
[![CircleCI](https://circleci.com/gh/gocardless/statesman.svg?style=shield)](https://circleci.com/gh/gocardless/statesman)
[![Code Climate](https://codeclimate.com/github/gocardless/statesman.svg)](https://codeclimate.com/github/gocardless/statesman)
[![Gitter](https://badges.gitter.im/join.svg)](https://gitter.im/gocardless/statesman?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)
[![SemVer](https://api.dependabot.com/badges/compatibility_score?dependency-name=statesman&package-manager=bundler&version-scheme=semver)](https://dependabot.com/compatibility-score.html?dependency-name=statesman&package-manager=bundler&version-scheme=semver)

Statesman is an opinionated state machine library designed to provide a robust
audit trail and data integrity. It decouples the state machine logic from the
underlying model and allows for easy composition with one or more model classes.

As such, the design of statesman is a little different from other state machine
libraries:
- State behaviour is defined in a separate, "state machine" class, rather than
added directly onto a model. State machines are then instantiated with the model
to which they should apply.
- State transitions are also modelled as a class, which can optionally be
persisted to the database for a full audit history. This audit history can
include JSON metadata set during a transition.
- Database indices are used to offer database-level transaction duplication
protection.

## Installation

To get started, just add Statesman to your `Gemfile`, and then run `bundle`:

```ruby
gem 'statesman', '~> 10.0.0'
```

## Usage

First, create a state machine based on `Statesman::Machine`:

```ruby
class OrderStateMachine
  include Statesman::Machine

  state :pending, initial: true
  state :checking_out
  state :purchased
  state :shipped
  state :cancelled
  state :failed
  state :refunded

  transition from: :pending,      to: [:checking_out, :cancelled]
  transition from: :checking_out, to: [:purchased, :cancelled]
  transition from: :purchased,    to: [:shipped, :failed]
  transition from: :shipped,      to: :refunded

  guard_transition(to: :checking_out) do |order|
    order.products_in_stock?
  end

  before_transition(from: :checking_out, to: :cancelled) do |order, transition|
    order.reallocate_stock
  end

  before_transition(to: :purchased) do |order, transition|
    PaymentService.new(order).submit
  end

  after_transition(to: :purchased) do |order, transition|
    MailerService.order_confirmation(order).deliver
  end
end
```

Then, link it to your model:

```ruby
class Order < ActiveRecord::Base
  has_many :order_transitions, autosave: false

  include Statesman::Adapters::ActiveRecordQueries[
    transition_class: OrderTransition,
    initial_state: :pending
  ]

  def state_machine
    @state_machine ||= OrderStateMachine.new(self, transition_class: OrderTransition)
  end
end
```

Next, you'll need to create a further model to represent state transitions:

```ruby
class OrderTransition < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordTransition

  validates :to_state, inclusion: { in: OrderStateMachine.states }

  belongs_to :order, inverse_of: :order_transitions
end
```

Now, you can start working with your state machine:

```ruby
Order.first.state_machine.current_state # => "pending"
Order.first.state_machine.allowed_transitions # => ["checking_out", "cancelled"]
Order.first.state_machine.can_transition_to?(:cancelled) # => true/false
Order.first.state_machine.transition_to(:cancelled, optional: :metadata) # => true/false
Order.first.state_machine.transition_to!(:cancelled) # => true/exception
Order.first.state_machine.last_transition # => transition model or nil
Order.first.state_machine.last_transition_to(:pending) # => transition model or nil

Order.in_state(:cancelled) # => [#<Order id: "123">]
Order.not_in_state(:checking_out) # => [#<Order id: "123">]
```

If you'd like, you can also define a template for a generic state machine, then alter classes which extend it as required:

```ruby
module Template
  def define_states
    state :a, initial: true
    state :b
    state :c
  end

  def define_transitions
    transition from: :a, to: :b
    transition from: :b, to: :c
    transition from: :c, to: :a
  end
end

class Circular
  include Statesman::Machine
  extend Template
  
  define_states
  define_transitions
end

class Linear
  include Statesman::Machine
  extend Template
  
  define_states
  define_transitions
  
  remove_transitions from: :c, to: :a
end

class Shorter
  include Statesman::Machine
  extend Template

  define_states
  define_transitions

  remove_state :c
end
```

## Persistence

By default Statesman stores transition history in memory only. It can be
persisted by configuring Statesman to use a different adapter. For example,
for ActiveRecord within Rails:

`config/initializers/statesman.rb`:

```ruby
Statesman.configure do
  storage_adapter(Statesman::Adapters::ActiveRecord)
end
```

Generate the transition model:

```bash
$ rails g statesman:active_record_transition Order OrderTransition
```

Your transition class should
`include Statesman::Adapters::ActiveRecordTransition` if you're using the
ActiveRecord adapter.

If you're using the ActiveRecord adapter and decide not to include the default
`updated_at` column in your transition table, you'll need to configure the
`updated_timestamp_column` option on the transition class, setting it to another column
name (e.g. `:updated_on`) or `nil`.

And add an association from the parent model:

`app/models/order.rb`:

```ruby
class Order < ActiveRecord::Base
  has_many :transitions, class_name: "OrderTransition", autosave: false

  # Initialize the state machine
  def state_machine
    @state_machine ||= OrderStateMachine.new(self, transition_class: OrderTransition,
                                                   association_name: :transitions)
  end

  # Optionally delegate some methods

  delegate :can_transition_to?,
           :current_state, :history, :last_transition, :last_transition_to,
           :transition_to!, :transition_to, :in_state?, to: :state_machine
end
```
#### Using PostgreSQL JSON column

By default, Statesman uses `serialize` to store the metadata in JSON format.
It is also possible to use the PostgreSQL JSON column if you are using Rails 4
or 5. To do that

* Change `metadata` column type in the transition model migration to `json` or `jsonb`

  ```ruby
  # Before
  t.text :metadata, default: "{}"
  # After (Rails 4)
  t.json :metadata, default: "{}"
  # After (Rails 5)
  t.json :metadata, default: {}
  ```

* Remove the `include Statesman::Adapters::ActiveRecordTransition` statement from
  your transition model. (If you want to customise your transition class's "updated
  timestamp column", as described above, you should define a
  `.updated_timestamp_column` method on your class and return the name of the column
  as a symbol, or `nil` if you don't want to record an updated timestamp on
  transitions.)

## Configuration

#### `storage_adapter`

```ruby
Statesman.configure do
  storage_adapter(Statesman::Adapters::ActiveRecord)
end
```
Statesman defaults to storing transitions in memory. If you're using rails, you
can instead configure it to persist transitions to the database by using the
ActiveRecord adapter.

Statesman will fallback to memory unless you specify a transition_class when instantiating your state machine. This allows you to only persist transitions on certain state machines in your app.


## Class methods

#### `Machine.state`
```ruby
Machine.state(:some_state, initial: true)
Machine.state(:another_state)
```
Define a new state and optionally mark as the initial state.

#### `Machine.transition`
```ruby
Machine.transition(from: :some_state, to: :another_state)
```
Define a transition rule. Both method parameters are required, `to` can also be
an array of states (`.transition(from: :some_state, to: [:another_state, :some_other_state])`).

#### `Machine.guard_transition`
```ruby
Machine.guard_transition(from: :some_state, to: :another_state) do |object|
  object.some_boolean?
end
```
Define a guard. `to` and `from` parameters are optional, a nil parameter means
guard all transitions. The passed block should evaluate to a boolean and must
be idempotent as it could be called many times. The guard will pass when it
evaluates to a truthy value and fail when it evaluates to a falsey value (`nil` or `false`).

#### `Machine.before_transition`
```ruby
Machine.before_transition(from: :some_state, to: :another_state) do |object|
  object.side_effect
end
```
Define a callback to run before a transition. `to` and `from` parameters are
optional, a nil parameter means run before all transitions. This callback can
have side-effects as it will only be run once immediately before the transition.

#### `Machine.after_transition`
```ruby
Machine.after_transition(from: :some_state, to: :another_state) do |object, transition|
  object.side_effect
end
```
Define a callback to run after a successful transition. `to` and `from`
parameters are optional, a nil parameter means run after all transitions. The
model object and transition object are passed as arguments to the callback.
This callback can have side-effects as it will only be run once immediately
after the transition.

If you specify `after_commit: true`, the callback will be executed once the
transition has been committed to the database.

#### `Machine.after_transition_failure`
```ruby
Machine.after_transition_failure(from: :some_state, to: :another_state) do |object, exception|
  Logger.info("transition to #{exception.to} failed for #{object.id}")
end
```
Define a callback to run if `Statesman::TransitionFailedError` is raised
during the execution of transition callbacks. `to` and `from`
parameters are optional, a nil parameter means run after all transitions.
The model object, and exception are passed as arguments to the callback.
This is executed outside of the transaction wrapping other callbacks.
If using `transition!` the exception is re-raised after these callbacks are
executed.

#### `Machine.after_guard_failure`
```ruby
Machine.after_guard_failure(from: :some_state, to: :another_state) do |object, exception|
  Logger.info("guard failed during transition to #{exception.to} for #{object.id}")
end
```
Define a callback to run if `Statesman::GuardFailedError` is raised
during the execution of guard callbacks. `to` and `from`
parameters are optional, a nil parameter means run after all transitions.
The model object, and exception are passed as arguments to the callback.
This is executed outside of the transaction wrapping other callbacks.
If using `transition!` the exception is re-raised after these callbacks are
executed.


#### `Machine.new`
```ruby
my_machine = Machine.new(my_model, transition_class: MyTransitionModel)
```
Initialize a new state machine instance. `my_model` is required. If using the
ActiveRecord adapter `my_model` should have a `has_many` association with
`MyTransitionModel`.

#### `Machine.retry_conflicts`
```ruby
Machine.retry_conflicts { instance.transition_to(:new_state) }
```
Automatically retry the given block if a `TransitionConflictError` is raised.
If you know you want to retry a transition if it fails due to a race condition
call it from within this block. Takes an (optional) argument for the maximum
number of retry attempts (defaults to 1).

#### `Machine.states`
Returns an array of all possible state names as strings.

#### `Machine.successors`
Returns a hash of states and the states it is valid for them to transition to.
```ruby
Machine.successors

{
  "pending" => ["checking_out", "cancelled"],
  "checking_out" => ["purchased", "cancelled"],
  "purchased" => ["shipped", "failed"],
  "shipped" => ["refunded"]
}
```

## Instance methods

#### `Machine#current_state`
Returns the current state based on existing transition objects.

Takes an optional keyword argument to force a reload of data from the
database.
e.g `current_state(force_reload: true)`

#### `Machine#in_state?(:state_1, :state_2, ...)`
Returns true if the machine is in any of the given states.

#### `Machine#history`
Returns a sorted array of all transition objects.

#### `Machine#last_transition`
Returns the most recent transition object.

#### `Machine#last_transition_to(:state)`
Returns the most recent transition object to a given state.

#### `Machine#allowed_transitions`
Returns an array of states you can `transition_to` from current state.

#### `Machine#can_transition_to?(:state)`
Returns true if the current state can transition to the passed state and all
applicable guards pass.

#### `Machine#transition_to!(:state)`
Transition to the passed state, returning `true` on success. Raises
`Statesman::GuardFailedError` or `Statesman::TransitionFailedError` on failure.

#### `Machine#transition_to(:state)`
Transition to the passed state, returning `true` on success. Swallows all
Statesman exceptions and returns false on failure. (NB. if your guard or
callback code throws an exception, it will not be caught.)


## Errors

### Initialization errors
These errors are raised when the Machine and/or Model is initialized. A simple spec like
```ruby
expect { OrderStateMachine.new(Order.new, transition_class: OrderTransition) }.to_not raise_error
```
will expose these errors as part of your test suite

#### InvalidStateError
Raised if:
  * Attempting to define a transition without a `to` state.
  * Attempting to define a transition with a non-existent state.
  * Attempting to define multiple states as `initial`.

#### InvalidTransitionError
Raised if:
  * Attempting to define a callback `from` a state that has no valid transitions (A terminal state).
  * Attempting to define a callback `to` the `initial` state if that state has no transitions to it.
  * Attempting to define a callback with `from` and `to` where any of the pairs have no transition between them.

#### InvalidCallbackError
Raised if:
  * Attempting to define a callback without a block.

#### UnserializedMetadataError
Raised if:
  * ActiveRecord is configured to not serialize the `metadata` attribute into
    to Database column backing it. See the `Using PostgreSQL JSON column` section.

#### IncompatibleSerializationError
Raised if:
  * There is a mismatch between the column type of the `metadata` in the
    Database and the model. See the `Using PostgreSQL JSON column` section.

#### MissingTransitionAssociation
Raised if:
  * The model that `Statesman::Adapters::ActiveRecordQueries` is included in
    does not have a `has_many` association to the `transition_class`.

### Runtime errors
These errors are raised by `transition_to!`. Using `transition_to` will
supress `GuardFailedError` and `TransitionFailedError` and return `false` instead.

#### GuardFailedError
Raised if:
  * A guard callback between `from` and `to` state returned a falsey value.

#### TransitionFailedError
Raised if:
  * A transition is attempted but `current_state -> new_state` is not a valid pair.

#### TransitionConflictError
Raised if:
  * A database conflict affecting the `sort_key` or `most_recent` columns occurs
    when attempting a transition.
    Retried automatically if it occurs wrapped in `retry_conflicts`.


## Model scopes

A mixin is provided for the ActiveRecord adapter which adds scopes to easily
find all models currently in (or not in) a given state. Include it into your
model and passing in `transition_class` and `initial_state` as options.

In 4.1.2 and below, these two options had to be defined as methods on the model,
but 5.0.0 and above allow this style of configuration as well.
The old method pollutes the model with extra class methods, and is deprecated,
to be removed in 6.0.0.

```ruby
class Order < ActiveRecord::Base
  has_many :order_transitions, autosave: false
  include Statesman::Adapters::ActiveRecordQueries[
    transition_class: OrderTransition,
    initial_state: OrderStateMachine.initial_state
  ]
end
```

If the transition class-name differs from the association name, you will also
need to pass `transition_name` as an option:

```ruby
class Order < ActiveRecord::Base
  has_many :transitions, class_name: "OrderTransition", autosave: false
  include Statesman::Adapters::ActiveRecordQueries[
    transition_class: OrderTransition,
    initial_state: OrderStateMachine.initial_state,
    transition_name: :transitions
  ]
end
```

#### `Model.in_state(:state_1, :state_2, etc)`
Returns all models currently in any of the supplied states.

#### `Model.not_in_state(:state_1, :state_2, etc)`
Returns all models not currently in any of the supplied states.


#### `Model.most_recent_transition_join`
This joins the model to its most recent transition whatever that may be.
We expose this method to ease use of ActiveRecord's `or` e.g

```ruby
Model.in_state(:state_1).or(
  Model.most_recent_transition_join.where(model_field: 123)
)
```

## Frequently Asked Questions

#### Storing the state on the model object

If you wish to store the model state on the model directly, you can keep it up
to date using an `after_transition` hook.
Combine it with the `after_commit` option to ensure the model state will only be
saved once the transition has made it irreversibly to the database:

```ruby
after_transition(after_commit: true) do |model, transition|
  model.state = transition.to_state
  model.save!
end
```

You could also use a calculated column or view in your database.

#### Accessing metadata from the last transition

Given a field `foo` that was stored in the metadata, you can access it like so:

```ruby
model_instance.state_machine.last_transition.metadata["foo"]
```

#### Events

Used to using a state machine with "events"? Support for events is provided by
the [statesman-events](https://github.com/gocardless/statesman-events) gem. Once
that's included in your Gemfile you can include event functionality in your
state machine as follows:

```ruby
class OrderStateMachine
  include Statesman::Machine
  include Statesman::Events

  ...
end
```

#### Deleting records.

If you need to delete the Parent model regularly you will need to change
either the association deletion behaviour or add a `DELETE CASCADE` condition
to foreign key in your database.

E.g
```
has_many :order_transitions, autosave: false, dependent: :destroy
```
or when migrating the transition model
```
add_foreign_key :order_transitions, :orders, on_delete: :cascade
```


## Testing Statesman Implementations

This answer was abstracted from [this issue](https://github.com/gocardless/statesman/issues/77).

At GoCardless we focus on testing that:
- guards correctly prevent / allow transitions
- callbacks execute when expected and perform the expected actions

#### Testing Guards

Guards can be tested by asserting that `transition_to!` does or does not raise a `Statesman::GuardFailedError`:

```ruby
describe "guards" do
  it "cannot transition from state foo to state bar" do
    expect { some_model.transition_to!(:bar) }.to raise_error(Statesman::GuardFailedError)
  end

  it "can transition from state foo to state baz" do
    expect { some_model.transition_to!(:baz) }.to_not raise_error
  end
end
```

#### Testing Callbacks

Callbacks are tested by asserting that the action they perform occurs:

```ruby
describe "some callback" do
  it "adds one to the count property on the model" do
    expect { some_model.transition_to!(:some_state) }.
      to change { some_model.reload.count }.
      by(1)
  end
end
```

# Third-party extensions

[statesman-sequel](https://github.com/badosu/statesman-sequel) - An adapter to make Statesman work with [Sequel](https://github.com/jeremyevans/sequel)

---

GoCardless ♥ open source. If you do too, come [join us](https://gocardless.com/about/careers/).
