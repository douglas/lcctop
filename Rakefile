require "rake/testtask"
require "fileutils"
require "json"

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
  %w[lcctop-hook lcctop-waybar lcctop-focus lcctop-pick].each do |bin|
    src  = File.expand_path("bin/#{bin}", __dir__)
    dest = File.join(LOCAL_BIN, bin)
    next unless File.exist?(src)
    FileUtils.ln_sf(src, dest)
    puts "Linked #{dest} -> #{src}"
  end
end

desc "Install Omarchy theme templates and generate current outputs"
task :install_theme do
  themed_dir  = File.expand_path("~/.config/omarchy/themed")
  colors_file = File.expand_path("~/.config/omarchy/current/theme/colors.toml")

  templates = {
    "lcctop-waybar.css.tpl"        => File.expand_path("~/.config/omarchy/current/theme/lcctop-waybar.css"),
    "lcctop-pick-colors.json.tpl"  => File.expand_path("~/.config/omarchy/current/theme/lcctop-pick-colors.json"),
  }

  FileUtils.mkdir_p(themed_dir)
  templates.each_key do |tpl|
    src  = File.expand_path("themed/#{tpl}", __dir__)
    dest = File.join(themed_dir, tpl)
    FileUtils.cp(src, dest)
    puts "Installed #{dest}"
  end

  # Generate outputs for the current theme directly from colors.toml.
  # omarchy-theme-set-templates only runs during theme switches (uses next-theme/);
  # we replicate its sed substitution here for the already-active theme.
  if File.exist?(colors_file)
    vars = {}
    File.readlines(colors_file).each do |line|
      m = line.match(/\A\s*(\w+)\s*=\s*"([^"]+)"/)
      vars[m[1]] = m[2] if m
    end

    templates.each do |tpl, out_path|
      src = File.expand_path("themed/#{tpl}", __dir__)
      content = File.read(src)
      vars.each { |k, v| content = content.gsub("{{ #{k} }}", v) }
      File.write(out_path, content)
      puts "Generated #{out_path}"
    end
  else
    puts "Note: #{colors_file} not found — run omarchy-theme-set to generate"
  end
end

desc "Install cctop plugin into ~/.claude/plugins/ and register hooks in settings.local.json"
task :install_plugin do
  plugins_dir = File.expand_path("~/.claude/plugins")
  src  = File.expand_path("plugins/cctop", __dir__)
  dest = File.join(plugins_dir, "cctop")
  FileUtils.mkdir_p(plugins_dir)
  FileUtils.ln_sf(src, dest)
  puts "Linked #{dest} -> #{src}"

  # Register hooks in settings.local.json.
  # Claude Code does not auto-load hooks.json from local plugins —
  # hooks must be declared in settings.local.json directly.
  settings_path = File.expand_path("~/.claude/settings.local.json")
  run_hook = File.expand_path("~/.claude/plugins/cctop/hooks/run-hook.sh")

  settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
  settings["hooks"] ||= {}
  h = settings["hooks"]

  hook_entries = {
    "SessionStart"     => { "matcher" => "",   "async" => false },
    "UserPromptSubmit" => { "matcher" => ".*", "async" => false },
    "PreToolUse"       => { "matcher" => ".*", "async" => true  },
    "PostToolUse"      => { "matcher" => ".*", "async" => true  },
    "Stop"             => { "matcher" => ".*", "async" => false },
    "Notification"     => { "matcher" => ".*", "async" => false },
    "PermissionRequest"=> { "matcher" => ".*", "async" => false },
    "SubagentStart"    => { "matcher" => ".*", "async" => false },
    "SubagentStop"     => { "matcher" => ".*", "async" => false },
    "PreCompact"       => { "matcher" => ".*", "async" => false },
    "SessionEnd"       => { "matcher" => ".*", "async" => false },
  }

  hook_entries.each do |event, opts|
    cmd = "#{run_hook} #{event}"
    h[event] ||= []
    already = h[event].any? { |e| e["hooks"]&.any? { |hk| hk["command"] == cmd } }
    next if already

    hook_def = { "type" => "command", "command" => cmd }
    hook_def["async"] = true if opts["async"]
    h[event] << { "matcher" => opts["matcher"], "hooks" => [hook_def] }
  end

  File.write(settings_path, JSON.pretty_generate(settings) + "\n")
  puts "Registered lcctop hooks in #{settings_path}"
  puts "Restart Claude Code sessions to activate."
