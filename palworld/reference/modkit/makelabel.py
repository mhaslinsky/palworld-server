"""Create the PrimaryAssetLabel that makes our mod cook into its own chunk.

A LogicMod pak is a CHUNK of the cook, not a separate build. The label is what assigns our
assets a chunk id; without it they land in chunk 0 with the whole game and no usable pak comes
out. Chunk ids below 1000 are reserved by the kit's own conventions, hence 1001.
"""
import unreal

MOD_NAME = "AutoHatchFix"
MOD_DIR = "/Game/Mods/" + MOD_NAME
CHUNK_ID = 1001

unreal.log("PACKPREP: mod dir exists = {}".format(unreal.EditorAssetLibrary.does_directory_exist(MOD_DIR)))

label_path = "{}/Label_{}".format(MOD_DIR, MOD_NAME)
if unreal.EditorAssetLibrary.does_asset_exist(label_path):
    unreal.log("PACKPREP: label already exists, deleting to rebuild it cleanly")
    unreal.EditorAssetLibrary.delete_asset(label_path)

factory = unreal.PrimaryAssetLabelFactory()
tools = unreal.AssetToolsHelpers.get_asset_tools()
label = tools.create_asset("Label_" + MOD_NAME, MOD_DIR, unreal.PrimaryAssetLabel, factory)
if label is None:
    unreal.log_error("PACKPREP: FAILED to create the label")
else:
    # Always-cook plus explicit chunk id. Without bIsRuntimeLabel/cook rule set, an asset that
    # nothing references gets dropped from the cook entirely, and our ModActor is referenced by
    # nothing inside the project: it is loaded at runtime by UE4SS.
    label.set_editor_property("chunk_id", CHUNK_ID)
    rules = label.get_editor_property("rules")
    rules.set_editor_property("chunk_id", CHUNK_ID)
    rules.set_editor_property("cook_rule", unreal.PrimaryAssetCookRule.ALWAYS_COOK)
    label.set_editor_property("rules", rules)
    unreal.EditorAssetLibrary.save_asset(label_path)
    unreal.log("PACKPREP: created {} chunk_id={}".format(label_path, CHUNK_ID))

for asset in unreal.EditorAssetLibrary.list_assets(MOD_DIR, recursive=True):
    unreal.log("PACKPREP: asset {}".format(asset))
unreal.log("PACKPREP: DONE")
