module IconsHelper
  def icon_tag(name, **options)
    css_classes = [ "icon", options.delete(:class) ].compact.join(" ")
    svg_style = "--svg: url(#{image_path("#{name}.svg")})"
    style = [ svg_style, options.delete(:style) ].compact.join("; ")

    tag.span nil, class: css_classes, style: style, aria: { hidden: true }, **options
  end
end
