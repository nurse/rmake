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
.SUFFIXES: .c .o
.revision.time:
\t@echo revision
  MK
  suffix = ev.suffix_rules.map { |r| r[0..1].join("->") }
  assert("unknown suffix pair is not suffix rule", suffix.none? { |x| x == ".revision->.time" })
  assert("unknown suffix pair kept as normal rule", ev.rules.any? { |r| r.targets.include?(".revision.time") })
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
  silent, ignore, force, cmd = RMake::Util.strip_cmd_prefixes("  @- echo hi")
  assert("strip_cmd_prefixes silent", silent)
  assert("strip_cmd_prefixes ignore", ignore)
  assert("strip_cmd_prefixes force", !force)
  assert("strip_cmd_prefixes cmd", cmd == "echo hi")
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
    script = File.join(dir, "make.sh")
    out_path = File.join(dir, "out.txt")
    File.write(script, "#!/bin/sh\necho CLEAN >> #{out_path}\n")
    File.chmod(0755, script)

    ev = parse_eval(<<~MK)
clean:
\t@$(MAKE)
    MK
    ev.vars["MAKE"] = RMake::Evaluator::Var.simple(script)

    g = RMake::Graph.new
    ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
    shell = RMake::Shell.new(true)
    exec = RMake::Executor.new(g, shell, ev.vars)
    with_env("MAKE", "") do
      exec.build("clean")
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("dry-run executes recursive command", content.include?("CLEAN"))
  end
end

tests << lambda do
  ev = parse_eval(<<~MK)
ext/clean.sub:
\t@echo $(@D) $(@F) $(@F:.sub=)
  MK
  g = RMake::Graph.new
  ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
  exec = RMake::Executor.new(g, RMake::Shell.new(true), ev.vars)
  node = g.node("ext/clean.sub")
  ctx = exec.send(:auto_vars, node)
  out = RMake::Util.expand("$(@D) $(@F) $(@F:.sub=)", ev.vars, ctx)
  assert("auto vars expand for @D/@F", out == "ext clean.sub clean")
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    make_path = File.join(dir, "make.sh")
    out_path = File.join(dir, "calls.txt")
    File.write(make_path, "#!/bin/sh\necho \"PWD=$(pwd) ARGS=$@\" >> #{out_path}\n")
    File.chmod(0755, make_path)

    ev = parse_eval(<<~MK)
ext/clean.sub:
\t@echo $(@F:.sub=)ing "$(@D)"
\t@$(MAKE) $(@F:.sub=)
    MK
    ev.vars["MAKE"] = RMake::Evaluator::Var.simple(make_path)

    g = RMake::Graph.new
    ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
    shell = RMake::Shell.new(true)
    exec = RMake::Executor.new(g, shell, ev.vars)
    with_env("MAKE", "") do
      exec.build("ext/clean.sub")
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("recursive make uses correct @F target", content.include?("clean"))
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
  out = RMake::Util.normalize_shell_output(" a\nb\n")
  assert("shell output keeps leading ws, replaces newlines", out == " a b")
end

