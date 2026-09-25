# Contributing

Thanks for taking an interest in contributing to Statesman, here are a few
ways you can help make this project better!

## Submitting pull requests

- Generally we welcome new features but please first open an issue where we
  can discuss whether it fits with our vision for the project.
- Any new feature or bug fix needs an accompanying test case.
- No need to add to the changelog, we will take care of updating it as we make
  releases.

## Running tests

`bundle exec rake` runs the suite against SQLite, PostgreSQL and MySQL in
parallel. PostgreSQL and MySQL are started as throwaway containers in Docker via
[Testcontainers](https://github.com/testcontainers/testcontainers-ruby).

```sh
bundle exec rake                           # all databases, in parallel
bundle exec rake spec:postgres             # a single database
```

`bundle exec rspec` runs against SQLite by default. Set `DB` to use a container,
or point `DATABASE_URL` at an existing database:

```sh
DB=postgres bundle exec rspec              # postgres:17
DB=mysql bundle exec rspec                 # mysql:8.4
DB=mysql DB_IMAGE=mysql:9.4 bundle exec rspec spec/statesman/machine_spec.rb
```

## Style

We use [Rubocop](https://github.com/bbatsov/rubocop) to help maintain a
consistent code style across the project. Please check that your pull
request passes by running `rubocop`.

## Documentation

Please add a section to [the readme](README.md) for any new feature additions or behavioural changes.

## Releasing

We publish new versions of Stateman using [RubyGems](https://guides.rubygems.org/publishing/). Once the relevant changes have been merged and `VERSION` has been appropriately bumped to the new version, we run the following command.

```sh
gem build statesman.gemspec
```

This builds a `.gem` file locally that will be named something like `statesman-X` where `X` is the new version. For example, if we are releasing version 9.0.0, the file would be
`statesman-9.0.0.gem`.

To publish, run `gem push` with the new `.gem` file we just generated. This requires a OTP that is currently only available
to GoCardless engineers. For example, if we were to continue to publish version 9.0.0, we would run:

```sh
gem push statesman-9.0.0.gem
```
