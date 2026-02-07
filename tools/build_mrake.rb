# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"

ROOT = File.expand_path("..", __dir__)
MRUBY_DIR = File.join(ROOT, "mruby")
DIST_DIR = File.join(ROOT, "dist")
TMP_DIR = File.join(ROOT, "tmp", "mrake-build")
MRUBY_CONFIG = File.join(ROOT, "tools", "mrake_mruby_config.rb")
MAIN_C = File.join(ROOT, "tools", "mrake_main.c")
BUNDLE_RB = File.join(TMP_DIR, "mrake_bundle.rb")
BUNDLE_C = File.join(TMP_DIR, "mrake_bundle.c")
MRBC_REL = File.join("build", "host", "mrbc", "bin")
LIBMRUBY_REL = File.join("build", "host", "lib", "libmruby.a")
BUILD_INCLUDE_REL = File.join("build", "host", "include")

RMAKE_SOURCES = %w[
  mrblib/rmake/util.rb
  mrblib/rmake/parser.rb
  mrblib/rmake/evaluator.rb
  mrblib/rmake/graph.rb
  mrblib/rmake/executor.rb
  mrblib/rmake/shell.rb
  mrblib/rmake/cli.rb
].freeze

def run!(*cmd, chdir: nil, env: {})
  line = cmd.join(" ")
  puts "+ #{line}"
  ok = system(env, *cmd, chdir: chdir)
  return if ok

  abort("command failed: #{line}")
end

def host_os
  RbConfig::CONFIG["host_os"].to_s
end

def host_cpu
  RbConfig::CONFIG["host_cpu"].to_s
end

def exe_ext
  host_os =~ /mswin|mingw|cygwin/ ? ".exe" : ""
end

def normalized_os
  os = host_os
  return "windows" if os =~ /mswin|mingw|cygwin/
  return "macos" if os =~ /darwin/
  return "linux" if os =~ /linux/

  os.gsub(/[^a-zA-Z0-9]+/, "-")
end

def normalized_arch
  cpu = host_cpu.downcase
  return "x86_64" if %w[x86_64 amd64].include?(cpu)
  return "arm64" if %w[arm64 aarch64].include?(cpu)

  cpu.gsub(/[^a-zA-Z0-9]+/, "-")
end

def output_name
  tag = ENV["MRAKE_OUT_TAG"].to_s
  tag = "#{normalized_os}-#{normalized_arch}" if tag.empty?
  "mrake-#{tag}#{exe_ext}"
end

def write_bundle!
  FileUtils.mkdir_p(TMP_DIR)
  File.open(BUNDLE_RB, "w") do |f|
    f.puts("# frozen_string_literal: true")
    f.puts
    f.puts("module RMake")
    f.puts("end")
    f.puts
    RMAKE_SOURCES.each do |rel|
      path = File.join(ROOT, rel)
      f.puts("# --- #{rel} ---")
      f.puts(File.read(path))
      f.puts
    end
    f.puts("RMake::CLI.run(ARGV)")
  end
end

def build_mruby!
  env = { "MRUBY_CONFIG" => MRUBY_CONFIG }
  run!("rake", "clean", chdir: MRUBY_DIR, env: env) if ENV["MRAKE_NO_CLEAN"] != "1"
  run!("rake", chdir: MRUBY_DIR, env: env)
end

def mrbc_path
  candidates = [
    File.join(MRUBY_DIR, MRBC_REL, "mrbc#{exe_ext}"),
    File.join(MRUBY_DIR, "bin", "mrbc#{exe_ext}"),
  ]
  path = candidates.find { |p| File.exist?(p) }
  abort("mrbc not found under #{MRUBY_DIR}") unless path

  path
end

def compile_irep!
  run!(mrbc_path, "-B", "mrake_app", "-o", BUNDLE_C, BUNDLE_RB, chdir: ROOT)
end

def compile_binary!
  FileUtils.mkdir_p(DIST_DIR)
  cc = ENV["CC"].to_s
  cc = RbConfig::CONFIG["CC"].to_s if cc.empty?
  cc = "cc" if cc.empty?
  cc_parts = Shellwords.split(cc)

  out = File.join(DIST_DIR, output_name)
  includes = [
    "-I#{File.join(MRUBY_DIR, "include")}",
    "-I#{File.join(MRUBY_DIR, BUILD_INCLUDE_REL)}",
  ]
  args = [
    *cc_parts,
    "-O2",
    *includes,
    MAIN_C,
    BUNDLE_C,
    File.join(MRUBY_DIR, LIBMRUBY_REL),
    "-o",
    out,
  ]

  libs = RbConfig::CONFIG["LIBS"].to_s.split
  args.concat(libs)
  args << "-lm" unless libs.include?("-lm")
  args.concat(ENV["MRAKE_EXTRA_LDFLAGS"].to_s.split)

  run!(*args, chdir: ROOT)

  strip = ENV["STRIP"].to_s
  strip = "strip" if strip.empty?
  system(strip, out) unless host_os =~ /mswin|mingw|cygwin/

  puts "built: #{out}"
end

write_bundle!
build_mruby!
compile_irep!
compile_binary!
