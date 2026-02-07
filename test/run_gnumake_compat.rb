# frozen_string_literal: true

require "fileutils"
require "open3"
require "open-uri"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
RMAKE = [
  ENV.fetch("RMAKE_MRUBY", File.join(ROOT, "mruby", "bin", "mruby")),
  File.join(ROOT, "tools", "rmake"),
]
GMAKE = [ENV.fetch("GMAKE", "gmake")]
RUN_MAKE_TESTS_URLS = (
  ENV["RUN_MAKE_TESTS_URLS"] || ENV["RUN_MAKE_TESTS_URL"] || [
    "https://cgit.git.savannah.gnu.org/cgit/make.git/plain/tests/run_make_tests.pl",
    "https://raw.githubusercontent.com/mirror/make/master/tests/run_make_tests.pl",
  ].join(",")
).split(",").map(&:strip).reject(&:empty?)
RUN_MAKE_TESTS_PATH = File.join(ROOT, "tmp", "run_make_tests.pl")
RUN_MAKE_TESTS_FETCH = ENV.fetch("RUN_MAKE_TESTS_FETCH", "1") != "0"

Case = Struct.new(:name, :prepare, :args, :check, keyword_init: true)

def valid_run_make_tests?(path)
  File.file?(path) && File.size(path).to_i > 0
end

def fetch_run_make_tests(path, urls)
  FileUtils.mkdir_p(File.dirname(path))
  last_error = nil
  urls.each do |url|
    begin
      URI.open(url, "rb") do |io|
        File.open(path, "wb") do |f|
          f.write(io.read)
        end
      end
      File.chmod(0755, path)
      return path
    rescue StandardError => e
      last_error = e
    end
  end
  warn "FAIL: failed to fetch run_make_tests.pl from #{urls.join(', ')}"
  warn "FAIL: last error: #{last_error.class}: #{last_error.message}" if last_error
  exit 1
end

def resolve_run_make_tests(path, urls, allow_fetch)
  return path if valid_run_make_tests?(path)
  unless allow_fetch
    warn "FAIL: run_make_tests.pl not found at #{path} and fetch is disabled"
    exit 1
  end
  fetch_run_make_tests(path, urls)
end

def run_cmd(cmd, args, chdir:)
  out, err, st = Open3.capture3(*cmd, *args, chdir: chdir)
  { out: out, err: err, status: st.exitstatus }
end

def both_text(result)
  (result[:out] + result[:err]).gsub("\r\n", "\n")
end

def norm_line(line)
  s = line.to_s.strip
  s = s.tr("`", "'")
  s = s.gsub(/\s+/, " ") if s.start_with?("make")
  s
end

def lines(result)
  both_text(result).split("\n").map { |l| norm_line(l) }.reject(&:empty?)
end

def assert(name, ok, g:, r:)
  return if ok
  warn "FAIL: #{name}"
  warn "--- gmake (status=#{g[:status]}) ---"
  warn both_text(g)
  warn "--- rmake (status=#{r[:status]}) ---"
  warn both_text(r)
  exit 1
end

cases = []

