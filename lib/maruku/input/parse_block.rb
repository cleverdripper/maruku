require 'set'

module MaRuKu; module In; module Markdown; module BlockLevelParser

  include Helpers
  include MaRuKu::Strings
  include MaRuKu::In::Markdown::SpanLevelParser

  class BlockContext < Array
    def describe
      n = 5
      desc = size > n ? self[-n, n] : self
      "Last #{n} elements: " +
        desc.map {|x| "\n -" + x.inspect }.join
    end
  end

  # Splits the string and calls parse_lines_as_markdown
  def parse_text_as_markdown(text)
    lines =  split_lines(text)
    src = LineSource.new(lines)
    parse_blocks(src)
  end

  # Input is a LineSource
  def parse_blocks(src)
    output = BlockContext.new

    # run state machine
    while src.cur_line
      next if check_block_extensions(src, output, src.cur_line)

      md_type = src.cur_line.md_type

      # Prints detected type (useful for debugging)
      #puts "parse_blocks #{md_type}|#{src.cur_line}"
      case md_type
      when :empty
        output << :empty
        src.ignore_line
      when :ial
        m = InlineAttributeList.match src.shift_line
        content = m[1] || ""
        src2 = CharSource.new(content, src)
        interpret_extension(src2, output)
      when :ald
        output << read_ald(src)
      when :text
        # paragraph, or table, or definition list
        read_text_material(src, output)
      when :header2, :hrule
        # hrule
        src.shift_line
        output << md_hrule
      when :header3
        output << read_header3(src)
      when :ulist, :olist
        list_type = (md_type == :ulist) ? :ul : :ol
        li = read_list_item(src)
        # append to current list if we have one
        if output.last.kind_of?(MDElement) &&
            output.last.node_type == list_type then
          output.last.children << li
        else
          output << md_el(list_type, li)
        end
      when :quote
        output << read_quote(src)
      when :code
        e = read_code(src)
        output << e if e
      when :raw_html
        # More extra hacky stuff - if there's more than just HTML, we either wrap it
        # in a paragraph or break it up depending on whether it's an inline element or not
        e = read_raw_html(src)
        unless e.empty?
          first_node = e.first.parsed_html.children.first
          if first_node && HTML_INLINE_ELEMS.include?(first_node.name) &&
              !['svg', 'math'].include?(first_node.name)
            content = [e.first]
            if e.size > 1
              content.concat(e[1].children)
            end
            output << md_par(content)
          else
            output.concat(e)
          end
        end
      when :footnote_text
        output << read_footnote_text(src)
      when :ref_definition
        if src.parent && src.cur_index == 0
          read_text_material(src, output)
        else
          read_ref_definition(src, output)
        end
      when :abbreviation
        output << read_abbreviation(src)
      when :xml_instr
        read_xml_instruction(src, output)
      else # warn if we forgot something
        line = src.cur_line
        maruku_error "Ignoring line '#{line}' type = #{md_type}", src
        src.shift_line
      end
    end

    merge_ial(output, src, output)
    output.delete_if {|x| x.kind_of?(MDElement) && x.node_type == :ial }

    # get rid of empty line markers
    output.delete_if {|x| x == :empty }

    # See for each list if we can omit the paragraphs
    # TODO: do this after
    output.each do |c|
      # Remove paragraphs that we can get rid of
      if [:ul, :ol].include?(c.node_type) && c.children.none?(&:want_my_paragraph)
        c.children.each do |d|
          if d.children.first && d.children.first.node_type == :paragraph
            d.children = d.children.first.children + d.children[1..-1]
          end
        end
      elsif c.node_type == :definition_list && c.children.none?(&:want_my_paragraph)
        c.children.each do |definition|
          definition.definitions.each do |dd|
            if dd.children.first.node_type == :paragraph
              dd.children = dd.children.first.children + dd.children[1..-1]
            end
          end
        end
      end
    end

    output
  end

  def read_text_material(src, output)
    maybeTableHeader = src.cur_line =~ MightBeTableHeader

    if maybeTableHeader &&
        src.next_line &&
        src.next_line =~ TableSeparator
      output << read_table(src, false)
    elsif maybeTableHeader &&
        src.next_line &&
        src.next_line =~ MultilineTableSeparator
      output << read_table(src, true)
    elsif src.next_line && [:header1, :header2].include?(src.next_line.md_type)
      output << read_header12(src)
    elsif eventually_comes_a_def_list(src)
      definition = read_definition(src)
      if output.last.kind_of?(MDElement) &&
          output.last.node_type == :definition_list then
        output.last.children << definition
      else
        output << md_el(:definition_list, definition)
      end
    else # Start of a paragraph
      output << read_paragraph(src)
    end
  end

  def read_ald(src)
    if (l = src.shift_line) =~ AttributeDefinitionList
      id = $1
      al = read_attribute_list(CharSource.new($2, src))
      self.ald[id] = al;
      md_ald(id, al)
    else
      maruku_error "Bug Bug:\n#{l.inspect}"
      nil
    end
  end

  # reads a header (with ----- or ========)
  def read_header12(src)
    line = src.shift_line.strip
    al = nil
    # Check if there is an IAL
    if new_meta_data? and line =~ /^(.*?)\{(.*?)\}\s*$/
      line = $1.strip
      ial = $2
      al = read_attribute_list(CharSource.new(ial, src))
    end
    text = parse_span line
    if text.empty?
      text = "{#{ial}}"
      al = nil
    end
    level = src.cur_line.md_type == :header2 ? 2 : 1;
    src.shift_line
    md_header(level, text, al)
  end

  # reads a header like '#### header ####'
  def read_header3(src)
    line = src.shift_line.strip
    al = nil
    # Check if there is an IAL
    if new_meta_data? and line =~ /^(.*?)\{(.*?)\}\s*$/
      line = $1.strip
      ial = $2
      al = read_attribute_list(CharSource.new(ial, src))
    end
    level = line[/^#+/].size
    text = parse_span line.gsub(/\A#+|#+\Z/, '')
    if text.empty?
      text = "{#{ial}}"
      al = nil
    end
    md_header(level, text, al)
  end

  def read_xml_instruction(src, output)
    m = /^\s*<\?((\w+)\s*)?(.*)$/.match src.shift_line
    raise "BugBug" unless m
    target = m[2] || ''
    code = m[3]
    until code =~ /\?>/
      code << "\n" << src.shift_line
    end
    unless code =~ /\?>\s*$/
      garbage = (/\?>(.*)$/.match(code))[1]
      maruku_error "Trailing garbage on last line: #{garbage.inspect}:\n" +
        code.gsub(/^/, '|'), src
    end
    code.gsub!(/\?>\s*$/, '')

    if target == 'mrk' && MaRuKu::Globals[:unsafe_features]
      result = safe_execute_code(self, code)
      if result
        if result.kind_of? String
          raise "Not expected"
        else
          output.push(*result)
        end
      end
    else
      output << md_xml_instr(target, code)
    end
  end

  HTML_INLINE_ELEMS = Set.new %w[a abbr acronym audio b bdi bdo big br button canvas caption cite code
    col colgroup command datalist del details dfn dir em fieldset font form i img input ins
    kbd label legend mark meter optgroup option progress q rp rt ruby s samp section select small
    source span strike strong sub summary sup tbody td tfoot th thead time tr track tt u var video wbr
    animate animateColor animateMotion animateTransform circle clipPath defs desc ellipse
    feGaussianBlur filter font-face font-face-name font-face-src foreignObject g glyph hkern
    linearGradient line marker mask metadata missing-glyph mpath path pattern polygon polyline
    radialGradient rect set stop svg switch text textPath title tspan use
    annotation annotation-xml maction math menclose merror mfrac mfenced mi mmultiscripts mn mo
    mover mpadded mphantom mprescripts mroot mrow mspace msqrt mstyle msub msubsup msup mtable
    mtd mtext mtr munder munderover none semantics] 
  def read_raw_html(src)
    extra_line = nil
    h = HTMLHelper.new
    begin
      l = src.shift_line
      h.eat_this(l)
      #     puts "\nBLOCK:\nhtml -> #{l.inspect}"
      while src.cur_line && !h.is_finished?
        l = src.shift_line
        #       puts "html -> #{l.inspect}"
        h.eat_this "\n" + l
      end
    rescue => e
      maruku_error "Bad block-level HTML:\n#{e.inspect.gsub(/^/, '|')}\n", src
    end
    unless h.rest =~ /^\s*$/
      extra_line = h.rest
    end
    raw_html = h.stuff_you_read

    is_inline = HTML_INLINE_ELEMS.include?(h.first_tag)
    
    if extra_line
      remainder = is_inline ? parse_span(extra_line) : parse_text_as_markdown(extra_line)
      if extra_line.start_with?(' ')
        remainder[0] = ' ' + remainder[0] if remainder[0].is_a?(String)
      end
      is_inline ? [md_html(raw_html), md_par(remainder)] : [md_html(raw_html)] + remainder
    else
      [md_html(raw_html)]
    end
  end

  def read_paragraph(src)
    lines = [src.shift_line]
    while src.cur_line
      # :olist does not break
      case t = src.cur_line.md_type
      when :quote, :header3, :empty, :ref_definition, :ial, :xml_instr
        break
      when :olist, :ulist
        break if !src.next_line || src.next_line.md_type == t
      when :raw_html
        # This is a pretty awful hack to handle inline HTML
        # but it means double-parsing HMTL.
        html = parse_span([src.cur_line], src)
        unless html.empty? || html.first.is_a?(String)
          first_node = html.first.parsed_html.children.first
        end
        break if first_node && !HTML_INLINE_ELEMS.include?(first_node.name)
      end
      break if src.cur_line.strip.empty?
      break if src.next_line && [:header1, :header2].include?(src.next_line.md_type)
      break if any_matching_block_extension?(src.cur_line)

      lines << src.shift_line
    end
    children = parse_span(lines, src)

    md_par(children)
  end

  # Reads one list item, either ordered or unordered.
  def read_list_item(src)
    parent_offset = src.cur_index

    item_type = src.cur_line.md_type
    first = src.shift_line

    indentation, ial = spaces_before_first_char(first)
    al = read_attribute_list(CharSource.new(ial, src)) if ial
    ial_offset = ial ? ial.length + 3 : 0
    lines, want_my_paragraph =
      read_indented_content(src, indentation, [], item_type, ial_offset)

    # add first line
    # Strip first '*', '-', '+' from first line
    stripped = first[indentation, first.size - 1]
    lines.unshift stripped

    src2 = LineSource.new(lines, src, parent_offset)
    children = parse_blocks(src2)

    md_li(children, want_my_paragraph, al)
  end

  def read_abbreviation(src)
    unless (l = src.shift_line) =~ Abbreviation
      maruku_error "Bug: it's Andrea's fault. Tell him.\n#{l.inspect}"
    end

    abbr = $1
    desc = $2

    if !abbr || abbr.empty?
      maruku_error "Bad abbrev. abbr=#{abbr.inspect} desc=#{desc.inspect}"
    end

    self.abbreviations[abbr] = desc

    md_abbr_def(abbr, desc)
  end

  def read_footnote_text(src)
    parent_offset = src.cur_index

    first = src.shift_line

    unless first =~ FootnoteText
      maruku_error "Bug (it's Andrea's fault)"
    end

    id = $1
    text = $2 || ''

    indentation = 4 #first.size-text.size

    #   puts "id =_#{id}_; text=_#{text}_ indent=#{indentation}"

    break_list = [:footnote_text, :ref_definition, :definition, :abbreviation]
    item_type = :footnote_text
    lines, _ = read_indented_content(src, indentation, break_list, item_type)

    # add first line
    lines.unshift text unless text.strip.empty?

    src2 = LineSource.new(lines, src, parent_offset)
    children = parse_blocks(src2)

    e = md_footnote(id, children)
    self.footnotes[id] = e
    e
  end


  # This is the only ugly function in the code base.
  # It is used to read list items, descriptions, footnote text
  def read_indented_content(src, indentation, break_list, item_type, ial_offset=0)
    lines = []
    # collect all indented lines
    saw_empty = false
    saw_anything_after = false
    break_list = Array(break_list)
    len = indentation - ial_offset

    while src.cur_line
      num_leading_spaces = src.cur_line.number_of_leading_spaces
      break if num_leading_spaces < len && ![:text, :empty].include?(src.cur_line.md_type)

      line = strip_indent(src.cur_line, indentation)
      md_type = line.md_type

      if md_type == :empty
        saw_empty = true
        lines << line
        src.shift_line
        next
      end

      # Unquestioningly grab anything that's deeper-indented
      if md_type != :code && num_leading_spaces > len
        lines << line
        src.shift_line
        next
      end

      # after a white line
      if saw_empty
        # we expect things to be properly aligned
        break if num_leading_spaces < len
        saw_anything_after = true
      else
        break if break_list.include?(md_type)
      end

      lines << line
      src.shift_line

      # You are only required to indent the first line of
      # a child paragraph.
      if md_type == :text
        while src.cur_line && src.cur_line.md_type == :text
          lines << strip_indent(src.shift_line, indentation)
        end
      end
    end

    # TODO fix this
    want_my_paragraph = saw_anything_after ||
      (saw_empty && src.cur_line && src.cur_line.md_type == item_type)

    # create a new context

    while lines.last && lines.last.md_type == :empty
      lines.pop
    end

    return lines, want_my_paragraph
  end


  def read_quote(src)
    parent_offset = src.cur_index

    lines = []
    # collect all indented lines
    while src.cur_line && src.cur_line.md_type == :quote
      lines << unquote(src.shift_line)
    end

    src2 = LineSource.new(lines, src, parent_offset)
    children = parse_blocks(src2)
    md_quote(children)
  end

  def read_code(src)
    # collect all indented lines
    lines = []
    while src.cur_line && [:code, :empty].include?(src.cur_line.md_type)
      lines << strip_indent(src.shift_line, 4)
    end

    #while lines.last && (lines.last.md_type == :empty )
    while lines.last && lines.last.strip.size == 0
      lines.pop
    end

    while lines.first && lines.first.strip.size == 0
      lines.shift
    end

    return nil if lines.empty?

    source = lines.join("\n")

    md_codeblock(source)
  end

  def read_ref_definition(src, out)
    line = src.shift_line

    # if link is incomplete, shift next line
    if src.cur_line &&
        ![:footnote_text, :ref_definition, :definition, :abbreviation].include?(src.cur_line.md_type) &&
        (1..3).include?(src.cur_line.number_of_leading_spaces)
      line << " " << src.shift_line
    end

    match = LinkRegex.match(line)
    unless match
      maruku_error "Link does not respect format: '#{line}'" and return
    end

    id = match[1]
    url = match[2]
    title = match[3] || match[4] || match[5]
    id = sanitize_ref_id(id)

    hash = self.refs[id] = {
      :url => url,
      :title => title
    }

    stuff = (match[6] || '')
    stuff.split.each do |couple|
      k, v = couple.split('=')
      v ||= ""
      v = v[1..-2] if v.start_with?('"') # strip quotes
      hash[k.to_sym] = v
    end

    out << md_ref_def(id, url, :title => title)
  end

  def distribute!(a, b)
    diff = [0, b.size - a.size].max
    a.concat(Array.new(diff) { Array.new })
    0.upto a.size - 1 do |i|
      a[i] << b[i]
    end
    a
  end
  
  def split_cells(src, isMultiline)
    if isMultiline
      cells = []

      while src.cur_line && src.cur_line =~ /\|/ && src.cur_line !~ MultilineTableSeparatorNoAlignment
        l = src.shift_line.split('|').reject(&:empty?).map(&:strip)
        cells = distribute!(cells, l)
      end

      # If we stopped on a --+--+-- line, discard it
      src.shift_line if src.cur_line && src.cur_line =~ MultilineTableSeparatorNoAlignment

      cells.map { |a| a.join(' ') }
    else
      sep = src.cur_line =~ /\|/ ? '|' : '+'
      src.shift_line.split(sep).reject(&:empty?).map(&:strip)
    end
  end

  def read_table(src, isMultiline)
    head = split_cells(src, false).map do |s|
      md_el(:head_cell, parse_span(s))
    end

    separator = split_cells(src, false)

    align = separator.map do |s|
      s =~ Sep
      if $1 && $2
        :center
      elsif $2
        :right
      else
        :left
      end
    end

    num_columns = align.size

    if head.size != num_columns
      maruku_error "Table head does not have #{num_columns} columns: \n#{head.inspect}"
      tell_user "I will ignore this table."
      # XXX try to recover
      return md_br
    end

    rows = []

    while src.cur_line && src.cur_line =~ /\|/
      row = split_cells(src, isMultiline).map do |s|
        md_el(:cell, parse_span(s))
      end

      if head.size != num_columns
        maruku_error  "Row does not have #{num_columns} columns: \n#{row.inspect}"
        tell_user "I will ignore this table."
        # XXX try to recover
        return md_br
      end
      rows << row
    end

    children = (head + rows).flatten
    md_el(:table, children, { :align => align })
  end

  # If current line is text, a definition list is coming
  # if 1) text,empty,[text,empty]*,definition
  def eventually_comes_a_def_list(src)
    src.tell_me_the_future =~ %r{^t+e?d}x
  end

  def read_definition(src)
    # Read one or more terms
    terms = []
    while src.cur_line && src.cur_line.md_type == :text
      terms << md_el(:definition_term, parse_span(src.shift_line))
    end

    want_my_paragraph = false

    raise "Chunky Bacon!" unless src.cur_line

    # one optional empty
    if src.cur_line.md_type == :empty
      want_my_paragraph = true
      src.shift_line
    end

    raise "Chunky Bacon!" unless src.cur_line.md_type == :definition

    # Read one or more definitions
    definitions = []
    while src.cur_line && src.cur_line.md_type == :definition
      parent_offset = src.cur_index

      first = src.shift_line
      first =~ Definition
      first = $1

      lines, w_m_p = read_indented_content(src, 4, :definition, :definition)
      want_my_paragraph ||= w_m_p

      lines.unshift first

      src2 = LineSource.new(lines, src, parent_offset)
      children = parse_blocks(src2)
      definitions << md_el(:definition_data, children)
    end

    md_el(:definition, terms + definitions, {
            :terms => terms,
            :definitions => definitions,
            :want_my_paragraph => want_my_paragraph
          })
  end
end end end end
