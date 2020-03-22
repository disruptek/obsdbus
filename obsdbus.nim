import std/os
import std/macros

import bus
import spec

const
  pluginName = "DBus"
  obsLibrary {.strdefine.} = "libobs.so"

{.pragma: obsMod, header: "obs-module.h".}
{.pragma: obsThread, header: "util/threading.h".}
{.pragma: obsLib, dynlib: obsLibrary.}

type
  OsEvent {.obsThread, incompleteStruct, importc: "os_event_t".} = object
  ObsModule {.obsMod, incompleteStruct, importc: "obs_module_t".} = object
  ObsData {.obsMod, incompleteStruct, importc: "obs_data".} = object
  ObsProperties {.obsMod, incompleteStruct, importc: "obs_properties_t".} = object

  OsEventType {.size: sizeof(cint).} = enum Manual, Automatic
  OsEventPtr = ptr OsEvent

proc os_event_init(eventPtr: ptr OsEventPtr; typ: OsEventType): cint
  {.obsThread, importc.}
proc os_event_destroy(event: OsEventPtr)
  {.obsThread, importc.}
proc os_event_try(event: OsEventPtr)
  {.obsThread, importc.}

### plugin procs
when true:
  let
    settingsId {.compileTime.} = ident"settings"
    dataId {.compileTime.} = ident"data"
    infoId {.compileTime.} = ident"info"
    sizeId {.compileTime.} = ident"size"
    pluginId {.compileTime.} = ident"Plugin"

# generates a slew of procs for each type of payload
template generator2(name: untyped; head: string) =
  type
    `obs _ name _ info` {.obsMod, inject,
                          importc: "obs_" & head & "_info".} = object
    `obs _ name` {.obsMod, inject, incompleteStruct,
                   importc: "obs_" & head.} = object

    # plugin-specific context
    pluginId[T: `obs _ name`] = ptr object
      data: ptr T
      initialized: bool
      stop: OsEventPtr
      thread: pluginThread[T]

    pluginThread[T: `obs _ name`] = Thread[Payload[T]]

    # thread-specific context
    PayLoad[T: `obs _ name`] = ref object
      data: ptr T
      plugin: pluginId[T]

  ### threading
  proc runThread[T: `obs _ name`](payload: Payload[T]) {.thread.} =
    let
      iface = init()
    while true:
      iface.process
      sleep 1000

  proc `obsplugin_destroy _ name`*(plugin: ptr pluginId[`obs _ name`])
    {.cdecl, exportc, dynlib.} =
    if plugin != nil:
      dealloc plugin

  proc `obsplugin_create _ name`*(`settingsId`: ptr ObsData;
                                  `dataId`: ptr `obs _ name`):
                                  ptr pluginId[`obs _ name`]
    {.cdecl, exportc, dynlib.} =
    let
      size = sizeof pluginId[`obs _ name`]

    # alloc our state object
    result = cast[ptr pluginId[`obs _ name`]](alloc0(size))
    result.data = dataId

    # setup our signal monitor
    if os_event_init(addr result.stop, Manual) != 0:
      `obsplugin_destroy _ name`(result)
      return

    # create the thread to handle dbus
    createThread(result.thread, runThread,
                 Payload[`obs _ name`](data: dataId, plugin: result[]))

    # mark the object as initialized for destroy purposes
    result.initialized = true

  proc `obsplugin_get_name _ name`*(plugin: ptr pluginId[`obs _ name`]): cstring
    {.cdecl, exportc, dynlib.} =
    result = pluginName.cstring

  # setup the object for plugic registration
  var
    `nim _ name` {.inject, importc, nodecl.}: `obs _ name _ info`

  # registry
  proc obs_register_plugin(infoId: ptr `obs _ name _ info`; sizeId: csize_t)
    {.cdecl, dynlib: obsLibrary, importc: "obs_register_" & head & "_s".}

expandMacros:
  generator2 output, "output"
generator2 source, "source"
generator2 encoder, "encoder"
generator2 service, "service"

### module procs
var
  LIBOBS_API_VER {.obsMod, importc.}: uint32
  # a single special pointer to the plugin module
  obsModulePointer: ptr ObsModule

proc obs_module_set_pointer(module: ptr ObsModule) {.cdecl, exportc, dynlib.} =
  obsModulePointer = module

proc obs_current_module(): ptr ObsModule {.cdecl, exportc, dynlib.} =
  result = obsModulePointer

proc obs_module_ver(): uint32 {.cdecl, exportc, dynlib.} =
  result = LIBOBS_API_VER

# https://obsproject.com/docs/reference-sources.html#c.obs_source_info
# https://obsproject.com/docs/reference-outputs.html#c.obs_output_info
# https://obsproject.com/docs/reference-encoders.html#c.obs_encoder_info
# https://obsproject.com/docs/reference-services.html#c.obs_service_info
proc obs_module_load(): bool {.cdecl, exportc, dynlib.} =
  {.emit: """

/* emit from inside nim... */
struct obs_source_info nim_source = { 0 };
nim_source.id           = "nim_source";
nim_source.type         = OBS_SOURCE_TYPE_INPUT;
nim_source.output_flags = OBS_SOURCE_VIDEO;
nim_source.get_name     = obsplugin_get_name_source;
nim_source.create       = obsplugin_create_source;
nim_source.destroy      = obsplugin_destroy_source;

struct obs_output_info nim_output = { 0 };
nim_output.id           = "nim_output";
nim_output.flags        = OBS_OUTPUT_AV | OBS_OUTPUT_ENCODED;
nim_output.get_name     = obsplugin_get_name_output;
nim_output.create       = obsplugin_create_output;
nim_output.destroy      = obsplugin_destroy_output;

struct obs_encoder_info nim_encoder = { 0 };
nim_encoder.id           = "nim_encoder";
nim_encoder.type         = OBS_ENCODER_VIDEO;
nim_encoder.codec        = "h264";
nim_encoder.get_name     = obsplugin_get_name_encoder;
nim_encoder.create       = obsplugin_create_encoder;
nim_encoder.destroy      = obsplugin_destroy_encoder;

struct obs_service_info nim_service = { 0 };
nim_service.id           = "nim_service";
nim_service.get_name     = obsplugin_get_name_service;
nim_service.create       = obsplugin_create_service;
nim_service.destroy      = obsplugin_destroy_service;

  """.}
  obs_register_plugin(addr nim_source, sizeof(obs_source_info).csize_t)
  obs_register_plugin(addr nim_output, sizeof(obs_output_info).csize_t)
  obs_register_plugin(addr nim_encoder, sizeof(obs_encoder_info).csize_t)
  obs_register_plugin(addr nim_service, sizeof(obs_service_info).csize_t)
  result = true
