module IconsHelper
  def icon_tag(name, **options)
    css_classes = [ "icon", "icon--#{name}", options.delete(:class) ].compact.join(" ")

    tag.span nil, class: css_classes, aria: { hidden: true }, **options
  end
end
