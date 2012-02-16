# encoding: UTF-8

require 'set'

module Twitter
  # A module for including Tweet auto-linking in a class. The primary use of this is for helpers/views so they can auto-link
  # usernames, lists, hashtags and URLs.
  module Autolink extend self
    # Default CSS class for auto-linked URLs
    DEFAULT_URL_CLASS = "tweet-url"
    # Default CSS class for auto-linked lists (along with the url class)
    DEFAULT_LIST_CLASS = "list-slug"
    # Default CSS class for auto-linked usernames (along with the url class)
    DEFAULT_USERNAME_CLASS = "username"
    # Default CSS class for auto-linked hashtags (along with the url class)
    DEFAULT_HASHTAG_CLASS = "hashtag"
    # Default target for auto-linked urls (nil will not add a target attribute)
    DEFAULT_TARGET = nil
    # HTML attribute for robot nofollow behavior (default)
    HTML_ATTR_NO_FOLLOW = " rel=\"nofollow\""

    def auto_link_entities(text, entities, options)
      return text if entities.empty?

      options = options.dup
      options[:url_class] ||= DEFAULT_URL_CLASS
      options[:list_class] ||= DEFAULT_LIST_CLASS
      options[:username_class] ||= DEFAULT_USERNAME_CLASS
      options[:username_url_base] ||= "https://twitter.com/"
      options[:list_url_base] ||= "https://twitter.com/"
      options[:hashtag_class] ||= DEFAULT_HASHTAG_CLASS
      options[:hashtag_url_base] ||= "https://twitter.com/#!/search?q=%23"
      options[:target] ||= DEFAULT_TARGET

      extra_html = HTML_ATTR_NO_FOLLOW unless options[:suppress_no_follow]

      url_entities = (options[:url_entities] || {}).inject({}){|h, e| h[e["url"]] = e; h}

      Twitter::Rewriter.rewrite_entities(text, entities) do |entity, chars|
        if entity[:url]
          url = entity[:url]
          href = if options[:link_url_block]
            options.delete(:link_url_block).call(url)
          else
            html_escape(url)
          end

          display_url = url
          link_text = html_escape(display_url)
          if url_entities[url] && url_entities[url]["display_url"]
            display_url = url_entities[url]["display_url"]
            expanded_url = url_entities[url]["expanded_url"]
            if !options[:title]
              options[:title] = expanded_url
            end

            # Goal: If a user copies and pastes a tweet containing t.co'ed link, the resulting paste
            # should contain the full original URL (expanded_url), not the display URL.
            #
            # Method: Whenever possible, we actually emit HTML that contains expanded_url, and use
            # font-size:0 to hide those parts that should not be displayed (because they are not part of display_url).
            # Elements with font-size:0 get copied even though they are not visible.
            # Note that display:none doesn't work here. Elements with display:none don't get copied.
            #
            # Additionally, we want to *display* ellipses, but we don't want them copied.  To make this happen we
            # wrap the ellipses in a tco-ellipsis class and provide an onCopy handler that sets display:none on
            # everything with the tco-ellipsis class.
            #
            # Exception: pic.twitter.com images, for which expandedUrl = "https://twitter.com/#!/username/status/1234/photo/1
            # For those URLs, display_url is not a substring of expanded_url, so we don't do anything special to render the elided parts.
            # For a pic.twitter.com URL, the only elided part will be the "https://", so this is fine.
            display_url_sans_ellipses = display_url.sub("…", "")
            if expanded_url.include?(display_url_sans_ellipses)
              display_url_index = expanded_url.index(display_url_sans_ellipses)
              before_display_url = expanded_url.slice(0, display_url_index)
              # Portion of expanded_url that comes after display_url
              after_display_url = expanded_url.slice(display_url_index + display_url_sans_ellipses.length, 999999)
              preceding_ellipsis = display_url.match(/^…/) ? "…" : ""
              following_ellipsis = display_url.match(/…$/) ? "…" : ""
              # As an example: The user tweets "hi http://longdomainname.com/foo"
              # This gets shortened to "hi http://t.co/xyzabc", with display_url = "…nname.com/foo"
              # This will get rendered as:
              # <span class='tco-ellipsis'> <!-- This stuff should get displayed but not copied -->
              #   …
              #   <!-- There's a chance the onCopy event handler might not fire. In case that happens,
              #        we include an &nbsp; here so that the … doesn't bump up against the URL and ruin it.
              #        The &nbsp; is inside the tco-ellipsis span so that when the onCopy handler *does*
              #        fire, it doesn't get copied.  Otherwise the copied text would have two spaces in a row,
              #        e.g. "hi  http://longdomainname.com/foo".
              #   <span style='font-size:0'>&nbsp;</span>
              # </span>
              # <span style='font-size:0'>  <!-- This stuff should get copied but not displayed -->
              #   http://longdomai
              # </span>
              # <span class='js-display-url'> <!-- This stuff should get displayed *and* copied -->
              #   nname.com/foo
              # </span>
              # <span class='tco-ellipsis'> <!-- This stuff should get displayed but not copied -->
              #   <span style='font-size:0'>&nbsp;</span>
              #   …
              # </span>
              invisible = "style='font-size:0; line-height:0'"
              link_text = "<span class='tco-ellipsis'>#{preceding_ellipsis}<span #{invisible}>&nbsp;</span></span><span #{invisible}>#{html_escape before_display_url}</span><span class='js-display-url'>#{html_escape display_url_sans_ellipses}</span><span #{invisible}>#{after_display_url}</span><span class='tco-ellipsis'><span #{invisible}>&nbsp;</span>#{following_ellipsis}</span>"
            end
          end

          # FIXME should merge with other options like class specifications.
          options[:html_attrs] ||= {}
          options[:html_attrs][:class]  = options[:url_class]
          options[:html_attrs][:target] = options[:target]
          options[:html_attrs][:rel]    = "nofollow" unless options[:suppress_no_follow]
          html_attrs = autolink_html_attrs(options[:html_attrs])

          %(<a href="#{href}"#{html_attrs}>#{link_text}</a>)
        elsif entity[:hashtag]
          hashtag = entity[:hashtag]
          hash = chars[entity[:indices].first]
          yield(hashtag) if block_given?
          href = if options[:hashtag_url_block]
            options[:hashtag_url_block].call(hashtag)
          else
            "#{options[:hashtag_url_base]}#{html_escape(hashtag)}"
          end
          %(<a href="#{href}" title="##{html_escape(hashtag)}" #{target_tag(options)}class="#{options[:url_class]} #{options[:hashtag_class]}"#{extra_html}>#{hash}#{html_escape(hashtag)}</a>)
        elsif entity[:screen_name]
          name = "#{entity[:screen_name]}#{entity[:list_slug]}"
          chunk = block_given? ? yield(name) : name
          at = options[:username_include_symbol] ? '' : chars[entity[:indices].first]
          at_before_user = options[:username_include_symbol] ? chars[entity[:indices].first] : ''

          if !entity[:list_slug].empty? && !options[:suppress_lists]
            href = if options[:list_url_block]
              options[:list_url_block].call(name.downcase)
            else
              "#{html_escape(options[:list_url_base])}#{html_escape(name.downcase)}"
            end
            %(#{at}<a class="#{options[:url_class]} #{options[:list_class]}" #{target_tag(options)}href="#{href}"#{extra_html}>#{html_escape(at_before_user + chunk)}</a>)
          else
            href = if options[:username_url_block]
              options[:username_url_block].call(chunk)
            else
              "#{html_escape(options[:username_url_base])}#{html_escape(chunk)}"
            end
            %(#{at}<a class="#{options[:url_class]} #{options[:username_class]}" #{target_tag(options)}href="#{href}"#{extra_html}>#{html_escape(at_before_user + chunk)}</a>)
          end
        end
      end
    end

    # Add <tt><a></a></tt> tags around the usernames, lists, hashtags and URLs in the provided <tt>text</tt>. The
    # <tt><a></tt> tags can be controlled with the following entries in the <tt>options</tt>
    # hash:
    #
    # <tt>:url_class</tt>::     class to add to all <tt><a></tt> tags
    # <tt>:list_class</tt>::    class to add to list <tt><a></tt> tags
    # <tt>:username_class</tt>::    class to add to username <tt><a></tt> tags
    # <tt>:hashtag_class</tt>::    class to add to hashtag <tt><a></tt> tags
    # <tt>:username_url_base</tt>::      the value for <tt>href</tt> attribute on username links. The <tt>@username</tt> (minus the <tt>@</tt>) will be appended at the end of this.
    # <tt>:list_url_base</tt>::      the value for <tt>href</tt> attribute on list links. The <tt>@username/list</tt> (minus the <tt>@</tt>) will be appended at the end of this.
    # <tt>:hashtag_url_base</tt>::      the value for <tt>href</tt> attribute on hashtag links. The <tt>#hashtag</tt> (minus the <tt>#</tt>) will be appended at the end of this.
    # <tt>:username_include_symbol</tt>::    place the <tt>@</tt> symbol within username and list links
    # <tt>:suppress_lists</tt>::    disable auto-linking to lists
    # <tt>:suppress_no_follow</tt>::   Do not add <tt>rel="nofollow"</tt> to auto-linked items
    # <tt>:target</tt>::   add <tt>target="window_name"</tt> to auto-linked items
    def auto_link(text, options = {}, &block)
      auto_link_entities(text, Extractor.extract_entities_with_indices(text, :extract_url_without_protocol => false), options, &block)
    end

    # Add <tt><a></a></tt> tags around the usernames and lists in the provided <tt>text</tt>. The
    # <tt><a></tt> tags can be controlled with the following entries in the <tt>options</tt>
    # hash:
    #
    # <tt>:url_class</tt>::     class to add to all <tt><a></tt> tags
    # <tt>:list_class</tt>::    class to add to list <tt><a></tt> tags
    # <tt>:username_class</tt>::    class to add to username <tt><a></tt> tags
    # <tt>:username_url_base</tt>::      the value for <tt>href</tt> attribute on username links. The <tt>@username</tt> (minus the <tt>@</tt>) will be appended at the end of this.
    # <tt>:username_include_symbol</tt>::    place the <tt>@</tt> symbol within username and list links
    # <tt>:list_url_base</tt>::      the value for <tt>href</tt> attribute on list links. The <tt>@username/list</tt> (minus the <tt>@</tt>) will be appended at the end of this.
    # <tt>:suppress_lists</tt>::    disable auto-linking to lists
    # <tt>:suppress_no_follow</tt>::   Do not add <tt>rel="nofollow"</tt> to auto-linked items
    # <tt>:target</tt>::   add <tt>target="window_name"</tt> to auto-linked items
    def auto_link_usernames_or_lists(text, options = {}, &block) # :yields: list_or_username
      auto_link_entities(text, Extractor.extract_mentions_or_lists_with_indices(text), options, &block)
    end

    # Add <tt><a></a></tt> tags around the hashtags in the provided <tt>text</tt>. The
    # <tt><a></tt> tags can be controlled with the following entries in the <tt>options</tt>
    # hash:
    #
    # <tt>:url_class</tt>::     class to add to all <tt><a></tt> tags
    # <tt>:hashtag_class</tt>:: class to add to hashtag <tt><a></tt> tags
    # <tt>:hashtag_url_base</tt>::      the value for <tt>href</tt> attribute. The hashtag text (minus the <tt>#</tt>) will be appended at the end of this.
    # <tt>:suppress_no_follow</tt>::   Do not add <tt>rel="nofollow"</tt> to auto-linked items
    # <tt>:target</tt>::   add <tt>target="window_name"</tt> to auto-linked items
    def auto_link_hashtags(text, options = {}, &block)  # :yields: hashtag_text
      auto_link_entities(text, Extractor.extract_hashtags_with_indices(text), options, &block)
    end

    def auto_link_urls(text, options = {}, &block)
      auto_link_entities(text, Extractor.extract_urls_with_indices(text, :extract_url_without_protocol => false), options, &block)
    end

    # These methods are deprecated, will be removed in future.
    extend Deprecation

    # <b>DEPRECATED</b> Please use <tt>auto_link_urls</tt> instead.
    # Add <tt><a></a></tt> tags around the URLs in the provided <tt>text</tt>. Any
    # elements in the <tt>href_options</tt> hash will be converted to HTML attributes
    # and place in the <tt><a></tt> tag. Unless <tt>href_options</tt> contains <tt>:suppress_no_follow</tt>
    # the <tt>rel="nofollow"</tt> attribute will be added.
    def auto_link_urls_custom(text, options = {})
      options = options.dup
      html_attrs = extract_html_attrs_for_options!(options)
      auto_link_urls(text, options.merge(:html_attrs => html_attrs))
    end
    deprecate :auto_link_urls_custom, :auto_link_urls

    private

    HTML_ENTITIES = {
      '&' => '&amp;',
      '>' => '&gt;',
      '<' => '&lt;',
      '"' => '&quot;',
      "'" => '&#39;'
    }

    def html_escape(text)
      text && text.to_s.gsub(/[&"'><]/) do |character|
        HTML_ENTITIES[character]
      end
    end

    # We will make this private in future.
    public :html_escape

    # Options which should not be passed as HTML attributes
    OPTIONS_NOT_ATTRIBUTES = Set.new([
      :url_class, :list_class, :username_class, :hashtag_class,
      :username_url_base, :list_url_base, :hashtag_url_base,
      :username_url_block, :list_url_block, :hashtag_url_block, :link_url_block,
      :username_include_symbol, :suppress_lists, :suppress_no_follow, :url_entities,
      :html_attrs
    ]).freeze

    def extract_html_attrs_for_options!(options)
      html_attrs = {}
      options.reject! do |key, value|
        if OPTIONS_NOT_ATTRIBUTES.include?(key)
          html_attrs[key] = value
          true
        end
      end
      html_attrs
    end

    BOOLEAN_ATTRIBUTES = Set.new([:disabled, :readonly, :multiple, :checked]).freeze

    def autolink_html_attrs(options)
      options.inject("") do |attrs, (key, value)|
        if BOOLEAN_ATTRIBUTES.include?(key)
          value = value ? key : nil
        end
        if !value.nil?
          attrs << %( #{html_escape(key)}="#{html_escape(value)}")
        end
        attrs
      end
    end

    def target_tag(options)
      target_option = options[:target].to_s
      if target_option.empty?
        ""
      else
        "target=\"#{html_escape(target_option)}\""
      end
    end
  end
end
