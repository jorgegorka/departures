module NavigationHelper
  def nav_link_to(name, path, exact: false)
    link_to name, path, class: "nav__link", aria: { current: nav_current?(path, exact: exact) ? "page" : nil }
  end

  def menu_link_to(name, path, exact: false)
    link_to name, path, class: "menu__item", aria: { current: nav_current?(path, exact: exact) ? "page" : nil }
  end

  def nav_current?(path, exact: false)
    path = URI.parse(url_for(path)).path
    return request.path == path if exact || path == "/"

    request.path == path || request.path.start_with?("#{path}/")
  end

  def nav_section_current?(*paths)
    paths.any? { |path| nav_current?(path) }
  end
end
