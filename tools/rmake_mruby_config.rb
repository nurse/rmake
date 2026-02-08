MRuby::Build.new("host") do |conf|
  tool = ENV["RMAKE_TOOLCHAIN"].to_s
  if !tool.empty?
    conf.toolchain tool.to_sym
  elsif RUBY_PLATFORM =~ /darwin/
    conf.toolchain :clang
  else
    conf.toolchain :gcc
  end

  conf.gem core: "mruby-bin-mrbc"
  conf.gem core: "mruby-bin-mruby"
  conf.gem core: "mruby-eval"
  conf.gem core: "mruby-struct"
  conf.gem core: "mruby-errno"
  conf.gem core: "mruby-string-ext"
  conf.gem core: "mruby-fiber"
  conf.gem core: "mruby-enumerator"
  conf.gem core: "mruby-hash-ext"
  conf.gem core: "mruby-kernel-ext"
  conf.gem core: "mruby-object-ext"
  conf.gem core: "mruby-metaprog"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-dir"
  conf.gem gemdir: "#{__dir__}/../mruby/mrbgems/mruby-process"
  conf.gem gemdir: "#{__dir__}/../mruby/mrbgems/mruby-file-stat"
end
