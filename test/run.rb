# frozen_string_literal: true

require "stringio"
require "tmpdir"

require_relative "../mrblib/rmake/util"
require_relative "../mrblib/rmake/parser"
require_relative "../mrblib/rmake/evaluator"
require_relative "../mrblib/rmake/graph"
require_relative "../mrblib/rmake/shell"
require_relative "../mrblib/rmake/executor"
require_relative "../mrblib/rmake/cli"

class TestFailure < StandardError; end

def assert(name, cond)
  raise TestFailure, name unless cond
end

def parse_eval(str)
  io = StringIO.new(str)
  lines = RMake::Parser.new(io, "<test>").parse
  RMake::Evaluator.new(lines).tap(&:evaluate)
end

def capture_io
  orig_out = $stdout
  orig_err = $stderr
  out = StringIO.new
  err = StringIO.new
  $stdout = out
  $stderr = err
  yield
  [out.string, err.string]
ensure
  $stdout = orig_out
  $stderr = orig_err
end

def with_env(key, value)
  had = Object.const_defined?(:ENV) && ENV.key?(key)
  prev = ENV[key] if had
  ENV[key] = value
  yield
ensure
  if had
    ENV[key] = prev
  else
    ENV.delete(key)
  end
end

tests = []

tests << lambda do
  ev = parse_eval(<<~MK)
    .c.o:
\t@echo compiling $<
  MK
  suffix = ev.suffix_rules.map { |r| r[0..1].join("->") }
  assert("suffix rule .c->.o detected", suffix.include?(".c->.o"))
  assert("no explicit rule for .c.o", ev.rules.none? { |r| r.targets.include?(".c.o") })
end

tests << lambda do
  ev = parse_eval(<<~MK)
    .rbconfig.time: $(PREP)
\t@echo generating $@
  MK
  suffix_targets = ev.suffix_rules.map { |r| ".#{r[0][1..]}#{r[1]}" }
  assert("non-suffix rule preserved", ev.rules.any? { |r| r.targets.include?(".rbconfig.time") })
  assert("not treated as suffix", suffix_targets.none? { |t| t == ".rbconfig.time" })
end

tests << lambda do
  ev = parse_eval(<<~MK)
ifeq (yes,no)
foo:
\t@echo nope
endif
ifeq (yes,yes)
bar:
\t@echo ok
endif
  MK
  assert("conditional false excluded", ev.rules.none? { |r| r.targets.include?("foo") })
  assert("conditional true included", ev.rules.any? { |r| r.targets.include?("bar") })
end

tests << lambda do
  ev = parse_eval(<<~MK)
ifeq (yes,yes)
baz:
\t@echo first
\t@echo second
endif
  MK
  rule = ev.rules.find { |r| r.targets.include?("baz") }
  assert("recipe preserved under condition", rule && rule.recipe.length == 2)
end

tests << lambda do
  silent, ignore, cmd = RMake::Util.strip_cmd_prefixes("  @- echo hi")
  assert("strip_cmd_prefixes silent", silent)
  assert("strip_cmd_prefixes ignore", ignore)
  assert("strip_cmd_prefixes cmd", cmd == "echo hi")
end

tests << lambda do
  line = "FOO=bar"
  assert("strip_comments no hash", RMake::Util.strip_comments(line) == line)
end

tests << lambda do
  parts = RMake::Util.split_ws("token")
  assert("split_ws single token", parts == ["token"])
end

tests << lambda do
  out = RMake::Util.expand("plain", {}, {})
  assert("expand no dollar", out == "plain")
end

tests << lambda do
  ev = parse_eval(<<~MK)
.c.o:
\t@echo suffix
all:
\t@echo ok
  MK
  g = RMake::Graph.new
  ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
  target = RMake::CLI.default_target("", ev, g)
  assert("default target skips dot", target == "all")
end

tests << lambda do
  ev = parse_eval(<<~MK)
.SUFFIXES:
.c.o:
\t@echo suffix
  MK
  g = RMake::Graph.new
  ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
  target = RMake::CLI.default_target("", ev, g)
  ok = target.nil? || target.start_with?(".")
  assert("default target falls back to dot or nil when only dot targets", ok)
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "all:\n")
    File.write(File.join(dir, "all"), "")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile"])
      end
    end
    assert("nothing to be done emitted", out.include?("Nothing to be done for `all'."))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), ".SUFFIXES:\n")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile"])
      end
    end
    assert("no nothing-to-be-done for dot target", !out.include?("Nothing to be done"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
foo.bar:
\techo $(*F) $(*D)
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "foo.bar"])
      end
    end
    assert("*F expands basename", out.include?("foo"))
    assert("*D expands dir", out.include?(".")) 
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "all:\n")
    File.write(File.join(dir, "all"), "")
    out, _err = capture_io do
      Dir.chdir(dir) do
        with_env("MAKELEVEL", "1") do
          RMake::CLI.run(["-f", "Makefile"])
        end
      end
    end
    assert("makelevel prefix", out.include?("make[1]: Nothing to be done for `all'."))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "miniruby:\n")
    File.write(File.join(dir, "miniruby"), "")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "miniruby"])
      end
    end
    assert("explicit target up to date", out.include?("`miniruby' is up to date."))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
V = 0
V0 = $(V:0=)
Q1 = $(V:1=)
Q = $(Q1:0=@)
ECHO1 = $(V:1=@:)
ECHO = $(ECHO1:0=@echo)
all:
\t$(ECHO) MSG
\t$(Q) echo CMD
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("V=0 prints echo MSG", out.include?("echo MSG"))
    assert("V=0 prints echo CMD", out.include?("echo CMD"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
V = 1
V0 = $(V:0=)
Q1 = $(V:1=)
Q = $(Q1:0=@)
ECHO1 = $(V:1=@:)
ECHO = $(ECHO1:0=@echo)
all:
\t$(ECHO) MSG
\t$(Q) echo CMD
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("V=1 prints : MSG", out.include?(": MSG"))
    assert("V=1 prints echo CMD", out.include?("echo CMD"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
V = 1
all:
\t@echo HUSH
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("@ still prints command with -n", out.include?("echo HUSH"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "all: missing\n")
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("missing dep returns failure", status == 2)
      end
    end
    combined = out + err
    assert("missing dep message", combined.include?("No rule to make target `missing'"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
.PHONY: PHONY
PHONY:
all: PHONY
\techo RUN
    MK
    File.write(File.join(dir, "all"), "")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("phony dep forces rebuild", out.include?("echo RUN"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all:
\techo RUN
    MK
    File.write(File.join(dir, "all"), "")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("no phony dep keeps up-to-date", !out.include?("echo RUN"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all:
\techo $(MFLAGS)
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        with_env("RMAKE_JOBS", "3") do
          RMake::CLI.run(["-f", "Makefile", "-n", "all"])
        end
      end
    end
    assert("default jobs from RMAKE_JOBS", out.include?("-j3"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all: src.txt
\techo OK
    MK
    File.write(File.join(dir, "src.txt"), "x")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "-j2", "all"])
      end
    end
    assert("parallel scheduler ignores file deps", out.include?("echo OK"))
  end
end

failures = []
tests.each_with_index do |t, i|
  begin
    t.call
  rescue TestFailure => e
    failures << "test #{i + 1}: #{e.message}"
  end
end

if failures.empty?
  puts "OK (#{tests.length} tests)"
  exit 0
else
  warn failures.join("\n")
  exit 1
end
