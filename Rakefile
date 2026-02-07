# frozen_string_literal: true

require "fileutils"
require "rbconfig"

ROOT = File.expand_path(__dir__)
RUBY = RbConfig.ruby

def run_cmd(*cmd, env: {}, chdir: ROOT)
  line = cmd.join(" ")
  puts "+ #{line}"
  ok = system(env, *cmd, chdir: chdir)
  return if ok

  abort("command failed: #{line}")
end

namespace :test do
  desc "Run local regression tests (test/run.rb)"
  task :unit do
    run_cmd(RUBY, File.join(ROOT, "test", "run.rb"))
  end

  desc "Run gmake micro compatibility tests (test/run_gnumake_compat.rb)"
  task :micro do
    run_cmd(RUBY, File.join(ROOT, "test", "run_gnumake_compat.rb"))
  end

  desc "Run GNU run_make_tests.pl categories only"
  task :gnu do
    run_cmd(
      RUBY,
      File.join(ROOT, "test", "run_all.rb"),
      env: {
        "RMAKE_RUN_UNIT" => "0",
        "RMAKE_RUN_GMAKE_COMPAT" => "0",
        "RMAKE_RUN_GNU" => "1",
      }
    )
  end

  desc "Run unit + gmake micro tests (skip GNU categories)"
  task :fast do
    run_cmd(
      RUBY,
      File.join(ROOT, "test", "run_all.rb"),
      env: {
        "RMAKE_RUN_UNIT" => "1",
        "RMAKE_RUN_GMAKE_COMPAT" => "1",
        "RMAKE_RUN_GNU" => "0",
      }
    )
  end

  desc "Run integrated test suite (unit + gmake micro + GNU categories)"
  task :all do
    run_cmd(RUBY, File.join(ROOT, "test", "run_all.rb"))
  end
end

desc "Run integrated test suite"
task test: "test:all"

namespace :build do
  desc "Build standalone mrake binary into dist/"
  task :mrake do
    run_cmd(RUBY, File.join(ROOT, "tools", "build_mrake.rb"))
  end

  desc "Build standalone mrake binary without mruby clean"
  task :mrake_no_clean do
    run_cmd(
      RUBY,
      File.join(ROOT, "tools", "build_mrake.rb"),
      env: { "MRAKE_NO_CLEAN" => "1" }
    )
  end
end

namespace :mrake do
  desc "Remove mrake build artifacts"
  task :clean do
    FileUtils.rm_rf(File.join(ROOT, "dist"))
    FileUtils.rm_rf(File.join(ROOT, "tmp", "mrake-build"))
  end
end

desc "Build standalone mrake binary"
task build: "build:mrake"

task default: :test
