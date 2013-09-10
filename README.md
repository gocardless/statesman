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

  before_transition(to: :submitted) do
    PaymentSubmissionService.new(payment).submit
  end

  after_transition(to: :paid) do
    mailer.payment_paid_email(payment).deliver
  end

  after_transition(to: :failed) do
    mailer.payment_failed_email(payment).deliver
  end

  guard_transition(to: :paid_out) { payment.payout.present? }

  after_transition(to: :paid_out) do
    mailer.payment_paid_out_email(payment).deliver
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
      t.string  :from
      t.string  :to
      t.integer :my_model_id
      t.hstore  :metadata
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
  my_state_machine = MyStateMachine.new(object: my_model_instance,
                                        transition_class: MyTransition)
```
