import std/os
import std/macros

import bus
import spec

const
  pluginName = "DBus"
  obsLibrary {.strdefine.} = "libobs.so"

{.pragma: obsMod, header: "obs-module.h".}
{.pragma: obsEncoder, header: "obs-encoder.h".}
{.pragma: obsProps, header: "obs-properties.h".}
{.pragma: obsThread, header: "util/threading.h".}
{.pragma: obsLib, dynlib: obsLibrary.}

type
  # encoder stuff
  encoder_frame {.obsEncoder, incompleteStruct, importc.} = object
  encoder_packet {.obsEncoder, incompleteStruct, importc.} = object

  OsEvent {.obsThread, incompleteStruct, importc: "os_event_t".} = object
  ObsModule {.obsMod, incompleteStruct, importc: "obs_module_t".} = object
  ObsData {.obsMod, incompleteStruct, importc: "obs_data".} = object
  ObsProperties {.obsProps,
                  incompleteStruct, importc: "obs_properties".} = object

  OsEventType {.size: sizeof(cint).} = enum Manual, Automatic
  OsEventPtr = ptr OsEvent


proc obs_properties_create(): ptr ObsProperties
  {.obsProps, importc.}
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
template generator(name: untyped; head: string) =
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
    echo "THREAD RUNNING FOR ", iface
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
    echo "CREATE PLUGIN INSTANCE FOR ", head
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
    #result = cstring(pluginName & "-" & head)

  # setup the object for plugic registration
  var
    `nim _ name` {.inject, importc, nodecl.}: `obs _ name _ info`

  # registry
  proc obs_register_plugin(infoId: ptr `obs _ name _ info`; sizeId: csize_t)
    {.cdecl, dynlib: obsLibrary, importc: "obs_register_" & head & "_s".}

  # properties for each plugin module
  proc `obsplugin_get_properties _ name`(plugin: ptr pluginId[`obs _ name`]): ptr ObsProperties
    {.cdecl, exportc, dynlib.} =
    result = obs_properties_create()

  proc `obsplugin_get_defaults _ name`(settingsId: ptr ObsData)
    {.cdecl, exportc, dynlib.} =
    discard

  when head == "encoder":
    proc obsplugin_encoder_encode(plugin: ptr pluginId[`obs _ name`];
                                  frame: ptr encoder_frame;
                                  packet: ptr encoder_packet;
                                  received: bool): bool
      {.cdecl, exportc, dynlib.} =
      discard
  elif head == "output":
    proc obsplugin_output_encoded_packet(plugin: ptr pluginId[`obs _ name`];
                                         packet: ptr encoder_packet)
      {.cdecl, exportc, dynlib.} =
      discard
    proc obsplugin_output_start(plugin: ptr pluginId[`obs _ name`]): bool
      {.cdecl, exportc, dynlib.} =
      discard

    proc obsplugin_output_stop(plugin: ptr pluginId[`obs _ name`]; ts: uint64)
      {.cdecl, exportc, dynlib.} =
      discard
  elif head == "source":
    proc obsplugin_source_get_width(plugin: ptr pluginId[`obs _ name`]): uint32
      {.cdecl, exportc, dynlib.} =
      discard

    proc obsplugin_source_get_height(plugin: ptr pluginId[`obs _ name`]): uint32
      {.cdecl, exportc, dynlib.} =
      discard

expandMacros:
  generator encoder, "encoder"
generator output, "output"
generator source, "source"
generator service, "service"

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
  echo "libobs version: ", result

# https://obsproject.com/docs/reference-sources.html#c.obs_source_info
# https://obsproject.com/docs/reference-outputs.html#c.obs_output_info
# https://obsproject.com/docs/reference-encoders.html#c.obs_encoder_info
# https://obsproject.com/docs/reference-services.html#c.obs_service_info
proc obs_module_load(): bool {.cdecl, exportc, dynlib.} =
  echo "module load"
  {.emit: """

/* emit from inside nim... */
struct obs_source_info nim_source = { 0 };
nim_source.id           = "nim_source";
nim_source.type         = OBS_SOURCE_TYPE_INPUT;
nim_source.output_flags = OBS_SOURCE_ASYNC_VIDEO;
nim_source.get_name     = obsplugin_get_name_source;
nim_source.create       = obsplugin_create_source;
nim_source.destroy      = obsplugin_destroy_source;
nim_source.get_width    = obsplugin_source_get_width;
nim_source.get_height   = obsplugin_source_get_height;
nim_source.get_properties = obsplugin_get_properties_source;
nim_source.get_defaults   = obsplugin_get_defaults_source;

struct obs_output_info nim_output = { 0 };
nim_output.id           = "nim_output";
nim_output.flags        = OBS_OUTPUT_AV | OBS_OUTPUT_ENCODED;
nim_output.get_name     = obsplugin_get_name_output;
nim_output.create       = obsplugin_create_output;
nim_output.destroy      = obsplugin_destroy_output;
nim_output.start        = obsplugin_output_start;
nim_output.stop         = obsplugin_output_stop;
nim_output.encoded_packet = obsplugin_output_encoded_packet;
nim_output.get_properties = obsplugin_get_properties_output;
nim_output.get_defaults   = obsplugin_get_defaults_output;

struct obs_encoder_info nim_encoder = { 0 };
nim_encoder.id           = "nim_encoder";
nim_encoder.type         = OBS_ENCODER_VIDEO;
nim_encoder.codec        = "h264";
nim_encoder.get_name     = obsplugin_get_name_encoder;
nim_encoder.create       = obsplugin_create_encoder;
nim_encoder.destroy      = obsplugin_destroy_encoder;
nim_encoder.encode       = obsplugin_encoder_encode;
nim_encoder.get_properties = obsplugin_get_properties_encoder;
nim_encoder.get_defaults   = obsplugin_get_defaults_encoder;

struct obs_service_info nim_service = { 0 };
nim_service.id           = "nim_service";
nim_service.get_name     = obsplugin_get_name_service;
nim_service.create       = obsplugin_create_service;
nim_service.destroy      = obsplugin_destroy_service;
nim_service.get_properties = obsplugin_get_properties_service;
nim_service.get_defaults   = obsplugin_get_defaults_service;

  """.}

  echo "nancy"
  obs_register_plugin(addr nim_source, sizeof(obs_source_info).csize_t)
  obs_register_plugin(addr nim_output, sizeof(obs_output_info).csize_t)
  obs_register_plugin(addr nim_encoder, sizeof(obs_encoder_info).csize_t)
  obs_register_plugin(addr nim_service, sizeof(obs_service_info).csize_t)
  echo "sinatra"
  result = true
