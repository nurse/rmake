# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "open3"
require "json"

ROOT = File.expand_path(__dir__)
RUBY = RbConfig.ruby

def run_cmd(*cmd, env: {}, chdir: ROOT)
  line = cmd.join(" ")
  puts "+ #{line}"
  ok = system(env, *cmd, chdir: chdir)
  return if ok

  abort("command failed: #{line}")
end

def capture_cmd(*cmd, chdir: ROOT)
  line = cmd.join(" ")
  puts "+ #{line}"
  out, status = Open3.capture2e(*cmd, chdir: chdir)
  ok = status.success?
  abort("command failed: #{line}\n#{out}") unless ok

  out
end

def latest_tag
  tags = `git tag --list --sort=version:refname`.split("\n")
  tags.last
end

def next_patch_tag(from_tag)
  base = from_tag.to_s.strip
  base = "v0.0.0" if base.empty?
  m = /\Av(\d+)\.(\d+)\.(\d+)\z/.match(base)
  abort("unsupported tag format: #{base}") unless m

  major = m[1].to_i
  minor = m[2].to_i
  patch = m[3].to_i + 1
  "v#{major}.#{minor}.#{patch}"
end

def wait_for_actions_run(tag, timeout: 1800, poll: 10)
  started = Time.now
  loop do
    out = capture_cmd(
      "gh", "run", "list",
      "--workflow", "Build rmake",
      "--branch", tag,
      "--limit", "1",
      "--json", "databaseId,status,conclusion"
    ).strip
    if out.start_with?("[") && !out.empty? && out != "[]"
      run = begin
        JSON.parse(out).first
      rescue StandardError
        nil
      end
      if run && run["databaseId"]
        run_id = run["databaseId"].to_s
        status = run["status"].to_s
        conclusion = run["conclusion"].to_s
        return run_id if status == "completed" && conclusion == "success"
        abort("Build rmake failed for #{tag}: status=#{status} conclusion=#{conclusion}") if status == "completed"
      end
    end
    if Time.now - started > timeout
      abort("timeout waiting for Build rmake run for #{tag}")
    end
    sleep poll
  end
end

def download_actions_artifacts(run_id)
  tmp = Dir.mktmpdir("rmake-release-artifacts-")
  run_cmd("gh", "run", "download", run_id.to_s, "-D", tmp)
  files = Dir.glob(File.join(tmp, "**", "*")).select { |p| File.file?(p) }
  abort("no artifacts downloaded for run #{run_id}") if files.empty?

  [tmp, files]
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

namespace :release do
  desc "Create next patch release from current working tree and attach Actions artifacts"
  task :publish do
    status = `git status --porcelain`.strip
    abort("working tree is clean; nothing to release") if status.empty?

    tag = ENV["VERSION"].to_s
    tag = next_patch_tag(latest_tag) if tag.empty?
    abort("VERSION must start with v (e.g. v0.0.9)") unless tag.start_with?("v")

    run_cmd("git", "add", "-A")
    run_cmd("git", "commit", "-m", "Release #{tag}")
    run_cmd("git", "tag", tag)
    run_cmd("git", "push", "origin", "master", tag)

    run_id = wait_for_actions_run(tag)
    tmp, files = download_actions_artifacts(run_id)
    begin
      run_cmd("gh", "release", "create", tag, "--generate-notes", "--title", tag)
      run_cmd("gh", "release", "upload", tag, *files, "--clobber")
    ensure
      FileUtils.rm_rf(tmp)
    end
  end
end

desc "Commit, tag, push, and create GitHub Release with Actions artifacts"
task release: "release:publish"

task default: :test
