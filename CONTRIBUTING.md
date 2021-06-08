Thanks for taking an interest in contributing to Statesman, here are a few
ways you can help make this project better!

## Contributing

- Generally we welcome new features but please first open an issue where we 
  can discuss whether it fits with our vision for the project.
- Any new feature or bug fix needs an accompanying test case.
- No need to add to the changelog, we will take care of updating it as we make
  releases.

## Style

We use [Rubocop](https://github.com/bbatsov/rubocop) to help maintain a
consistent code style across the project. Please check that your pull
request passes by running `rubocop`.

## Documentation

Please add a section to the readme for any new feature additions or behaviour
changes.

## Releasing

We publish new versions of Stateman using [RubyGems](https://guides.rubygems.org/publishing/). Once
the relevant changes have been merged and `VERSION` has been appropriately bumped to the new
version, we run the following command.
```
$ gem build statesman.gemspec
```
This builds a `.gem` file locally that will be named something like `statesman-X` where `X` is the
new version. For example, if we are releasing version 9.0.0, the file would be
`statesman-9.0.0.gem`.

To publish, run `gem push` with the new `.gem` file we just generated. This requires a OTP that is currently only available
to GoCardless engineers. For example, if we were to continue to publish version 9.0.0, we would run:
```
$ gem push statesman-9.0.0.gem
```
