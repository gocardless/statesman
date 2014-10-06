![Statesman](http://f.cl.ly/items/410n2A0S3l1W0i3i0o2K/statesman.png)

A statesmanlike state machine library for Ruby 1.9.3 and 2.0.

[![Gem Version](https://badge.fury.io/rb/statesman.png)](http://badge.fury.io/rb/statesman)
[![Build Status](https://travis-ci.org/gocardless/statesman.png?branch=master)](https://travis-ci.org/gocardless/statesman)
[![Code Climate](https://codeclimate.com/github/gocardless/statesman.png)](https://codeclimate.com/github/gocardless/statesman)

Statesman is a little different from other state machine libraries which tack
state behaviour directly onto a model. A statesman state machine is defined as a
separate class which is instantiated with the model to which it should
apply. State transitions are also modelled as a class which can optionally be
persisted to the database for a full audit history, including JSON metadata
which can be set during a transition.

This data model allows for interesting things like using a different state
machine depending on the value of a model attribute.

## TL;DR Usage

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

class Order < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordModel

  has_many :order_transitions

  def state_machine
    OrderStateMachine.new(self, transition_class: OrderTransition)
  end

  private

  def self.transition_class
    OrderTransition
  end
end

class OrderTransition < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordTransition

  belongs_to :order, inverse_of: :order_transitions
end

Order.first.state_machine.current_state
# => "pending"

Order.first.state_machine.allowed_transitions
# => ["checking_out", "cancelled"]

Order.first.state_machine.can_transition_to?(:cancelled)
# => true/false

Order.first.state_machine.transition_to(:cancelled, optional: :metadata)
# => true/false

Order.in_state(:cancelled)
# => [#<Order id: "123">]

Order.not_in_state(:checking_out)
# => [#<Order id: "123">]

Order.first.state_machine.transition_to!(:cancelled)
# => true/exception
```

## Events

```ruby
class TaskStateMachine
  include Statesman::Machine

  state :unstarted, initial: true
  state :started
  state :finished
  state :delivered
  state :accepted
  state :rejected

  event :start do
    transition from: :unstarted,  to: :started
  end

  event :finish do
    transition from: :started,    to: :finished
  end

  event :deliver do
    transition from: :finished,   to: :delivered
    transition from: :started,    to: :delivered
  end

  event :accept do
    transition from: :delivered, to: :accepted
  end

  event :rejected do
    transition from: :delivered, to: :rejected
  end

  event :restart do
    transition from: :rejected,   to: :started
  end

end

class Task < ActiveRecord::Base
  delegate :current_state, :trigger!, :available_events, to: :state_machine

  def state_machine
    @state_machine ||= TaskStateMachine.new(self)
  end

end

task = Task.new

task.current_state
# => "unstarted"

task.trigger!(:start)
# => true/exception

task.current_state
# => "started"

task.available_events
# => [:finish, :deliver]

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
  has_many :order_transitions

  # Initialize the state machine
  def state_machine
    @state_machine ||= OrderStateMachine.new(self, transition_class: OrderTransition)
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
Machine.guard_transition(from: :some_state, to: another_state) do |object|
  object.some_boolean?
end
```
Define a guard. `to` and `from` parameters are optional, a nil parameter means
guard all transitions. The passed block should evaluate to a boolean and must
be idempotent as it could be called many times.

#### `Machine.before_transition`
```ruby
Machine.before_transition(from: :some_state, to: another_state) do |object|
  object.side_effect
end
```
Define a callback to run before a transition. `to` and `from` parameters are
optional, a nil parameter means run before all transitions. This callback can
have side-effects as it will only be run once immediately before the transition.

#### `Machine.after_transition`
```ruby
Machine.after_transition(from: :some_state, to: another_state) do |object, transition|
  object.side_effect
end
```
Define a callback to run after a successful transition. `to` and `from`
parameters are optional, a nil parameter means run after all transitions. The
model object and transition object are passed as arguments to the callback.
This callback can have side-effects as it will only be run once immediately
after the transition.

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
model and define a `transition_class` method.

```ruby
class Order < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordModel

  private

  def self.transition_class
    OrderTransition
  end
end
```

#### `Model.in_state(:state_1, :state_2, etc)`
Returns all models currently in any of the supplied states.

#### `Model.not_in_state(:state_1, :state_2, etc)`
Returns all models not currently in any of the supplied states.

## Frequently Asked Questions

#### `Model.in_state` does not work before first transition

This is expected. State is modelled as a series of tranisitions so initially where there has been no transition, there is no explict state. At GoCardless we get around this by transitioning immediately after creation:

```ruby
after_create do
  state_machine.transition_to! "pending"
end
```

#### Storing the state on the model object

If you wish to store the model state on the model directly, you can keep it up to date using an `after_transition` hook:

```ruby
after_transition do |model, transition|
  model.state = transition.to_state
  model.save!
end
```

#### Accessing metadata from the last transition

Given a field `foo` that was stored in the metadata, you can access it like so:

```ruby
model_instance.last_transition.metadata["foo"]
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
    expect { some_model.transition_to!(:baz).to_not raise_error
  end
end
```

#### Testing Callbacks

Callbacks are tested by asserting that the action they perform occurs:

```ruby
describe "some callback" do
  it "adds one to the count property on the model" do
    expect { some_model.transition_to!(:some_state) }.
      to change {
        some_model.reload.count
      }.by(1)
  end
end
```

#### Creating models in certain states

Sometimes you'll want to test a guard / transition from one state to another, where the state you want to go from is not the initial state of the model. In this instance you'll need to construct a model instance in the state required. However, if you have strict guards, this can be a pain. One way to get around this in tests is to directly create the transitions in the database, hence avoiding the guards. 

We use [FactoryGirl](https://github.com/thoughtbot/factory_girl) for creating our test objects. Given an `Order` model that is backed by Statesman, we can easily set up transitions to particular states:

```ruby
factory :order do
  property "value"
  ...
  
  trait :shipped do
    after(:create) do |order|
      FactoryGirl.create(:order_transition, :shipped, order: order)
    end
  end
end
  
factory :order_transition do
  order
  ...
  
  trait :shipped do
    to_state "shipped"
  end
end
```

This means you can easily create an `Order` with the `shipped` state:

```ruby
let(:shipped_order) { FactoryGirl.create(:order, :shipped) }
```

---

GoCardless ♥ open source. If you do too, come [join us](https://gocardless.com/jobs#software-engineer).
