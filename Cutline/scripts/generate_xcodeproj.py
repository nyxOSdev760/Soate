#!/usr/bin/env python3
"""Generates Cutline.xcodeproj (project.pbxproj + shared scheme) from the files
in Cutline/. Run from the Cutline folder after adding or removing source files:

    python3 scripts/generate_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = "Cutline"
PROJECT = "Cutline.xcodeproj"
BUNDLE_ID = "com.example.cutline"


def oid(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def quote(value):
    safe = all(c.isalnum() or c in "._/$" for c in value) and value != ""
    return value if safe else '"' + value.replace('"', '\\"') + '"'


def collect():
    """Returns a tree: {"name": str, "path": str, "children": [...], "files": [...]}."""
    def walk(rel):
        node = {"path": rel, "groups": [], "files": []}
        full = os.path.join(ROOT, rel)
        for entry in sorted(os.listdir(full)):
            if entry.startswith("."):
                continue
            entry_rel = os.path.join(rel, entry)
            entry_full = os.path.join(ROOT, entry_rel)
            if entry.endswith(".xcassets"):
                node["files"].append(entry_rel)
            elif os.path.isdir(entry_full):
                node["groups"].append(walk(entry_rel))
            elif entry.endswith(".swift") or entry == "Info.plist":
                node["files"].append(entry_rel)
        return node
    return walk(APP_DIR)


def file_type(path):
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    if path.endswith(".plist"):
        return "text.plist.xml"
    return "text"


def main():
    tree = collect()
    objects = {}
    sources = []
    resources = []

    def add_group(node, is_root=False):
        child_ids = []
        for group in node["groups"]:
            child_ids.append(add_group(group))
        for path in node["files"]:
            ref = oid("ref", path)
            name = os.path.basename(path)
            objects[ref] = (
                "PBXFileReference",
                f"{{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; path = {quote(name)}; sourceTree = \"<group>\"; }}",
            )
            child_ids.append(ref)
            if path.endswith(".swift"):
                build = oid("build", path)
                objects[build] = (
                    "PBXBuildFile",
                    f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}",
                )
                sources.append((build, name))
            elif path.endswith(".xcassets"):
                build = oid("build", path)
                objects[build] = (
                    "PBXBuildFile",
                    f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}",
                )
                resources.append((build, name))
        gid = oid("group", node["path"])
        children = "".join(f"\n\t\t\t\t{c}," for c in child_ids)
        name = os.path.basename(node["path"])
        objects[gid] = (
            "PBXGroup",
            f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = ({children}\n\t\t\t);\n\t\t\tpath = {quote(name)};\n\t\t\tsourceTree = \"<group>\";\n\t\t}}",
        )
        return gid

    app_group = add_group(tree, is_root=True)

    product_ref = oid("product", "Cutline.app")
    objects[product_ref] = (
        "PBXFileReference",
        "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Cutline.app; sourceTree = BUILT_PRODUCTS_DIR; }",
    )
    products_group = oid("group", "Products")
    objects[products_group] = (
        "PBXGroup",
        f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{product_ref} /* Cutline.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}}",
    )
    main_group = oid("group", "main")
    objects[main_group] = (
        "PBXGroup",
        f"{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_group} /* Cutline */,\n\t\t\t\t{products_group} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}}",
    )

    sources_phase = oid("phase", "sources")
    files = "".join(f"\n\t\t\t\t{b} /* {n} in Sources */," for b, n in sorted(sources, key=lambda x: x[1]))
    objects[sources_phase] = (
        "PBXSourcesBuildPhase",
        f"{{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ({files}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}",
    )
    frameworks_phase = oid("phase", "frameworks")
    objects[frameworks_phase] = (
        "PBXFrameworksBuildPhase",
        "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}",
    )
    resources_phase = oid("phase", "resources")
    files = "".join(f"\n\t\t\t\t{b} /* {n} in Resources */," for b, n in resources)
    objects[resources_phase] = (
        "PBXResourcesBuildPhase",
        f"{{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ({files}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}",
    )

    def settings_block(settings):
        lines = []
        for key in sorted(settings):
            value = settings[key]
            if isinstance(value, list):
                inner = "".join(f"\n\t\t\t\t\t{quote(v)}," for v in value)
                lines.append(f"\t\t\t\t{key} = ({inner}\n\t\t\t\t);")
            else:
                lines.append(f"\t\t\t\t{key} = {quote(str(value))};")
        return "\n".join(lines)

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
    }
    debug_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    release_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "VALIDATE_PRODUCT": "YES",
    })
    target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Cutline/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }

    configs = {}
    for scope, debug, release in (
        ("project", debug_project, release_project),
        ("target", target_settings, target_settings),
    ):
        ids = []
        for name, settings in (("Debug", debug), ("Release", release)):
            cid = oid("config", scope, name)
            objects[cid] = (
                "XCBuildConfiguration",
                f"{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(settings)}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}}",
            )
            ids.append((cid, name))
        lid = oid("configlist", scope)
        entries = "".join(f"\n\t\t\t\t{c} /* {n} */," for c, n in ids)
        objects[lid] = (
            "XCConfigurationList",
            f"{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = ({entries}\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}}",
        )
        configs[scope] = lid

    target = oid("target", "Cutline")
    objects[target] = (
        "PBXNativeTarget",
        f"{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {configs['target']};\n\t\t\tbuildPhases = (\n\t\t\t\t{sources_phase} /* Sources */,\n\t\t\t\t{frameworks_phase} /* Frameworks */,\n\t\t\t\t{resources_phase} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = Cutline;\n\t\t\tproductName = Cutline;\n\t\t\tproductReference = {product_ref} /* Cutline.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}}",
    )
    project = oid("project", "Cutline")
    objects[project] = (
        "PBXProject",
        f"{{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{target} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {configs['project']};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products_group} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{target} /* Cutline */,\n\t\t\t);\n\t\t}}",
    )

    out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
    by_isa = {}
    for key, (isa, body) in objects.items():
        by_isa.setdefault(isa, []).append((key, body))
    for isa in sorted(by_isa):
        out.append("")
        out.append(f"/* Begin {isa} section */")
        for key, body in sorted(by_isa[isa]):
            if "\n" in body:
                out.append(f"\t\t{key} = {body};")
            else:
                out.append(f"\t\t{key} = {body};")
        out.append(f"/* End {isa} section */")
    out.append("\t};")
    out.append(f"\trootObject = {project} /* Project object */;")
    out.append("}")

    proj_dir = os.path.join(ROOT, PROJECT)
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(out) + "\n")

    workspace_dir = os.path.join(proj_dir, "project.xcworkspace")
    os.makedirs(workspace_dir, exist_ok=True)
    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')

    scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    ref = f'''<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "Cutline.app"
               BlueprintName = "Cutline"
               ReferencedContainer = "container:Cutline.xcodeproj">
            </BuildableReference>'''
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    with open(os.path.join(scheme_dir, "Cutline.xcscheme"), "w") as f:
        f.write(scheme)
    print(f"Wrote {PROJECT} with {len(sources)} Swift files")


if __name__ == "__main__":
    main()
