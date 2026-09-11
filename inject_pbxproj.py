import uuid
import re

def generate_id():
    return uuid.uuid4().hex[:24].upper()

files_to_add = [
    'LocalTTSClient.swift',
    'LocalVisionProcessor.swift',
    'Mem0Client.swift',
    'OllamaAPI.swift',
    'OllamaModelMemoryManager.swift'
]

project_path = '/Users/okasha/clicky/leanring-buddy.xcodeproj/project.pbxproj'
with open(project_path, 'r') as f:
    content = f.read()

# For each file, we need:
# 1. PBXBuildFile
# 2. PBXFileReference
# 3. Add to PBXGroup
# 4. Add to PBXSourcesBuildPhase

# We know the main group for leanring-buddy is 28F22CBF2F56440300A0FC59 (actually that's Clicky.app)
# Let's find the group for the source files.
group_match = re.search(r'([0-9A-F]{24}) /\* leanring-buddy \*/ = \{\n\s*isa = PBXGroup;\n\s*children = \(\n(.*?)\);', content, re.DOTALL)
if not group_match:
    print("Could not find PBXGroup")
    exit(1)

group_id = group_match.group(1)
group_children = group_match.group(2)

build_phase_match = re.search(r'([0-9A-F]{24}) /\* Sources \*/ = \{\n\s*isa = PBXSourcesBuildPhase;\n\s*buildActionMask = [0-9]+;\n\s*files = \(\n(.*?)\);', content, re.DOTALL)
if not build_phase_match:
    print("Could not find PBXSourcesBuildPhase")
    exit(1)

build_phase_id = build_phase_match.group(1)
build_phase_files = build_phase_match.group(2)

new_build_files = []
new_file_refs = []
new_group_children = []
new_sources = []

for filename in files_to_add:
    file_ref_id = generate_id()
    build_file_id = generate_id()
    
    new_file_refs.append(f"\t\t{file_ref_id} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = \"<group>\"; }};")
    new_build_files.append(f"\t\t{build_file_id} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};")
    
    new_group_children.append(f"\t\t\t\t{file_ref_id} /* {filename} */,")
    new_sources.append(f"\t\t\t\t{build_file_id} /* {filename} in Sources */,")

# Insert PBXBuildFile
content = content.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n" + "\n".join(new_build_files) + "\n")

# Insert PBXFileReference
content = content.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + "\n".join(new_file_refs) + "\n")

# Update PBXGroup
updated_group_children = group_children + "\n".join(new_group_children) + "\n"
content = content.replace(group_children, updated_group_children, 1)

# Update PBXSourcesBuildPhase
updated_sources = build_phase_files + "\n".join(new_sources) + "\n"
content = content.replace(build_phase_files, updated_sources, 1)

with open(project_path, 'w') as f:
    f.write(content)

print("Injected successfully.")
