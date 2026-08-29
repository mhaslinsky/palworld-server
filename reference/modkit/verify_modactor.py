"""Verify the ModActor asset from a FRESH editor process.

Run this as a separate invocation from build_modactor.py. Verifying inside the run that created
an asset proves only that the objects are live in memory; it says nothing about what reached
disk. This is the same rule that governs the Lua side of this project, where a call reporting
success while consuming nothing cost several test rounds.

There is no direct "get the parent class" call in the Python API, so the parent chain is proven
by instantiating the class default object and asking whether it IS an Actor.
"""
import unreal

PATH = "/Game/Mods/AutoHatchFix/ModActor"

blueprint = unreal.EditorAssetLibrary.load_asset(PATH)
unreal.log("VERIFY: loaded = {}".format(blueprint is not None))
if blueprint is None:
    unreal.log_error("VERIFY: asset absent from disk")
else:
    generated = blueprint.generated_class()
    unreal.log("VERIFY: generated_class = {}".format(generated.get_name() if generated else None))
    cdo = unreal.get_default_object(generated) if generated else None
    unreal.log("VERIFY: parent chain reaches Actor = {}".format(isinstance(cdo, unreal.Actor)))
    graph = unreal.BlueprintEditorLibrary.find_graph(blueprint, "DoHatch")
    unreal.log("VERIFY: DoHatch graph present = {}".format(graph is not None))
unreal.log("VERIFY: DONE")
