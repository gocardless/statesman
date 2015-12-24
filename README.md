![Statesman](http://f.cl.ly/items/410n2A0S3l1W0i3i0o2K/statesman.png)

A statesmanlike state machine library for Ruby 2.0.0 and up.

[![Gem Version](https://badge.fury.io/rb/statesman.png)](http://badge.fury.io/rb/statesman)
[![Build Status](https://travis-ci.org/gocardless/statesman.png?branch=master)](https://travis-ci.org/gocardless/statesman)
[![Code Climate](https://codeclimate.com/github/gocardless/statesman.png)](https://codeclimate.com/github/gocardless/statesman)
[![Gitter](https://badges.gitter.im/Join Chat.svg)](https://gitter.im/gocardless/statesman?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

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
- Database indicies are used to offer database-level transaction duplication
protection.

## TL;DR Usage

```ruby

#######################
# State Machine Class #
#######################
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

##############
# Your Model #
##############
class Order < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordQueries

  has_many :order_transitions, autosave: false

  def state_machine
    @state_machine ||= OrderStateMachine.new(self, transition_class: OrderTransition)
  end

  private

  def self.transition_class
    OrderTransition
  end

  def self.initial_state
    :pending
  end
end

####################
# Transition Model #
####################
class OrderTransition < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordTransition

  belongs_to :order, inverse_of: :order_transitions
end

########################
# Example method calls #
########################
Order.first.state_machine.current_state # => "pending"
Order.first.state_machine.allowed_transitions # => ["checking_out", "cancelled"]
Order.first.state_machine.can_transition_to?(:cancelled) # => true/false
Order.first.state_machine.transition_to(:cancelled, optional: :metadata) # => true/false
Order.first.state_machine.transition_to!(:cancelled) # => true/exception

Order.in_state(:cancelled) # => [#<Order id: "123">]
Order.not_in_state(:checking_out) # => [#<Order id: "123">]

```

## Persistence

By default Statesman stores transition history in memory only. It can be
persisted by configuring Statesman to use a different adapter. For example,
ActiveRecord within Rails:

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
  delegate :can_transition_to?, :transition_to!, :transition_to, :current_state,
           to: :state_machine
end
```
#### Using PostgreSQL JSON column

By default, Statesman uses `serialize` to store the metadata in JSON format.
It is also possible to use the PostgreSQL JSON column if you are using Rails 4. To do that

* Change `metadata` column type in the transition model migration to `json`

  ```ruby
  # Before
  t.text :metadata, default: "{}"
  # After
  t.json :metadata, default: "{}"
  ```

* Remove `include Statesman::Adapters::ActiveRecordTransition` statement from your
  transition model

## Configuration

#### `storage_adapter`

```ruby
Statesman.configure do
  storage_adapter(Statesman::Adapters::ActiveRecord)
  # ...or
  storage_adapter(Statesman::Adapters::Mongoid)
end
```
Statesman defaults to storing transitions in memory. If you're using rails, you
can instead configure it to persist transitions to the database by using the
ActiveRecord or Mongoid adapter.

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
be idempotent as it could be called many times.

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

## Instance methods

#### `Machine#current_state`
Returns the current state based on existing transition objects.

#### `Machine#in_state?(:state_1, :state_2, ...)`
Returns true if the machine is in any of the given states.

#### `Machine#history`
Returns a sorted array of all transition objects.

#### `Machine#last_transition`
Returns the most recent transition object.

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

## Model scopes

A mixin is provided for the ActiveRecord adapter which adds scopes to easily
find all models currently in (or not in) a given state. Include it into your
model and define `transition_class` and `initial_state` class methods:

```ruby
class Order < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordQueries

  private

  def self.transition_class
    OrderTransition
  end

  def self.initial_state
    OrderStateMachine.initial_state
  end
end
```

If the transition class-name differs from the association name, you will also
need to define a corresponding `transition_name` class method:

```ruby
class Order < ActiveRecord::Base
  has_many :transitions, class_name: "OrderTransition", autosave: false

  private

  def self.transition_name
    :transitions
  end

  def self.transition_class
    OrderTransition
  end

  def self.initial_state
    OrderStateMachine.initial_state
  end
end
```

#### `Model.in_state(:state_1, :state_2, etc)`
Returns all models currently in any of the supplied states.

#### `Model.not_in_state(:state_1, :state_2, etc)`
Returns all models not currently in any of the supplied states.

## Frequently Asked Questions

#### Storing the state on the model object

If you wish to store the model state on the model directly, you can keep it up
to date using an `after_transition` hook:

```ruby
after_transition do |model, transition|
  model.state = transition.to_state
  model.save!
end
```

You could also use a calculated column or view in your database.

#### Accessing metadata from the last transition

Given a field `foo` that was stored in the metadata, you can access it like so:

```ruby
model_instance.last_transition.metadata["foo"]
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

---

GoCardless ♥ open source. If you do too, come [join us](https://gocardless.com/jobs#software-engineer).