end

desc "Install opencode plugin to ~/.config/opencode/plugins/cctop.js"
task :install_opencode do
  opencode_plugins_dir = File.expand_path("~/.config/opencode/plugins")
  src  = File.expand_path("plugins/opencode/plugin.js", __dir__)
  dest = File.join(opencode_plugins_dir, "cctop.js")

  FileUtils.mkdir_p(opencode_plugins_dir)
  FileUtils.cp(src, dest)
  puts "Installed #{dest}"
  puts
  puts "To activate, add the following to your opencode.json plugin array:"
  puts %|  "file://~/.config/opencode/plugins/cctop.js"|
end

desc "Copy AGS picker + bar widget to ~/.config/ags/lcctop/"
task :install_ags do
  dest = File.expand_path("~/.config/ags/lcctop")
  src  = File.expand_path("plugins/ags", __dir__)
  FileUtils.mkdir_p(File.dirname(dest))
  FileUtils.cp_r(src, dest)
  puts "Installed #{dest}"
  puts
  puts "To run: ags run ~/.config/ags/lcctop/app.tsx --gtk 4"
  puts "To toggle picker: ags request 'toggle lcctop-picker'"
end

desc "Build Tauri panel app"
task :build_tauri do
  Dir.chdir(File.expand_path("plugins/tauri", __dir__)) do
    system "cargo tauri build" or abort "cargo tauri build failed"
  end
end

desc "Install Tauri panel binary to ~/.local/bin/lcctop-panel"
task :install_tauri do
  src  = File.expand_path("plugins/tauri/src-tauri/target/release/lcctop-tauri", __dir__)
  dest = File.expand_path("~/.local/bin/lcctop-panel")
  abort "Run rake build_tauri first" unless File.exist?(src)
  FileUtils.ln_sf(src, dest)
  puts "Linked #{dest} -> #{src}"
  puts
  puts "Add to hyprland.conf:"
  puts File.read(File.expand_path("plugins/tauri/hyprland-rules.conf", __dir__)) rescue nil
end

desc "Inject lcctop hooks into a project's .claude/settings.local.json (use: rake 'install_hooks[/path/to/project]')"
task :install_hooks, [:project_path] do |_, args|
  project_path = args[:project_path]
  abort "Usage: rake 'install_hooks[/path/to/project]'" if project_path.nil? || project_path.empty?

  settings_dir  = File.join(File.expand_path(project_path), ".claude")
  settings_path = File.join(settings_dir, "settings.local.json")
  run_hook      = File.expand_path("~/.claude/plugins/cctop/hooks/run-hook.sh")

  FileUtils.mkdir_p(settings_dir)
  settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
  settings["hooks"] ||= {}
  h = settings["hooks"]

  hook_entries = {
    "SessionStart"     => { "matcher" => "",   "async" => false },
    "UserPromptSubmit" => { "matcher" => ".*", "async" => false },
    "PreToolUse"       => { "matcher" => ".*", "async" => true  },
    "PostToolUse"      => { "matcher" => ".*", "async" => true  },
    "Stop"             => { "matcher" => ".*", "async" => false },
    "Notification"     => { "matcher" => ".*", "async" => false },
    "PermissionRequest"=> { "matcher" => ".*", "async" => false },
    "SubagentStart"    => { "matcher" => ".*", "async" => false },
    "SubagentStop"     => { "matcher" => ".*", "async" => false },
    "PreCompact"       => { "matcher" => ".*", "async" => false },
    "SessionEnd"       => { "matcher" => ".*", "async" => false },
  }

  hook_entries.each do |event, opts|
    cmd = "#{run_hook} #{event}"
    h[event] ||= []
    already = h[event].any? { |e| e["hooks"]&.any? { |hk| hk["command"] == cmd } }
    next if already

    hook_def = { "type" => "command", "command" => cmd }
    hook_def["async"] = true if opts["async"]
    h[event] << { "matcher" => opts["matcher"], "hooks" => [hook_def] }
  end

  File.write(settings_path, JSON.pretty_generate(settings) + "\n")
  puts "Registered lcctop hooks in #{settings_path}"
  puts "Restart Claude Code in that project to activate."
end
