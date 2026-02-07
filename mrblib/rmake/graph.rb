module RMake
  class Graph
    Node = Struct.new(:name, :deps, :order_only, :recipe, :phony, :precious, :double_colon, :target_vars, :target_inherit_append, :grouped, :group_peers, :pattern_stem)
    PatternRule = Struct.new(:targets, :prereqs, :order_only, :recipe, :grouped)

    def initialize
      @nodes = {}
      @suffix_rules = []
      @suffix_by_dst = {}
      @pattern_rules = []
    end

    def add_rule(rule, phony: false, precious: false)
      rule.targets.each do |t|
        node = (@nodes[t] ||= Node.new(t, [], [], [], false, false, rule.double_colon, {}, {}, false, [], nil))
        node.deps.concat(rule.prereqs)
        node.order_only.concat(rule.order_only)
        node.phony ||= phony
        node.precious ||= precious
        if rule.grouped
          node.grouped = true
          peers = rule.targets.reject { |x| x == t }
          node.group_peers ||= []
          peers.each { |p| node.group_peers << p unless node.group_peers.include?(p) }
        end
        if rule.recipe.any?
          if rule.double_colon
            node.recipe.concat(rule.recipe)
          else
            node.recipe = rule.recipe
          end
        end
      end
    end

    def add_pattern_rule(rule)
      @pattern_rules << PatternRule.new(rule.targets.dup, rule.prereqs.dup, rule.order_only.dup, rule.recipe.dup, rule.grouped || rule.targets.length > 1)
    end

    def add_suffix_rule(src, dst, prereqs, recipe)
      @suffix_rules << [src, dst, prereqs, recipe]
      (@suffix_by_dst[dst] ||= []) << [src, dst, prereqs, recipe]
    end

    def node(name)
      @nodes[name]
    end

    def ensure_node(name)
      @nodes[name] ||= Node.new(name, [], [], [], false, false, false, {}, {}, false, [], nil)
    end

    def nodes
      @nodes.values
    end

    def implicit_rules_for(target)
      rules = []
      @suffix_by_dst.each do |dst, list|
        next unless target.end_with?(dst)
        list.each { |r| rules << r }
      end
      if rules.empty?
        @suffix_rules.each do |r|
          rules << r if target.end_with?(r[1])
        end
      end
      rules
    end

    def pattern_rule_node_for(target)
      @pattern_rules.reverse_each do |rule|
        stem = nil
        matched = false
        rule.targets.each do |pat|
          next unless pat.include?("%")
          s = pattern_stem(target, pat)
          next if s.nil?
          stem = s
          matched = true
          break
        end
        next unless matched
        deps = rule.prereqs.map { |w| replace_percent(w, stem) }
        order_only = rule.order_only.map { |w| replace_percent(w, stem) }
        peers = rule.targets.map { |t| replace_percent(t, stem) }.reject { |t| t == target }
        return Node.new(target, deps, order_only, rule.recipe.dup, false, false, false, {}, {}, rule.grouped, peers, stem)
      end
      nil
    end

    private

    def pattern_stem(word, pattern)
      i = pattern.index("%")
      return nil if i.nil?
      pre = pattern[0...i]
      post = pattern[(i + 1)..-1].to_s
      return nil unless word.start_with?(pre)
      return nil unless post.empty? || word.end_with?(post)
      left = pre.length
      right = post.length
      body_end = right == 0 ? word.length : (word.length - right)
      return nil if body_end < left
      word[left...body_end]
    end

    def replace_percent(text, stem)
      t = text.to_s
      return t unless t.include?("%")
      t.gsub("%", stem.to_s)
    end
  end
end
