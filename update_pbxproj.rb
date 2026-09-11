require 'xcodeproj'

project_path = '/Users/okasha/clicky/leanring-buddy.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath('leanring-buddy', false)

files_to_remove = [
  'AssemblyAIStreamingTranscriptionProvider.swift',
  'ClaudeAPI.swift',
  'ClickyAnalytics.swift',
  'ElevenLabsTTSClient.swift',
  'OpenAIAPI.swift',
  'OpenAIAudioTranscriptionProvider.swift'
]

files_to_add = [
  'LocalTTSClient.swift',
  'LocalVisionProcessor.swift',
  'Mem0Client.swift',
  'OllamaAPI.swift',
  'OllamaModelMemoryManager.swift'
]

# Remove files
files_to_remove.each do |file_name|
  file_ref = group.files.find { |f| f.path == file_name || f.name == file_name }
  if file_ref
    puts "Removing #{file_name} from target"
    target.source_build_phase.remove_file_reference(file_ref)
    file_ref.remove_from_project
  end
end

# Add new files
files_to_add.each do |file_name|
  # Ensure we don't add duplicates
  unless group.files.any? { |f| f.path == file_name || f.name == file_name }
    puts "Adding #{file_name} to target"
    file_path = File.join(group.real_path, file_name)
    file_ref = group.new_file(file_path)
    target.add_file_references([file_ref])
  end
end

project.save
puts "Project saved successfully."
