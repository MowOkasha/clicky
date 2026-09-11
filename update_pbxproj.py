import os
from pbxproj import XcodeProject

project_path = '/Users/okasha/clicky/leanring-buddy.xcodeproj/project.pbxproj'
project = XcodeProject.load(project_path)

files_to_remove = [
    'AssemblyAIStreamingTranscriptionProvider.swift',
    'ClaudeAPI.swift',
    'ClickyAnalytics.swift',
    'ElevenLabsTTSClient.swift',
    'OpenAIAPI.swift',
    'OpenAIAudioTranscriptionProvider.swift'
]

files_to_add = [
    'leanring-buddy/LocalTTSClient.swift',
    'leanring-buddy/LocalVisionProcessor.swift',
    'leanring-buddy/Mem0Client.swift',
    'leanring-buddy/OllamaAPI.swift',
    'leanring-buddy/OllamaModelMemoryManager.swift'
]

for file in files_to_remove:
    # We find files by their name
    file_refs = project.get_files_by_name(file)
    if file_refs:
        for file_ref in file_refs:
            print(f"Removing {file}")
            project.remove_file_by_id(file_ref.get_id())
    else:
        print(f"File {file} not found in project")

for file_path in files_to_add:
    print(f"Adding {file_path}")
    project.add_file(file_path, parent=project.get_or_create_group('leanring-buddy'), force=False)

project.save()
print("Project saved successfully.")
