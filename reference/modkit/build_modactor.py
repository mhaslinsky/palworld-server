"""Create the AutoHatchFix ModActor Blueprint asset.

Run headlessly on the build box:
    ssh ascension-mdns "cmd /c C:\\Users\\mhasl\\runpy.bat C:\\Users\\mhasl\\build_modactor.py"

This gets the asset as far as automation can take it on UE 5.1. The DoHatch function graph is
created but EMPTY: adding its input pins and the call node has to be done by hand in the
Blueprint editor. That is an engine limitation, not an oversight, and it was established by
checking the reflection surface rather than by inferring from missing attributes:

  - EdGraphPin is not a reflected UObject at all. unreal.load_class(None,
    "/Script/Engine.EdGraphPin") returns None, so pins are not script-visible in any form.
  - K2Node_FunctionEntry.UserDefinedPins, which would hold the custom input definitions, is not
    a reflected PROPERTY. Reading it errors "Failed to find property", not "protected and
    cannot be read" as FunctionReference and ExtraFlags on the same object do. So this is not a
    general protection wall; that member was never exposed.
  - K2Node_CallFunction, K2Node_FunctionEntry and K2Node_FunctionResult load and instantiate
    fine, confirming they are real UClasses, but none of their useful members are UFUNCTIONs,
    so nothing on them can be called from Python.

Node-level graph editing in 5.1 lives in FKismetEditorUtilities, UEdGraphSchema_K2 and
UK2Node::CreatePin, all C++ only. The manual steps that finish this asset are recorded in
reference/README.md.
"""
import unreal

PACKAGE_PATH = "/Game/Mods/AutoHatchFix"
ASSET_NAME = "ModActor"   # This exact name is what makes UE4SS mount the pak as a LogicMod.
FUNC_NAME = "DoHatch"

asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
factory = unreal.BlueprintFactory()
factory.set_editor_property("parent_class", unreal.Actor)

blueprint = asset_tools.create_asset(ASSET_NAME, PACKAGE_PATH, unreal.Blueprint, factory)
graph = unreal.BlueprintEditorLibrary.add_function_graph(blueprint, func_name=FUNC_NAME)

unreal.BlueprintEditorLibrary.compile_blueprint(blueprint)
unreal.EditorAssetLibrary.save_loaded_asset(blueprint)
unreal.log("BUILD: created {}/{} with empty {} graph".format(PACKAGE_PATH, ASSET_NAME, FUNC_NAME))
