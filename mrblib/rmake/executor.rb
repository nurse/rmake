module RMake
  class Executor
    def initialize(graph, shell, vars, delete_on_error = false, trace = false)
      @graph = graph
      @shell = shell
      @vars = vars
      @delete_on_error = delete_on_error
      @trace = trace
      @building = {}
      @mtime_cache = {}
      @resolve_cache = {}
      @node_cache = {}
      @vpath_dirs = nil
      @built_any = false
      @built_phony = {}
      @restat_no_change = {}
    end

    def built_any?
      @built_any
    end

    def build(target, parent = nil)
      node = resolve_node(target)
      unless node
        return true if file_present?(target)
        return missing_dep_error(target, parent)
      end
      key = node.name
      return true if @built_phony[key]
      return true if @building[key] == :done
      if @building[key] == :building
        return true
      end
      @building[key] = :building
      puts "rmake: #{target}" if @trace

      node.deps.each { |dep| return false unless build(dep, node.name) }
      node.order_only.each { |dep| return false unless build(dep, node.name) }

      if node.phony && (node.recipe.nil? || node.recipe.empty?)
        @built_phony[key] = true
        @building[key] = :done
        return true
      end

      if need_build?(node)
        old_mtime = mtime(node.name)
        @built_any = true
        ok = run_recipe(node)
        unless ok
          cleanup_target(node)
          return false
        end
        restat_update(node.name, old_mtime)
        @built_phony[key] = true if node.phony
      else
        puts "rmake: #{node.name} (skip)" if @trace
      end

      @building[key] = :done
      true
    end

    def build_parallel(target, jobs = 1)
      return build(target) if jobs <= 1
      return build(target) unless Shell.supports_spawn?
      return false unless validate_deps(target, nil, {})
      plan = collect_targets(target)
      return true if plan.empty?

      reverse = {}
      pending = {}
      ready = []
      done = {}
      running = {}
      run_old = {}

      plan.each do |name, node|
        deps = node.deps + node.order_only
        wait_deps = deps.select { |dep| plan.key?(dep) }
        pending[name] = wait_deps.length
        wait_deps.each do |dep|
          (reverse[dep] ||= []) << name
        end
      end

      plan.each_key do |name|
        ready << plan[name] if pending[name] == 0
      end

      while done.length < plan.length
        while ready.any? && running.length < jobs
          node = ready.shift
          if @built_phony[node.name] || @building[node.name] == :done
            mark_done(node.name, done, pending, reverse, plan, ready)
            next
          end
          if !need_build?(node)
            @built_phony[node.name] = true if node.phony
            mark_done(node.name, done, pending, reverse, plan, ready)
            next
          end

          puts "rmake: #{node.name}" if @trace
          @built_any = true
          @building[node.name] = :building
          run_old[node.name] = mtime(node.name)
          pid = @shell.spawn_recipe(node, vars_for(node), auto_vars(node))
          if pid == 0
            @built_phony[node.name] = true if node.phony
            @building[node.name] = :done
            mark_done(node.name, done, pending, reverse, plan, ready)
          else
            running[pid] = node
          end
        end

        if running.any?
          pid, status = @shell.wait_any
          node = running.delete(pid)
          if status != 0
            cleanup_target(node)
            return false
          end
          restat_update(node.name, run_old[node.name])
          @built_phony[node.name] = true if node.phony
          @building[node.name] = :done
          mark_done(node.name, done, pending, reverse, plan, ready)
        end

        if running.empty? && ready.empty?
          break_cycle(pending, reverse, plan, ready, done)
          break if ready.empty?
        end
      end

      true
    end

    def can_build?(target)
      !!resolve_node(target)
    end

    private

    def resolve_node(name)
      cached = @node_cache[name]
      return cached if cached

      node = @graph.node(name)
      if node.nil?
        alt = name.start_with?("./") ? name[2..-1] : "./#{name}"
        node = @graph.node(alt)
        if node
          @node_cache[name] = node
          return node
        end
      end
      imp = nil
      imp_rules = @graph.implicit_rules_for(name)
      if node
        if node.recipe.nil? || node.recipe.empty?
          imp_rules.each do |src, dst, prereqs, recipe|
            base = name[0...-dst.length]
            imp = Graph::Node.new(name, [base + src] + prereqs, [], recipe.dup, false, false, false, {})
            src_path = imp.deps.first
            if src_path && (File.exist?(src_path) || resolve_path(src_path) || graph_has_node?(src_path))
              node.deps = (imp.deps + node.deps).uniq
              node.recipe = imp.recipe
              break
            end
          end
        end
        if node.recipe.nil? || node.recipe.empty?
          if name.end_with?(".o")
            base = name[0...-2]
            [".S", ".s"].each do |ext|
              src = base + ext
              if File.exist?(src) || resolve_path(src)
                node.deps = ([src] + node.deps).uniq
                node.recipe = [
                  "$(Q) $(CC) $(CFLAGS) $(XCFLAGS) $(CPPFLAGS) $(COUTFLAG)$@ -c $<",
                ]
                break
              end
            end
          end
        end
        @node_cache[name] = node
        return node
      end
      imp_rules.each do |src, dst, prereqs, recipe|
        base = name[0...-dst.length]
        imp = Graph::Node.new(name, [base + src] + prereqs, [], recipe.dup, false, false, false, {})
        src_path = imp.deps.first
        if src_path && (File.exist?(src_path) || resolve_path(src_path) || graph_has_node?(src_path))
          @node_cache[name] = imp
          return imp
        end
      end
      # Built-in implicit for assembly
      if name.end_with?(".o")
        base = name[0...-2]
        [".S", ".s"].each do |ext|
          src = base + ext
          if File.exist?(src) || resolve_path(src)
            recipe = [
              "$(Q) $(CC) $(CFLAGS) $(XCFLAGS) $(CPPFLAGS) $(COUTFLAG)$@ -c $<",
            ]
            node = Graph::Node.new(name, [src], [], recipe, false, false, false, {})
            @node_cache[name] = node
            return node
          end
        end
      end
      nil
    end

    def need_build?(node)
      if node.phony
        return false if @built_phony[node.name]
        return false if node.recipe.nil? || node.recipe.empty?
        return true
      end
      return false if node.recipe.nil? || node.recipe.empty?
      node.deps.each do |dep|
        dep_node = @graph.node(dep)
        return true if dep_node && dep_node.phony
      end
      tgt_mtime = mtime(node.name)
      return true if tgt_mtime.nil?

      node.deps.any? do |dep|
        next false if @restat_no_change[dep]
        path = resolve_path(dep) || dep
        (mtime(path) || 0) > tgt_mtime
      end
    end

    def run_recipe(node)
      ctx = auto_vars(node)
      vars = vars_for(node)
      node.recipe.each do |raw|
        ok = @shell.run(raw, vars, ctx)
        return false unless ok
      end
      true
    end

    def auto_vars(node)
      prereqs = node.deps.map { |d| resolve_path(d) || d }
      first = prereqs.first || ""
      stem = Util.strip_suffix(node.name)
      stem_dir = File.dirname(stem)
      stem_dir = "." if stem_dir == "."
      {
        "@" => node.name,
        "<" => first,
        "?" => prereqs.join(" "),
        "^" => prereqs.join(" "),
        "*" => stem,
        "*F" => File.basename(stem),
        "*D" => stem_dir,
        "@F" => File.basename(node.name),
        "@D" => File.dirname(node.name) == "." ? "." : File.dirname(node.name),
      }
    end

    def vars_for(node)
      return @vars if node.nil? || node.target_vars.nil? || node.target_vars.empty?
      @vars.merge(node.target_vars)
    end

    def resolve_path(path)
      if @resolve_cache.key?(path)
        return @resolve_cache[path]
      end
      if File.exist?(path)
        @resolve_cache[path] = path
        if path.start_with?("./")
          @resolve_cache[path[2..-1]] = path
        else
          @resolve_cache["./#{path}"] = path
        end
        return path
      end
      if path.start_with?("/") || path.start_with?("./") || path.start_with?("../")
        @resolve_cache[path] = nil
        if path.start_with?("./")
          @resolve_cache[path[2..-1]] = nil
        else
          @resolve_cache["./#{path}"] = nil
        end
        return nil
      end
      dirs = vpath_dirs
      if dirs.nil? || dirs.empty?
        @resolve_cache[path] = nil
        return nil
      end
      dirs.each do |dir|
        candidate = File.join(dir, path)
        if File.exist?(candidate)
          @resolve_cache[path] = candidate
          return candidate
        end
      end
      @resolve_cache[path] = nil
      nil
    end

    def file_present?(path)
      return true if File.exist?(path)
      !!resolve_path(path)
    end

    def missing_dep_error(target, parent)
      msg = if parent && !parent.empty?
        "rmake: *** No rule to make target `#{target}', needed by `#{parent}'. Stop."
      else
        "rmake: *** No rule to make target `#{target}'. Stop."
      end
      if Kernel.respond_to?(:warn)
        warn msg
      else
        puts msg
      end
      false
    end

    def validate_deps(target, parent, seen)
      return true if seen[target]
      seen[target] = true
      node = resolve_node(target)
      unless node
        return true if file_present?(target)
        return missing_dep_error(target, parent)
      end
      node.deps.each { |dep| return false unless validate_deps(dep, node.name, seen) }
      node.order_only.each { |dep| return false unless validate_deps(dep, node.name, seen) }
      true
    end

    def vpath_dirs
      return @vpath_dirs if @vpath_dirs
      vpath = @vars["VPATH"]
      vpath = vpath && vpath.simple ? vpath.value : (vpath ? Util.expand(vpath.value, @vars) : nil)
      @vpath_dirs = vpath.nil? || vpath.empty? ? [] : vpath.split(":")
      @vpath_dirs
    end

    def mtime(path)
      return @mtime_cache[path] if @mtime_cache.key?(path)
      return nil unless File.respond_to?(:exist?) && File.exist?(path)
      if File.respond_to?(:mtime)
        t = File.mtime(path)
        t = t.to_i if t.respond_to?(:to_i)
        @mtime_cache[path] = t
        return t
      elsif File.respond_to?(:stat)
        t = File.stat(path).mtime
        t = t.to_i if t.respond_to?(:to_i)
        @mtime_cache[path] = t
        return t
      elsif IO.respond_to?(:popen)
        out = ""
        IO.popen("/usr/bin/stat -f %m #{Util.shell_escape(path)}") { |io| out = io.read }
        t = out.to_i if out
        @mtime_cache[path] = t
        return t
      end
      @mtime_cache[path] = nil
      nil
    rescue Errno::ENOENT
      @mtime_cache[path] = nil
      nil
    end

    def graph_has_node?(path)
      return true if @graph.node(path)
      if path.start_with?("./")
        alt = path[2..-1]
        return true if @graph.node(alt)
      else
        alt = "./#{path}"
        return true if @graph.node(alt)
      end
      false
    end

    def cleanup_target(node)
      return unless @delete_on_error
      return if node.precious
      begin
        File.delete(node.name) if File.exist?(node.name)
      rescue
        # ignore
      end
    end

    def collect_targets(target)
      plan = {}
      stack = [target]
      until stack.empty?
        name = stack.pop
        node = resolve_node(name)
        next unless node
        plan[name] ||= node
        (node.deps + node.order_only).each do |dep|
          next if plan.key?(dep)
          stack << dep
        end
      end
      plan
    end

    def mark_done(name, done, pending, reverse, plan, ready)
      return if done[name]
      done[name] = true
      deps = reverse[name]
      return unless deps
      deps.each do |dep_name|
        next if done[dep_name]
        pending[dep_name] -= 1
        next unless pending[dep_name] == 0
        node = plan[dep_name]
        ready << node if node
      end
    end

    def break_cycle(pending, reverse, plan, ready, done)
      dep, name = find_cycle_edge(plan, done)
      return unless dep && name
      if Kernel.respond_to?(:warn)
        warn "rmake: Circular #{dep} <- #{name} dependency dropped."
      else
        puts "rmake: Circular #{dep} <- #{name} dependency dropped."
      end
      pending[name] -= 1
      if reverse[dep]
        reverse[dep].delete(name)
      end
      ready << plan[name] if pending[name] <= 0
    end

    def find_cycle_edge(plan, done)
      visited = {}
      stack = {}
      plan.each_key do |name|
        next if done[name]
        edge = dfs_cycle(name, plan, done, visited, stack)
        return edge if edge
      end
      nil
    end

    def dfs_cycle(name, plan, done, visited, stack)
      return nil if visited[name]
      visited[name] = true
      stack[name] = true
      node = plan[name]
      if node
        deps = node.deps + node.order_only
        deps.each do |dep|
          next unless plan.key?(dep)
          next if done[dep]
          if !visited[dep]
            edge = dfs_cycle(dep, plan, done, visited, stack)
            return edge if edge
          elsif stack[dep]
            return [dep, name]
          end
        end
      end
      stack.delete(name)
      nil
    end

    def restat_update(name, old_mtime)
      @mtime_cache.delete(name)
      if name.start_with?("./")
        @mtime_cache.delete(name[2..-1])
      else
        @mtime_cache.delete("./#{name}")
      end
      new_mtime = mtime(name)
      if old_mtime && new_mtime && old_mtime == new_mtime
        @restat_no_change[name] = true
        if name.start_with?("./")
          @restat_no_change[name[2..-1]] = true
        else
          @restat_no_change["./#{name}"] = true
        end
      else
        @restat_no_change.delete(name)
        @restat_no_change.delete("./#{name}")
        if name.start_with?("./")
          @restat_no_change.delete(name[2..-1])
        end
      end
    end
  end
end
