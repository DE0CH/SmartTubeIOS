# Removes the Apple Watch app (and its complications) from the iOS app's dependencies and
# embed phases, so archiving the iOS app neither builds nor signs it.
#   ruby drop-watch.rb <path/to/Project.xcodeproj>      (needs the xcodeproj gem)
require "xcodeproj"
project = Xcodeproj::Project.open(ARGV.fetch(0))
watch = project.targets.select { |t| t.name.start_with?("SmartTubeWatch") }
project.targets.reject { |t| watch.include?(t) }.each do |t|
  t.dependencies.select { |d| watch.include?(d.target) }.each(&:remove_from_project)
  t.copy_files_build_phases.each do |phase|
    phase.files.select { |f| f.display_name.to_s.include?("SmartTubeWatch") }.each { |f| phase.remove_build_file(f) }
  end
end
project.save
puts "watch targets detached: #{watch.map(&:name).join(', ')}"
