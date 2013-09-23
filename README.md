# Statesman

A statesmanlike state machine library.


## Usage

```ruby
class PaymentStateMachine
  include Statesman

  state :created, initial: true
  state :submitted
  state :paid
  state :paid_out
  state :failed
  state :refunded

  transition from: :created, to: :submitted
  transition from: :submitted, to: [:paid, :failed]
  transition from: :paid, to: [:paid_out, :refunded]
  transition from: :paid_out, to: :refunded
  transition from: :failed, to: :submitted

  guard_transition(to: :submitted) { payment.mandate.active? }

  before_transition(to: :submitted) do |payment|
    PaymentSubmissionService.new(payment).submit
  end

  after_transition(to: :paid) do |payment|
    MailerService.payment_paid_email(payment).deliver
  end

  after_transition(to: :failed) do |payment|
    MailerService.payment_failed_email(payment).deliver
  end

  guard_transition(to: :paid_out) { |payment| payment.payout.present? }

  after_transition(to: :paid_out) do |payment|
    MailerService.payment_paid_out_email(payment).deliver
  end
end
```

## Persistence

By default Statesman stores transition history in memory only. It can be
persisted by configuring Statesman to use a different adapter. For example,
ActiveRecord within rails:
  
`config/initializers/statesman.rb`:

```ruby
Statesman.configure do
  storage_adapter(Statesman::Adapters::ActiveRecord)
end
```

`db/migrate/create_my_transitions_migration.rb`:

```ruby
class CreateMyTransitionsMigration < ActiveRecord::Migration
  def change
    create_table :my_transitions do |t|
      t.string  :to_state
      t.integer :my_model_id
      t.text    :metadata
      t.timestamps
    end
  end
end  
```

`app/models/my_transition.rb`:

```ruby
class MyModel < ActiveRecord::Base
  has_many :my_transitions
end
```

and on machine initialization:

```ruby
MyStateMachine.new(my_model_instance, transition_class: MyTransition)
```

## Configuration

#### `storage_adapter`

```ruby
Statesman.configure do
  storage_adapter(Statesman::Adapters::ActiveRecord)
end
```
Statesman defaults to storing transitions in memory. If you're using rails, you can instead configure it to persist transitions to the database by using the ActiveRecord adapter.

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
Define a transition rule. Both method parameters are required, `to` can also be an array of states (`.transition(from: :some_state, to: [:another_state, :some_other_state])`).

#### `Machine.guard_transition`
```ruby
Machine.guard_transition(from: :some_state, to: another_state) do |object|
  object.some_boolean?
end
```
Define a guard. `to` and `from` parameters are optional, a nil parameter means guard all transitions. The passed block should evaluate to a boolean and must be idempotent as it could be called many times.

#### `Machine.before_transition`
```ruby
Machine.before_transition(from: :some_state, to: another_state) do |object| 
  object.side_effect
end
```
Define a callback to run before a transition. `to` and `from` parameters are optional, a nil parameter means run before all transitions. This callback can have side-effects as it will only be run once immediately before the transition.

#### `Machine.after_transition`
```ruby
Machine.after_transition(from: :some_state, to: another_state) do |object, transition|
  object.side_effect
end
```
Define a callback to run after a successful transition. `to` and `from` parameters are optional, a nil parameter means run after all transitions. The model object and transition object are passed as arguments to the callback. This callback can have side-effects as it will only be run once immediately after the transition.

#### `Machine.new`
```ruby
my_machine = Machine.new(my_model, transition_class: MyTransitionModel)
```
Initialize a new state machine instance. `my_model` is required. If using the ActiveRecord adapter `my_model` should have a `has_many` association with `MyTransitionModel`.

## Instance methods

#### `Machine#current_state`
Returns the current state based on existing transition objects.

#### `Machine#history`
Returns a sorted array of all transition objects.

#### `Machine#last_transition`
Returns the most recent transition object.

#### `Machine#can_transition_to?(:state)`
Returns true if the current state can transition to the passed state and all applicable guards pass.

#### `Machine#transition_to!(:state)`
Transition to the passed state, returning `true` on success. Raises `Statesman::GuardFailedError` or `Statesman::TransitionFailedError` on failure.

#### `Machine#transition_to(:state)`
Transition to the passed state, returning `true` on success. Swallows all exceptions and returns false on failure.
