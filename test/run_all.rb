# frozen_string_literal: true

require "fileutils"
require "open3"
require "timeout"

ROOT = File.expand_path("..", __dir__)
TEST_DIR = File.join(ROOT, "test")
TMP_DIR = File.join(ROOT, "tmp")

GNU_MAKE_REPO = "https://github.com/mirror/make.git"
GNU_MAKE_DIR = File.join(TMP_DIR, "make-master")
GNU_MAKE_TESTS_DIR = File.join(GNU_MAKE_DIR, "tests")
GNU_CATEGORIES = %w[
  functions/file
  functions/shell
  options/dash-B
  options/dash-C
  options/dash-I
  options/dash-W
  options/dash-e
  options/dash-f
  options/dash-k
  options/dash-l
  options/dash-n
  options/dash-q
  options/dash-r
  options/dash-s
  options/dash-t
  options/general
  options/print-directory
].freeze

def run_step(name, cmd, chdir: ROOT, env: {}, timeout_sec: nil, progress_sec: nil)
  puts "==> #{name}"
  ok = true
  timed_out = false
  started = Time.now
  last_ping = started
  Open3.popen2e(env, *cmd, chdir: chdir) do |_stdin, out, wait_thr|
    begin
      _stdin.close
    rescue StandardError
    end
    loop do
      begin
        chunk = out.read_nonblock(4096)
        print chunk
        last_ping = Time.now
      rescue IO::WaitReadable
        if wait_thr.join(0.2)
          begin
            loop do
              chunk = out.read_nonblock(4096)
              print chunk
            end
          rescue IO::WaitReadable, EOFError
          end
          ok = wait_thr.value.success?
          break
        end
      rescue EOFError
        ok = wait_thr.value.success?
        break
      end

      if timeout_sec && timeout_sec > 0 && (Time.now - started) > timeout_sec
        timed_out = true
        ok = false
        begin
          Process.kill("TERM", wait_thr.pid)
        rescue StandardError
        end
        sleep 1
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue StandardError
        end
        break
      end

      if progress_sec && progress_sec > 0 && (Time.now - last_ping) > progress_sec
        elapsed = (Time.now - started).to_i
        puts "[progress] #{name} still running (#{elapsed}s)"
        last_ping = Time.now
      end
    end
  end
  warn "FAIL: #{name} (timeout after #{timeout_sec}s)" if timed_out
  unless ok
    warn "FAIL: #{name}"
    exit 1
  end
  puts
end

def cleanup_mruby_processes
  return unless system("which pkill >/dev/null 2>&1")
  if defined?(File::NULL)
    system("pkill", "-f", File.join(ROOT, "mruby", "bin", "mruby"), out: File::NULL, err: File::NULL)
  else
    system("pkill -f #{File.join(ROOT, 'mruby', 'bin', 'mruby')} >/dev/null 2>&1")
  end
end

def ensure_gnu_tests_tree
  env_dir = ENV["GNU_MAKE_TESTS_DIR"]
  if env_dir && !env_dir.empty?
    return env_dir if File.file?(File.join(env_dir, "run_make_tests.pl"))
    warn "FAIL: GNU_MAKE_TESTS_DIR is set but invalid: #{env_dir}"
    exit 1
  end

  return GNU_MAKE_TESTS_DIR if File.file?(File.join(GNU_MAKE_TESTS_DIR, "run_make_tests.pl"))

  if ENV.fetch("RMAKE_GNU_TESTS_FETCH", "1") == "0"
    warn "FAIL: GNU make tests are missing at #{GNU_MAKE_TESTS_DIR} and fetch is disabled"
    exit 1
  end

  FileUtils.mkdir_p(TMP_DIR)
  run_step("clone GNU make tests", ["git", "clone", "--depth=1", GNU_MAKE_REPO, GNU_MAKE_DIR], chdir: ROOT)
  unless File.file?(File.join(GNU_MAKE_TESTS_DIR, "run_make_tests.pl"))
    warn "FAIL: cloned repo does not contain tests/run_make_tests.pl"
    exit 1
  end
  GNU_MAKE_TESTS_DIR
end

def ensure_config_flags(tests_dir)
  path = File.join(tests_dir, "config-flags.pm")
  return if File.file?(path)
  File.write(path, <<~PM)
    # This is a -*-perl-*- script
    #
    # Set variables that were defined by configure, in case we need them
    # during the tests.

    %CONFIG_FLAGS = (
        AM_LDFLAGS      => '',
        AR              => '',
        CC              => '',
        CFLAGS          => '',
        CPP             => '',
        CPPFLAGS        => '',
        GUILE_CFLAGS    => '',
        GUILE_LIBS      => '',
        LDFLAGS         => '',
        LIBS            => '',
        USE_SYSTEM_GLOB => ''
    );

    1;
  PM
end

def run_all
  run_unit = ENV.fetch("RMAKE_RUN_UNIT", "1") != "0"
  run_micro = ENV.fetch("RMAKE_RUN_GMAKE_COMPAT", "1") != "0"
  run_gnu = ENV.fetch("RMAKE_RUN_GNU", "1") != "0"

  unless run_unit || run_micro || run_gnu
    warn "FAIL: all test sections are disabled"
    exit 1
  end

  run_step("unit/regression tests", ["ruby", File.join(TEST_DIR, "run.rb")], chdir: ROOT) if run_unit
  run_step("gmake micro compatibility tests", ["ruby", File.join(TEST_DIR, "run_gnumake_compat.rb")], chdir: ROOT) if run_micro

  return unless run_gnu

  tests_dir = ensure_gnu_tests_tree
  ensure_config_flags(tests_dir)
  cleanup_mruby_processes
  driver = File.join(TEST_DIR, "rmake-make-driver.pl")
  unless File.file?(driver)
    warn "FAIL: missing GNU test driver: #{driver}"
    exit 1
  end

  categories = ENV["RMAKE_GNU_CATEGORIES"]
  list = if categories && !categories.empty?
    categories.split(",").map(&:strip).reject(&:empty?)
  else
    GNU_CATEGORIES
  end
  run_step(
    "GNU run_make_tests.pl categories",
    ["perl", "run_make_tests.pl", "-make", driver, *list],
    chdir: tests_dir,
    env: { "RMAKE_JOBS" => ENV.fetch("RMAKE_JOBS", "1") },
    timeout_sec: ENV.fetch("RMAKE_GNU_TIMEOUT", "1200").to_i,
    progress_sec: ENV.fetch("RMAKE_GNU_PROGRESS_SEC", "20").to_i
  )
end

run_all
