require 'xcodeproj'

project_path = '/Users/okasha/clicky/leanring-buddy.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath('leanring-buddy', false)

# Files deleted from disk — remove from Xcode project
files_to_remove = [
  'LocalVisionProcessor.swift',
  'ElementLocationDetector.swift'
]

# New files added to disk — add to Xcode project
files_to_add = [
  'AgentToolDefinition.swift',
  'AgentToolExecutor.swift',
  'AgentLoop.swift'
]

# Remove deleted files
files_to_remove.each do |file_name|
  file_ref = group.files.find { |f| f.path == file_name || f.name == file_name }
  if file_ref
    puts "Removing #{file_name} from project"
    target.source_build_phase.remove_file_reference(file_ref)
    file_ref.remove_from_project
  else
    puts "#{file_name} not found in project (already removed?)"
  end
end

# Add new files
files_to_add.each do |file_name|
  # Skip if already in the project
  if group.files.any? { |f| f.path == file_name || f.name == file_name }
    puts "#{file_name} already in project — skipping"
    next
  end

  file_path = File.join(group.real_path, file_name)
  unless File.exist?(file_path)
    puts "WARNING: #{file_name} not found on disk at #{file_path}"
    next
  end

  puts "Adding #{file_name} to project"
  file_ref = group.new_reference(file_path)
  target.source_build_phase.add_file_reference(file_ref)
end

project.save
puts "Project saved successfully"
