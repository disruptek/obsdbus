import std/os
import std/macros

import nimline

import bus
import spec

cppIncludes("obs")

defineCppType(ObsOutput, "obs_output_t", "obs-module.h")
defineCppType(ObsSource, "obs_source_t", "obs-module.h")
defineCppType(ObsEncoder, "obs_encoder_t", "obs-module.h")
defineCppType(ObsService, "obs_service_t", "obs-module.h")

defineCppType(ObsOutputInfo, "obs_output_info", "obs-module.h")
defineCppType(ObsSourceInfo, "obs_source_info", "obs-module.h")
defineCppType(ObsEncoderInfo, "obs_encoder_info", "obs-module.h")
defineCppType(ObsServiceInfo, "obs_service_info", "obs-module.h")

defineCppType(ObsProperties, "obs_properties_t", "obs-module.h")
defineCppType(ObsData, "obs_data_t", "obs-module.h")

defineCppType(OsEvent, "os_event_t", "util/threading.h")
#defineCppType(OsEventType, "os_event_type", "util/threading.h")

type
  OsEventType = enum Manual, Automatic
  OsEventPtr = ptr OsEvent

proc os_event_init(eventPtr: ptr OsEventPtr; typ: OsEventType): cint
  {.header: "util/threading.h", importc.}
proc os_event_destroy(event: OsEventPtr)
  {.header: "util/threading.h", importc.}
proc os_event_try(event: OsEventPtr)
  {.header: "util/threading.h", importc.}

const
  pluginName = "DBus"
  obsLibrary {.strdefine.} = "libobs.so"

cppLibs(obsLibrary)

type
  SurfacePtr = ptr ObsSource or
               ptr ObsEncoder or
               ptr ObsService or
               ptr ObsOutput

  # plugin-specific context
  Plugin[T: SurfacePtr] = ptr object
    data: T
    initialized: bool
    stop: OsEventPtr
    thread: PluginThread[T]

  PluginThread[T] = Thread[Payload[T]]

  # thread-specific context
  PayLoad[T: SurfacePtr] = ref object
    data: T
    plugin: Plugin[T]

### threading
proc runThread[T](payload: Payload[T]) {.thread.} =
  let
    iface = init()
  while true:
    iface.process
    sleep 1000

### plugin procs
let
  settings {.compileTime.} = ident"settings"
  data {.compileTime.} = ident"data"

# generates a slew of procs for each type of payload
template generator(name: untyped; head: string) =
  proc `obsplugin_destroy _ name`*(plugin: ptr Plugin[ptr `Obs name`])
    {.cdecl, exportc, dynlib.} =
    if plugin != nil:
      dealloc plugin

  proc `obsplugin_create _ name`*(`settings`: ptr ObsData;
                                  `data`: ptr `Obs name`):
                                  ptr Plugin[ptr `Obs name`]
    {.cdecl, exportc, dynlib.} =
    let
      size = sizeof Plugin[ptr `Obs name`]

    # alloc our state object
    result = cast[ptr Plugin[ptr `Obs name`]](alloc0(size))
    result.data = data

    # setup our signal monitor
    if os_event_init(addr result.stop, Manual) != 0:
      `obsplugin_destroy _ name`(result)
      return

    # create the thread to handle dbus
    createThread(result.thread, runThread,
                 Payload[ptr `Obs name`](data: data, plugin: result[]))

    # mark the object as initialized for destroy purposes
    result.initialized = true

  proc `obsplugin_get_name _ name`*(plugin: ptr Plugin[ptr `Obs name`]): cstring
    {.cdecl, exportc, dynlib.} =
    result = pluginName.cstring

  # setup the object for plugic registration
  var
    `nim _ name` {.inject, importc, nodecl.}: `Obs name Info`

  # registry
  proc registerPlugin(info: ptr `Obs name Info`; size: csize_t)
    {.cdecl, dynlib: obsLibrary, importc: head.}

expandMacros:
  generator source, "obs_register_source_s"
  generator encoder, "obs_register_encoder_s"
  generator service, "obs_register_service_s"
  generator output, "obs_register_output_s"

### module procs
# a single special pointer to the plugin module
defineCppType(ObsModule, "obs_module_t", "obs-module.h")

var
  obsModulePointer: ptr ObsModule

proc obs_module_set_pointer(module: ptr ObsModule) {.cdecl, exportc, dynlib.} =
  obsModulePointer = module

proc obs_current_module(): ptr ObsModule {.cdecl, exportc, dynlib.} =
  obsModulePointer

proc obs_module_ver(): uint32 {.cdecl, exportc, dynlib.} =
  global.LIBOBS_API_VER.to(uint32)

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
  registerPlugin(addr nim_source, sizeof(ObsSourceInfo).csize_t)
  registerPlugin(addr nim_output, sizeof(ObsOutputInfo).csize_t)
  registerPlugin(addr nim_encoder, sizeof(ObsEncoderInfo).csize_t)
  registerPlugin(addr nim_service, sizeof(ObsServiceInfo).csize_t)
  result = true