tests << lambda do
  src = "FOO := $(shell echo '#') # tail"
  got = RMake::Util.strip_comments(src)
  assert("strip_comments keeps # inside function args", got.include?("echo '#'"))
  assert("strip_comments strips trailing comment", !got.include?("tail"))
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out_path = File.join(dir, "out.txt")
    mk = <<~MK
      .PHONY: all
      PRE := $(.SHELLSTATUS)
      $(shell exit 0)
      OK := $(.SHELLSTATUS)
      $(shell exit 1)
      BAD := $(.SHELLSTATUS)
      all: ; @echo PRE=$(PRE) OK=$(OK) BAD=$(BAD) > #{out_path}
    MK
    File.write(File.join(dir, "Makefile"), mk)
    Dir.chdir(dir) do
      status = RMake::CLI.run(["-f", "Makefile", "all"])
      assert("shellstatus target success", status == 0)
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("shellstatus values", content.include?("PRE= OK=0 BAD=1"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out_path = File.join(dir, "out.txt")
    File.write(File.join(dir, "Makefile"), <<~MK)
      FOO = bar
      OUT = $(shell echo $$FOO)
      all: ; @echo '$(OUT)' > #{out_path}
    MK
    with_env("FOO", "baz") do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("shell env override target success", status == 0)
      end
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("shell sees make override of env key", content.include?("bar"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out_path = File.join(dir, "out.txt")
    File.write(File.join(dir, "Makefile"), <<~MK)
      HI = $(shell echo hi)
      .PHONY: all
      all: ; @echo $$HI > #{out_path}
    MK
    with_env("HI", "foo") do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("recipe env target success", status == 0)
      end
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("recipe sees make override of env key", content.include?("hi"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    file_path = File.join(dir, "x.out")
    out_path = File.join(dir, "out.txt")
    File.write(File.join(dir, "Makefile"), <<~MK)
      $(file >#{file_path},hello)
      X := x$(file <#{file_path})y
      all: ; @echo $(X) > #{out_path}
    MK
    Dir.chdir(dir) do
      status = RMake::CLI.run(["-f", "Makefile", "all"])
      assert("file function target success", status == 0)
    end
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("file function read/write", content.include?("xhelloy"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "$(file foo)\nall: ; @:\n")
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("file invalid op returns failure", status == 2)
      end
    end
    combined = out + err
    assert("file invalid op message", combined.include?("file: invalid file operation"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    sub = File.join(dir, "sub")
    Dir.mkdir(sub)
    out_path = File.join(sub, "out.txt")
    File.write(File.join(sub, "Makefile"), "all:\n\t@echo SUB > #{out_path}\n")
    RMake::CLI.run(["-C", sub, "all"])
    content = File.exist?(out_path) ? File.read(out_path) : ""
    assert("chdir option runs in subdir", content.include?("SUB"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-C", "no-such-dir", "all"])
        assert("chdir invalid returns failure", status == 2)
      end
    end
    combined = out + err
    assert("chdir invalid error message", combined.include?("*** -C no-such-dir"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    file_path = File.join(dir, "notdir")
    File.write(file_path, "x")
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-C", file_path, "all"])
        assert("chdir file path returns failure", status == 2)
      end
    end
    combined = out + err
    assert("chdir file path reports not a directory", combined.include?("Not a directory"))
  end
end

tests << lambda do
  ev = RMake::Evaluator.new([])
  opts, _jobs_set = RMake::CLI.parse_args(["-j4"])
  RMake::CLI.set_make_vars(ev, "make", opts)
  mflags = ev.vars["mflags"].value
  assert("mflags mirrors MFLAGS", mflags.include?("-j4"))
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    Dir.chdir(dir) do
      dep = "dep.txt"
      tgt = "tgt.txt"
      File.write(dep, "a")
      File.write(tgt, "b")
      File.utime(Time.now, Time.now + 10, dep)
      File.utime(Time.now, Time.now, tgt)

      g = RMake::Graph.new
      rule = RMake::Evaluator::Rule.new([tgt], [dep], [], ["echo RUN"], false)
      g.add_rule(rule, phony: false, precious: false)
      shell = RMake::Shell.new(true)
      exec = RMake::Executor.new(g, shell, {})
      node = g.node(tgt)

      assert("dep newer triggers rebuild", exec.send(:need_build?, node))
      exec.instance_variable_get(:@restat_no_change)[dep] = true
      assert("restat skips dep", !exec.send(:need_build?, node))
    end
  end
end

tests << lambda do
  ev = parse_eval(<<~MK)
TARGET_SO =
clean-local: $(TARGET_SO)
\t@echo clean
  MK
  rule = ev.rules.find { |r| r.targets.include?("clean-local") }
  assert("empty variable prereq is dropped", rule.prereqs.empty?)
end

tests << lambda do
  ev = parse_eval(<<~MK)
foo: BAR = baz
foo:
\t@echo $(BAR)
  MK
  vars = ev.target_vars["foo"]
  assert("target-specific var stored", vars && vars["BAR"] && vars["BAR"].value == "baz")
  rule = ev.rules.find { |r| r.targets.include?("foo") }
  assert("rule still parsed for target", !rule.nil?)
end

tests << lambda do
  with_env("MAKE", "/tmp/mruby /tmp/rmake") do
    ev = parse_eval(<<~MK)
reconfig config.status: export MAKE:=$(MAKE)
reconfig config.status:
\t@echo RECHECK
    MK
    tvars = ev.target_vars["config.status"]
    assert("target-specific export assignment parsed", tvars && tvars["MAKE"])
    g = RMake::Graph.new
    ev.rules.each { |r| g.add_rule(r, phony: false, precious: false) }
    node = g.node("config.status")
    assert("no bogus prereq from spaced MAKE", node && !node.deps.include?("/tmp/rmake"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all: foo ./foo
\techo ALL
foo:
\techo FOO
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    foo_count = out.scan(/^echo FOO$/).length
    all_count = out.scan(/^echo ALL$/).length
    assert("duplicate deps only execute once", foo_count == 1)
    assert("top-level recipe still runs", all_count == 1)
  end
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["MAKEFLAGS=-j7", "all"])
  assert("parse_args jobs from MAKEFLAGS assignment", opts[:jobs] == 7)
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["MAKEFLAGS=-n", "all"])
  assert("parse_args dry_run from MAKEFLAGS assignment", opts[:dry_run])
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["hello:=cmd", "hello+=cmd2", "all"])
  assigns = opts[:var_assigns]
  ok = assigns.include?(["hello", ":=", "cmd"]) && assigns.include?(["hello", "+=", "cmd2"])
  assert("parse_args supports := and +=", ok)
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["-e", "all"])
  assert("parse_args environment override flag", opts[:env_override])
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["-s", "all"])
  assert("parse_args silent mode", opts[:silent])
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["-q", "all"])
  assert("parse_args question mode", opts[:question])
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
hello+=blue
hello+=yellow
$(info $(hello))
phobos:; $(info $(hello))
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "hello:=cmd", "hello+=cmd2", "phobos"])
        assert("command line := += status", status == 0)
      end
    end
    lines = out.split("\n").map(&:strip).reject(&:empty?)
    assert("command line := += parse-time", lines.include?("cmd cmd2"))
    assert("command line := += build-time", lines.count("cmd cmd2") >= 2)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
phobo%: hello+=blue
phobos: hello+=yellow
$(info $(hello))
phobos:; $(info $(hello))
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "phobos"])
        assert("pattern target var status", status == 0)
      end
    end
    lines = out.split("\n").map(&:strip)
    assert("pattern target var applies at build", lines.include?("blue yellow"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
mars: hello+=blue
phobos:; $(info $(hello))
mars: phobos; $(info $(hello))
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "mars"])
        assert("prereq inherits target-specific vars status", status == 0)
      end
    end
    lines = out.split("\n").map(&:strip).reject(&:empty?)
    assert("prereq inherits target-specific vars", lines.count("blue") >= 2)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
HELLO=file
$(info $(HELLO))
all:; $(info $(HELLO))
    MK
    with_env("HELLO", "env") do
      out1, _err1 = capture_io do
        Dir.chdir(dir) do
          RMake::CLI.run(["-f", "Makefile", "all"])
        end
      end
      out2, _err2 = capture_io do
        Dir.chdir(dir) do
          RMake::CLI.run(["-f", "Makefile", "-e", "all"])
        end
      end
      lines1 = out1.split("\n").map(&:strip).reject(&:empty?)
      lines2 = out2.split("\n").map(&:strip).reject(&:empty?)
      assert("env without -e is overridden by makefile", lines1.include?("file"))
      assert("env with -e overrides makefile", lines2.include?("env"))
    end
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all: out
out:
\t@echo OUT > out
    MK
    File.write(File.join(dir, "out"), "OUT\n")
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-q", "all"])
        assert("question mode up-to-date returns success", status == 0)
      end
    end
    assert("question mode up-to-date quiet", (out + err).strip.empty?)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all: out
out:
\t@echo OUT > out
    MK
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-q", "all"])
        assert("question mode needs rebuild returns 1", status == 1)
      end
    end
    assert("question mode rebuild quiet", (out + err).strip.empty?)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "all: missing\n")
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-q", "all"])
        assert("question mode missing dep returns failure", status == 2)
      end
    end
    combined = out + err
    assert("question mode missing dep message", combined.include?("No rule to make target 'missing'"))
  end
end

tests << lambda do
  with_env("MAKE", "") do
    with_env("MAKELEVEL", "") do
      shell = RMake::Shell.new(true)
      vars = {
        "MAKE" => RMake::Evaluator::Var.simple("rmake"),
        "MAKELEVEL" => RMake::Evaluator::Var.simple("1"),
        "MAKEFLAGS" => RMake::Evaluator::Var.simple("-j4"),
        "MFLAGS" => RMake::Evaluator::Var.simple("-j4"),
      }
      cmd = "cd enc && rmake encs"
      out = shell.send(:with_makelevel, cmd, vars, true)
      assert("with_makelevel injects for recursive", out.include?("MAKELEVEL=2"))
      out2 = shell.send(:with_makelevel, "echo hi", vars, false)
      assert("with_makelevel skips non-recursive", out2 == "echo hi")
    end
  end
end

tests << lambda do
  with_env("MAKE", "rmake") do
    with_env("MAKELEVEL", "2") do
      with_env("MAKEFLAGS", "-j8") do
        with_env("MFLAGS", "-j8") do
          shell = RMake::Shell.new(true)
          cmd = "exec rmake clean"
          out = shell.send(:with_makelevel, cmd, {}, true)
          ok = out.include?("MAKELEVEL=3") && out.include?("MAKEFLAGS='-j8'") && out.include?("MFLAGS='-j8'")
          assert("with_makelevel injects env flags", ok)
        end
      end
    end
  end
end

tests << lambda do
  with_env("MAKE", "") do
    shell = RMake::Shell.new(true)
    vars = {
      "MAKE" => RMake::Evaluator::Var.simple("false"),
      "MAKELEVEL" => RMake::Evaluator::Var.simple("0"),
      "MAKEFLAGS" => RMake::Evaluator::Var.simple("-n"),
    }
    ok, _ran = shell.run("@false", vars, {})
    assert("dry-run executes recursive commands", ok == false)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    Dir.chdir(dir) do
      g = RMake::Graph.new
      phony = RMake::Evaluator::Rule.new(["p"], [], [], ["echo PHONY"], false)
      a = RMake::Evaluator::Rule.new(["a"], ["p"], [], ["echo A"], false)
      b = RMake::Evaluator::Rule.new(["b"], ["p"], [], ["echo B"], false)
      all = RMake::Evaluator::Rule.new(["all"], ["a", "b"], [], [], false)
      g.add_rule(phony, phony: true, precious: false)
      g.add_rule(a, phony: false, precious: false)
      g.add_rule(b, phony: false, precious: false)
      g.add_rule(all, phony: false, precious: false)
      shell = RMake::Shell.new(true)
      exec = RMake::Executor.new(g, shell, {})
      out, _err = capture_io do
        exec.build_parallel("all", 2)
      end
      count = out.scan("echo PHONY").length
      assert("phony runs once per invocation", count == 1)
    end
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
.SUFFIXES: .bar
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
    assert("makelevel prefix", out.include?("[1]: Nothing to be done for 'all'."))
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
    assert("explicit target up to date", out.include?("'miniruby' is up to date."))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["all"])
        assert("missing makefile returns failure", status == 2)
      end
    end
    combined = out + err
    assert("missing makefile message with target", combined.include?("No rule to make target 'all'"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run([])
        assert("missing makefile returns failure", status == 2)
      end
    end
    combined = out + err
    assert("missing makefile message without target", combined.include?("No targets specified and no makefile found"))
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
    assert("missing dep message", combined.include?("No rule to make target 'missing'"))
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
.PHONY: noop
noop: dep
dep:
\t@echo dep
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "noop"])
      end
    end
    assert("phony without recipe still builds deps", out.include?("echo dep"))
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
all:
\techo $(MFLAGS)
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        with_env("MAKEFLAGS", "-j5") do
          with_env("RMAKE_JOBS", "") do
            RMake::CLI.run(["-f", "Makefile", "-n", "all"])
          end
        end
      end
    end
    assert("default jobs from MAKEFLAGS", out.include?("-j5"))
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
        with_env("RMAKE_JOBS", "4") do
          RMake::CLI.run(["-f", "Makefile", "-n", "-j", "all"])
        end
      end
    end
    assert("default jobs when -j has no value", out.include?("-j4"))
  end
end

tests << lambda do
  out = RMake::Util.shell_capture("printf ' a\\nb\\n'")
  assert("shell capture trims only trailing newline", out == " a b")
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "a.txt"), "x")
    out = Dir.chdir(dir) do
      RMake::Util.expand("$(wildcard a.txt b.txt)", {}, {})
    end
    assert("wildcard multi-pattern", out == "a.txt")
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "inc.mk"), "FOO = 3\n")
    File.write(File.join(dir, "Makefile"), <<~MK)
include inc.mk
all:
\techo $(FOO)
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "FOO=2", "all"])
      end
    end
    assert("cli override beats include", out.include?("echo 2"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
define myrule
foo:
\t@echo hi
endef
$(eval $(myrule))
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "foo"])
      end
    end
    assert("define+eval emits rule", out.include?("echo hi"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
include inc.mk
inc.mk:
\techo FOO=1 > inc.mk
all:
\t@echo $(FOO)
    MK
    _out, _err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-n", "all"])
        assert("include remake dry-run returns success", status == 0)
      end
    end
    assert("include remake does not create file under -n", !File.exist?(File.join(dir, "inc.mk")))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "inc.mk"), "FOO=old\n")
    File.write(File.join(dir, "stamp"), "x")
    File.utime(Time.now - 60, Time.now - 60, File.join(dir, "inc.mk"))
    File.utime(Time.now, Time.now, File.join(dir, "stamp"))
    File.write(File.join(dir, "Makefile"), <<~MK)