cases << Case.new(
  name: "shell-newline",
  prepare: lambda do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      X := $(shell printf ' a\\nb\\n')
      all:
      \t@echo X=$(X)
    MK
  end,
  args: ["-f", "Makefile", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 && lines(g).last == lines(r).last
  end
)

cases << Case.new(
  name: "include-override",
  prepare: lambda do |dir|
    File.write(File.join(dir, "inc.mk"), "FOO = 3\n")
    File.write(File.join(dir, "Makefile"), <<~MK)
      include inc.mk
      all:
      \t@echo $(FOO)
    MK
  end,
  args: ["-f", "Makefile", "FOO=2", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 && lines(g).last == "2" && lines(r).last == "2"
  end
)

cases << Case.new(
  name: "missing-makefile-target",
  prepare: ->(_dir) {},
  args: ["all"],
  check: lambda do |g, r|
    lg = lines(g).join("\n")
    lr = lines(r).join("\n")
    g[:status] == 2 && r[:status] != 0 &&
      lg.include?("No rule to make target 'all'") &&
      lr.include?("No rule to make target 'all'")
  end
)

cases << Case.new(
  name: "missing-makefile-no-target",
  prepare: ->(_dir) {},
  args: [],
  check: lambda do |g, r|
    lg = lines(g).join("\n")
    lr = lines(r).join("\n")
    g[:status] == 2 && r[:status] != 0 &&
      lg.include?("No targets specified and no makefile found") &&
      lr.include?("No targets specified and no makefile found")
  end
)

cases << Case.new(
  name: "invalid-chdir",
  prepare: ->(_dir) {},
  args: ["-C", "no-such-dir"],
  check: lambda do |g, r|
    lg = lines(g).join("\n")
    lr = lines(r).join("\n")
    g[:status] == 2 && r[:status] != 0 &&
      lg.include?("no-such-dir: No such file or directory") &&
      lr.include?("no-such-dir: No such file or directory")
  end
)

cases << Case.new(
  name: "invalid-chdir-notdir",
  prepare: lambda do |dir|
    File.write(File.join(dir, "notdir"), "x")
  end,
  args: ["-C", "notdir"],
  check: lambda do |g, r|
    lg = lines(g).join("\n")
    lr = lines(r).join("\n")
    g[:status] == 2 && r[:status] != 0 &&
      lg.include?("notdir: Not a directory") &&
      lr.include?("notdir: Not a directory")
  end
)

cases << Case.new(
  name: "question-up-to-date",
  prepare: lambda do |dir|
    File.write(File.join(dir, "out"), "x\n")
    File.write(File.join(dir, "Makefile"), <<~MK)
      all: out
      out:
      \t@echo X > out
    MK
  end,
  args: ["-f", "Makefile", "-q", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 &&
      lines(g).empty? && lines(r).empty?
  end
)

cases << Case.new(
  name: "question-needs-build",
  prepare: lambda do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      all: out
      out:
      \t@echo X > out
    MK
  end,
  args: ["-f", "Makefile", "-q", "all"],
  check: lambda do |g, r|
    g[:status] == 1 && r[:status] == 1
  end
)

cases << Case.new(
  name: "include-remake",
  prepare: lambda do |dir|
    inc = File.join(dir, "inc.mk")
    stamp = File.join(dir, "stamp")
    File.write(inc, "FOO=old\n")
    File.write(stamp, "x\n")
    now = Time.now
    File.utime(now - 60, now - 60, inc)
    File.utime(now, now, stamp)
    File.write(File.join(dir, "Makefile"), <<~MK)
      include inc.mk
      inc.mk: stamp
      \techo FOO=new > inc.mk
      all:
      \t@echo $(FOO)
    MK
  end,
  args: ["-f", "Makefile", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 &&
      lines(g).last == "new" && lines(r).last == "new"
  end
)

cases << Case.new(
  name: "include-phony-once",
  prepare: lambda do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      SHOWFLAGS = showflags
      -include $(SHOWFLAGS)
      all: $(SHOWFLAGS)
      .PHONY: showflags
      showflags:
      \t@echo A=1
    MK
  end,
  args: ["-f", "Makefile", "-n", "all"],
  check: lambda do |g, r|
    lg = lines(g)
    lr = lines(r)
    g[:status] == 0 && r[:status] == 0 &&
      lg.count("echo A=1") == 1 && lr.count("echo A=1") == 1
  end
)

cases << Case.new(
  name: "revision-like-target",
  prepare: lambda do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      .SUFFIXES: .c .o
      .revision.time:
      \t@echo REVISION
      all: .revision.time
    MK
  end,
  args: ["-f", "Makefile", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 &&
      lines(g).last == "REVISION" && lines(r).last == "REVISION"
  end
)

cases << Case.new(
  name: "suffix-asm-rule",
  prepare: lambda do |dir|
    File.write(File.join(dir, "foo.S"), ".text\n")
    File.write(File.join(dir, "Makefile"), <<~MK)
      .SUFFIXES: .S .o
      SYMBOL_PREFIX = _
      PREFIXED_SYMBOL = name
      _PREFIXED_SYMBOL = TOKEN_PASTE($(SYMBOL_PREFIX),name)
      .S.o:
      \t@echo "-DPREFIXED_SYMBOL(name)=$($(SYMBOL_PREFIX)PREFIXED_SYMBOL)"
      all: foo.o
    MK
  end,
  args: ["-f", "Makefile", "all"],
  check: lambda do |g, r|
    g[:status] == 0 && r[:status] == 0 &&
      lines(g).last == lines(r).last &&
      lines(r).last.include?("-DPREFIXED_SYMBOL(name)=TOKEN_PASTE(_,name)")
  end
)

run_make_tests = resolve_run_make_tests(
  RUN_MAKE_TESTS_PATH,
  RUN_MAKE_TESTS_URLS,
  RUN_MAKE_TESTS_FETCH
)
unless valid_run_make_tests?(run_make_tests)
  warn "FAIL: run_make_tests.pl is empty: #{run_make_tests}"
  exit 1
end

cases.each do |kase|
  Dir.mktmpdir("rmake-gmake-") do |dir|
    kase.prepare.call(dir)
    g = run_cmd(GMAKE, kase.args, chdir: dir)
    r = run_cmd(RMAKE, kase.args, chdir: dir)
    assert(kase.name, kase.check.call(g, r), g: g, r: r)
  end
end

puts "OK (#{cases.length} gmake-compat cases)"
