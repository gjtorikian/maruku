module MaRuKu::In::Markdown::SpanLevelParser

  # This class helps me read and sanitize HTML blocks
  class HTMLHelper
    Tag = %r{^<(/)?(\w+)\s*([^>]*?)>}m
    PartialTag = %r{^<.*}m
    CData = %r{^\s*<!\[CDATA\[}m
    CDataEnd = %r{\]\]>}m

    EverythingElse = %r{^[^<]+}m
    CommentStart = %r{^<!--}x
    CommentEnd = %r{-->}
    TO_SANITIZE = ['img','hr','br']

    attr_reader :rest, :first_tag

    def my_debug(s)
      #    puts "---" * 10 + "\n" + inspect + "\t>>>\t" + s
    end

    def initialize
      @rest = ""
      @tag_stack = []
      @m = nil
      @already = ""
      self.state = :inside_element
    end

    attr_accessor :state # = :inside_element, :inside_tag, :inside_comment, :inside_cdata, :inside_script_style

    def eat_this(line)
      @rest = line + @rest
      things_read = 0
      until @rest.empty?
        case self.state
        when :inside_comment
          if @m = CommentEnd.match(@rest)
            my_debug "#{@state}: Comment End: #{@m.to_s.inspect}"
            # Workaround for https://bugs.ruby-lang.org/issues/9277 and another bug in 1.9.2 where even a
            # single dash in a comment will cause REXML to error.
            @already << @m.pre_match.gsub(/-(?![^\-])/, '- ') << @m.to_s
            @rest = @m.post_match
            self.state = :inside_element
          else
            @already << @rest.gsub(/-(?![^\-])/, '- ') # Workaround for https://bugs.ruby-lang.org/issues/9277
            @rest = ""
            self.state = :inside_comment
          end
        when :inside_element
          if @m = CommentStart.match(@rest)
            my_debug "#{@state}: Comment: #{@m.to_s.inspect}"
            things_read += 1
            @already << @m.pre_match << @m.to_s
            @rest = @m.post_match
            self.state = :inside_comment
          elsif @m = Tag.match(@rest)
            my_debug "#{@state}: Tag: #{@m.to_s.inspect}"
            things_read += 1
            self.state = :inside_element
            handle_tag
          elsif @m = CData.match(@rest)
            my_debug "#{@state}: CDATA: #{@m.to_s.inspect}"
            @already << @m.pre_match << @m.to_s
            @rest = @m.post_match
            self.state = :inside_cdata
          elsif @m = PartialTag.match(@rest)
            my_debug "#{@state}: PartialTag: #{@m.to_s.inspect}"
            @already << @m.pre_match
            @rest = @m.post_match
            @partial_tag = @m.to_s
            self.state = :inside_tag
          elsif @m = EverythingElse.match(@rest)
            my_debug "#{@state}: Everything: #{@m.to_s.inspect}"
            @already << @m.pre_match << @m.to_s
            @rest = @m.post_match
            self.state = :inside_element
          else
            error "Malformed HTML: not complete: #{@rest.inspect}"
          end
        when :inside_tag
          if @m = /^[^>]*>/.match(@rest)
            my_debug "#{@state}: matched #{@m.to_s.inspect}"
            @partial_tag << @m.to_s
            my_debug "#{@state}: matched TOTAL: #{@partial_tag.to_s.inspect}"
            @rest = @partial_tag + @m.post_match
            @partial_tag = nil
            self.state = :inside_element
          else
            @partial_tag << @rest
            @rest = ""
            self.state = :inside_tag
          end
        when :inside_cdata
          if @m = CDataEnd.match(@rest)
            my_debug "#{@state}: matched #{@m.to_s.inspect}"
            self.state = %(script style).include?(@tag_stack.last) ? :inside_script_style : :inside_element
            @already << @m.pre_match
            @already << @m.to_s unless self.state == :inside_script_style
            @rest = @m.post_match
          else
            @already << @rest
            @rest = ""
            self.state = :inside_cdata
          end
        when :inside_script_style
          if @m = CData.match(@rest)
            if @already.rstrip.end_with?('<![CDATA[')
              @already << @m.pre_match
              @rest = @m.post_match
            else
              my_debug "#{@state}: CDATA: #{@m.to_s.inspect}"
              @already << @m.pre_match << @m.to_s
              @rest = @m.post_match
            end
            self.state = :inside_cdata
          elsif @m = Tag.match(@rest)
            is_closing = !!@m[1]
            tag = @m[2]
            if is_closing && tag == @tag_stack.last
              my_debug "#{@state}: matched #{@m.to_s.inspect}"
              @already << @m.pre_match
              @rest = @m.post_match
              # This is necessary to properly parse
              # script tags
              @already << script_style_cdata_end(tag) unless @already.rstrip.end_with?(']]>')
              self.state = :inside_element
              handle_tag false # don't double-add pre_match
            else
              @already << @rest
              @rest = ""
            end
          elsif @m = EverythingElse.match(@rest)
            my_debug "#{@state}: Everything: #{@m.to_s.inspect}"
            @already << @m.pre_match << @m.to_s
            @rest = @m.post_match
          else
            @already << @rest
            @rest = ""
          end
        else
          raise "Bug bug: state = #{self.state.inspect}"
        end # not inside comment

        break if is_finished? && things_read > 0
      end
    end

    def handle_tag(add_pre_match = true)
      @already << @m.pre_match if add_pre_match
      @rest = @m.post_match

      is_closing = !!@m[1]
      tag = @m[2]
      @first_tag ||= tag
      attributes = @m[3].to_s

      is_single = false
      if attributes[-1, 1] == '/'
        attributes = attributes[0, attributes.size - 1]
        is_single = true
      end

      my_debug "Attributes: #{attributes.inspect}"
      my_debug "READ TAG #{@m.to_s.inspect} tag = #{tag} closing? #{is_closing} single = #{is_single}"

      if TO_SANITIZE.include? tag
        attributes.strip!
        #   puts "Attributes: #{attributes.inspect}"
        if attributes.size > 0
          @already <<  '<%s %s />' % [tag, attributes]
        else
          @already <<  '<%s />' % [tag]
        end
      elsif is_closing
        if @tag_stack.empty?
          error "Malformed: closing tag #{tag.inspect} in empty list"
        end
        if @tag_stack.last != tag
          error "Malformed: tag <#{tag}> closes <#{@tag_stack.last}>"
        end

        @already << @m.to_s
        @tag_stack.pop
      else
        @already << @m.to_s

        if not is_single
          @tag_stack.push(tag)
          my_debug "Pushing #{tag.inspect} when read #{@m.to_s.inspect}"
        end

        if %w(script style).include?(@tag_stack.last)
          # This is necessary to properly parse
          # script tags
          @already << script_style_cdata_start(@tag_stack.last)
          self.state = :inside_script_style
        end
      end
    end

    def error(s)
      raise "Error: #{s} \n" + inspect, caller
    end

    def inspect
      "HTML READER\n state=#{self.state} " +
        "match=#{@m.to_s.inspect}\n" +
        "Tag stack = #{@tag_stack.inspect} \n" +
        "Before:\n" +
        @already.gsub(/^/, '|') + "\n" +
        "After:\n" +
        @rest.gsub(/^/, '|') + "\n"
    end

    def stuff_you_read
      @already
    end

    def is_finished?
      (self.state == :inside_element) and @tag_stack.empty?
    end

    def script_style_cdata_start(tag)
      (tag == 'script') ? "//<![CDATA[\n" : "/*<![CDATA[*/\n"
    end

    def script_style_cdata_end(tag)
      (tag == 'script') ? "\n//]]>" : "\n/*]]>*/"
    end
  end # html helper
end
