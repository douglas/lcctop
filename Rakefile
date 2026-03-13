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

desc "Install cctop plugin into ~/.claude/plugins/"
task :install_plugin do
  plugins_dir = File.expand_path("~/.claude/plugins")
  src  = File.expand_path("plugins/cctop", __dir__)
  dest = File.join(plugins_dir, "cctop")
  FileUtils.mkdir_p(plugins_dir)
  FileUtils.ln_sf(src, dest)
  puts "Linked #{dest} -> #{src}"
end
