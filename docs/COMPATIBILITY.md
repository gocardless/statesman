# Compatibility

Our goal as Statesman maintainers is for the library to be compatible with all supported versions of Ruby and Rails.

Specifically, any CRuby/MRI version that has not received an End of Life notice ([e.g. this notice for Ruby 2.1](https://www.ruby-lang.org/en/news/2017/04/01/support-of-ruby-2-1-has-ended/)) is supported. Similarly, any version of Rails listed as currently supported on [this page](http://guides.rubyonrails.org/maintenance_policy.html) is one we aim to support in Statesman.

To that end, [our build matrix](../.circleci/config.yml) includes all these versions.

Any time Statesman doesn't work on a supported combination of Ruby and Rails, it's a bug, and can be reported [here](https://github.com/gocardless/statesman/issues).

# Deprecation

Whenever a version of Ruby or Rails falls out of support, we will mirror that change in Statesman by updating the build matrix and releasing a new major version.

At that point, we will close any issues that only affect the unsupported version, and may choose to remove any workarounds from the code that are only necessary for the unsupported version.

We will then bump the major version of Statesman, to indicate the break in compatibility. Even if the new version of Statesman happens to work on the unsupported version of Ruby or Rails, we consider compatibility to be broken at this point.
