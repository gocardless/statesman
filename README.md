# Statesman

A statesmanlike state machine library.


## Usage

```ruby
class PaymentStateMachine
  extend Statesman

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

