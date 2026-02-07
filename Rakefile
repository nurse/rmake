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
  desc "Build standalone rmake binary into dist/"
  task :rmake do
    run_cmd(RUBY, File.join(ROOT, "tools", "build_rmake.rb"))
  end

  desc "Build standalone rmake binary without mruby clean"
  task :rmake_no_clean do
    run_cmd(
      RUBY,
      File.join(ROOT, "tools", "build_rmake.rb"),
      env: { "RMAKE_NO_CLEAN" => "1" }
    )
  end
end

namespace :rmake do
  desc "Remove rmake build artifacts"
  task :clean do
    FileUtils.rm_rf(File.join(ROOT, "dist"))
    FileUtils.rm_rf(File.join(ROOT, "tmp", "rmake-build"))
  end
end

desc "Build standalone rmake binary"
task build: "build:rmake"

task default: :test
