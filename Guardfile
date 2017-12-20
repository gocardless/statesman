# A sample Guardfile
# More info at https://github.com/guard/guard#readme

guard :rspec, all_on_start: true, cmd: "bundle exec rspec --color" do
  watch(%r{^spec/.+_spec\.rb$})
  watch(%r{^lib/(.+)\.rb$}) { |m| "spec/#{m[1]}_spec.rb" }
  watch("spec/spec_helper.rb") { "spec" }
end

guard :rubocop, all_on_start: true, cli: ["--format", "clang"] do
  watch(/.+\.rb$/)
  watch(%r{(?:.+/)?\.rubocop\.yml$}) { |m| File.dirname(m[0]) }
  watch(%r{(?:.+/)?\rubocop-todo\.yml$}) { |m| File.dirname(m[0]) }
end
