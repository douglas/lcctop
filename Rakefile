require "rake/testtask"
require "fileutils"

LOCAL_BIN = File.expand_path("~/.local/bin")

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/test_*.rb"]
  t.verbose = true
end

task default: :test

desc "Symlink bin/lcctop-hook and bin/lcctop-waybar into ~/.local/bin/"
task :install do
  FileUtils.mkdir_p(LOCAL_BIN)
  %w[lcctop-hook lcctop-waybar].each do |bin|
    src  = File.expand_path("bin/#{bin}", __dir__)
    dest = File.join(LOCAL_BIN, bin)
    next unless File.exist?(src)
    FileUtils.ln_sf(src, dest)
    puts "Linked #{dest} -> #{src}"
  end
end

desc "Install Omarchy theme template and generate current CSS"
task :install_theme do
  themed_dir  = File.expand_path("~/.config/omarchy/themed")
  tpl_src     = File.expand_path("themed/lcctop-waybar.css.tpl", __dir__)
  tpl_dest    = File.join(themed_dir, "lcctop-waybar.css.tpl")
  colors_file = File.expand_path("~/.config/omarchy/current/theme/colors.toml")
  css_out     = File.expand_path("~/.config/omarchy/current/theme/lcctop-waybar.css")

  FileUtils.mkdir_p(themed_dir)
  FileUtils.cp(tpl_src, tpl_dest)
  puts "Installed #{tpl_dest}"

  # Generate CSS for the current theme directly from colors.toml.
  # omarchy-theme-set-templates only runs during theme switches (uses next-theme/);
  # we replicate its sed substitution here for the already-active theme.
  if File.exist?(colors_file)
    vars = {}
    File.readlines(colors_file).each do |line|
      m = line.match(/\A\s*(\w+)\s*=\s*"([^"]+)"/)
      vars[m[1]] = m[2] if m
    end

    css = File.read(tpl_src)
    vars.each { |k, v| css = css.gsub("{{ #{k} }}", v) }
    File.write(css_out, css)
    puts "Generated #{css_out}"
  else
    puts "Note: #{colors_file} not found — run omarchy-theme-set to generate"
  end
end

desc "Install cctop plugin into ~/.claude/plugins/"
task :install_plugin do
  plugins_dir = File.expand_path("~/.claude/plugins")
  src  = File.expand_path("plugins/cctop", __dir__)
  dest = File.join(plugins_dir, "cctop")
  FileUtils.mkdir_p(plugins_dir)
  FileUtils.ln_sf(src, dest)
  puts "Linked #{dest} -> #{src}"
end