include inc.mk
inc.mk: stamp
\techo FOO=new > inc.mk
all:
\t@echo $(FOO)
    MK
    _out, _err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("include remake update returns success", status == 0)
      end
    end
    content = File.read(File.join(dir, "inc.mk"))
    assert("include remake updates file", content.include?("FOO=new"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
SHOWFLAGS = showflags
-include $(SHOWFLAGS)
all: $(SHOWFLAGS)
.PHONY: showflags
showflags:
\t@echo A=1
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    count = out.scan(/^echo A=1$/).length
    assert("phony include target only runs once", count == 1)
    assert("phony include target is not executed in dry-run phase", !out.include?("\nA=1\n"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
include missing.mk
all:
\t@echo hi
    MK
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "all"])
        assert("missing required include returns failure", status == 2)
      end
    end
    combined = out + err
    assert("missing required include message", combined.include?("No such file or directory"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), "all:; @echo yes\n")
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("inline recipe emits command", out.include?("echo yes"))
  end
end

tests << lambda do
  shell = RMake::Shell.new(false)
  vars = {}
  out, err = capture_io do
    shell.run("-false", vars, { "@" => "clean-so" })
  end
  combined = out + err
  assert("ignored error emits message", combined.include?("Error 1 (ignored)"))
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
a: b
\t@echo a
b: a
\t@echo b
    MK
    out, err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "-j2", "a"])
      end
    end
    combined = out + err
    assert("cycle warning emitted", combined.include?("Circular"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
x:
\t@echo x
all: ./x
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        RMake::CLI.run(["-f", "Makefile", "-n", "all"])
      end
    end
    assert("normalize ./ path deps", out.include?("echo x"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
all:
\t@echo RUN
    MK
    out, _err = capture_io do
      Dir.chdir(dir) do
        with_env("MAKEFLAGS", "-n") do
          RMake::CLI.run(["-f", "Makefile", "all"])
        end
      end
    end
    assert("MAKEFLAGS -n sets dry run", out.include?("echo RUN"))
  end
end

tests << lambda do
  opts, _jobs_set = RMake::CLI.parse_args(["-fR", "-", "all"])
  assert("dash makefile parsed as stdin", opts[:makefiles].include?("-"))
  assert("dash is not treated as target", !opts[:targets].include?("-"))
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    bye = File.join(dir, "bye.mk")
    byesrc = File.join(dir, "bye.mk.src")
    File.write(bye, <<~MK)
bye.mk: bye.mk.src
\ttouch $@
bye.mk.src:
\ttouch $@
    MK
    old = Time.now - 600
    File.utime(old, old, bye)

    out, err = capture_io do
      Dir.chdir(dir) do
        prev = $stdin
        begin
          $stdin = StringIO.new("all:; $(info hello, world)\n")
          status = RMake::CLI.run(["-fbye.mk", "-f-", "all"])
          assert("stdin makefile remake returns success", status == 0)
        ensure
          $stdin = prev
        end
      end
    end
    combined = out + err
    assert("stdin makefile info runs after remake", combined.include?("hello, world"))
    assert("bye source created", File.exist?(byesrc))
    assert("bye makefile updated", File.mtime(bye) > old)
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    bye = File.join(dir, "bye.mk")
    File.write(File.join(dir, "base.mk"), "all: ; @echo from-base\n")
    File.write(bye, <<~MK)
bye.mk: bye.mk.src
\ttouch $@
bye.mk.src:
\ttouch $@
    MK
    old = Time.now - 600
    File.utime(old, old, bye)

    out, err = capture_io do
      Dir.chdir(dir) do
        prev = $stdin
        begin
          $stdin = StringIO.new("all:; @echo from-stdin\n")
          status = RMake::CLI.run(["-f", "base.mk", "-fbye.mk", "-fR", "-", "all"])
          assert("missing top-level makefile returns failure", status == 2)
        ensure
          $stdin = prev
        end
      end
    end
    combined = out + err
    assert("missing top-level makefile warning", combined.include?("R: No such file or directory"))
    assert("missing top-level makefile build error", combined.include?("No rule to make target 'R'"))
    assert("dash not treated as build target", !combined.include?("No rule to make target '-'"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      .SUFFIXES:

      all: exe1 exe2; @echo making $@

      exe1 exe2: lib; @echo cp $^ $@

      lib: foo.o; @echo cp $^ $@

      foo.o: ; exit 1
    MK
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-k"])
        assert("keep-going shared dep returns failure", status == 2)
      end
    end
    combined = out + err
    assert("keep-going runs failing recipe", combined.include?("exit 1"))
    assert("keep-going reports top target failure", combined.include?("Target 'all' not remade because of errors."))
    assert("keep-going does not build sibling from failed shared dep", !combined.include?("cp lib exe2"))
  end
end

tests << lambda do
  Dir.mktmpdir("rmake-test-") do |dir|
    File.write(File.join(dir, "Makefile"), <<~MK)
      all: ; @echo hi
      include ifile
      ifile: no-such-file; exit 1
    MK
    out, err = capture_io do
      Dir.chdir(dir) do
        status = RMake::CLI.run(["-f", "Makefile", "-k"])
        assert("include remake with keep-going returns failure", status == 2)
      end
    end
    combined = out + err
    i1 = combined.index("ifile: No such file or directory")
    i2 = combined.index("No rule to make target 'no-such-file', needed by 'ifile'.")
    i3 = combined.index("failed to remake makefile 'ifile'")
    assert("include missing message emitted", !i1.nil?)
    assert("include missing dep message emitted", !i2.nil?)
    assert("include remake-failed message emitted", !i3.nil?)
    assert("include remake message order", i1 < i2 && i2 < i3)
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
