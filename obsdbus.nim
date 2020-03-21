import std/os
import std/macros

import nimline

import bus
import spec

cppIncludes("obs")

defineCppType(ObsModule, "obs_module_t", "obs-module.h")

defineCppType(ObsEncoder, "obs_encoder_t", "obs-module.h")
defineCppType(ObsSource, "obs_source_t", "obs-module.h")
defineCppType(ObsOutput, "obs_output_t", "obs-module.h")
defineCppType(ObsService, "obs_service_t", "obs-module.h")

defineCppType(ObsServiceInfo, "obs_service_info", "obs-module.h")
defineCppType(ObsOutputInfo, "obs_output_info", "obs-module.h")
defineCppType(ObsEncoderInfo, "obs_encoder_info", "obs-module.h")
defineCppType(ObsSourceInfo, "obs_source_info", "obs-module.h")

defineCppType(ObsProperties, "obs_properties_t", "obs-module.h")
defineCppType(ObsData, "obs_data_t", "obs-module.h")

defineCppType(OsEvent, "os_event_t", "util/threading.h")
#defineCppType(OsEventType, "os_event_type", "util/threading.h")

type
  OsEventType = enum Manual, Automatic

proc os_event_init(event: ptr ptr OsEvent; typ: OsEventType): cint
                  {.header: "util/threading.h", cdecl, importcpp.}
proc os_event_destroy(event: ptr OsEvent)
                     {.header: "util/threading.h", cdecl, importcpp.}
proc os_event_try(event: ptr OsEvent)
                  {.header: "util/threading.h", cdecl, importcpp.}


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
    stop: ptr OsEvent
    thread: PluginThread[T]

  PluginThread[T] = Thread[Payload[T]]

  # thread-specific context
  PayLoad[T: SurfacePtr] = ref object
    data: T
    plugin: Plugin[T]

var
  obsModulePointer: ptr ObsModule
  nim_source {.importc, nodecl.}: ObsSourceInfo
  nim_output {.importc, nodecl.}: ObsOutputInfo
  nim_encoder {.importc, nodecl.}: ObsEncoderInfo
  nim_service {.importc, nodecl.}: ObsServiceInfo

### threading
proc runThread[T](payload: Payload[T]) {.thread.} =
  let
    iface = init()
  while true:
    iface.process
    sleep 1000
  return

### plugin procs
let
  settings {.compileTime.} = ident"settings"
  data {.compileTime.} = ident"data"

# generates a slew of procs; one for each type of payload
template generator(name: untyped) =
  proc `obsplugin_destroy name`*(plugin: ptr Plugin[ptr `Obs name`])
    {.cdecl, exportc, dynlib.} =
    if plugin != nil:
      dealloc plugin

  proc `obsplugin_create name`*(`settings`: ptr ObsData;
                                `data`: ptr `Obs name`): ptr Plugin[ptr `Obs name`] {.cdecl, exportc, dynlib.} =
    let
      size = sizeof Plugin[ptr `Obs name`]

    # alloc our state object
    result = cast[ptr Plugin[ptr `Obs name`]](alloc0(size))
    result.data = data

    # setup our signal monitor
    if os_event_init(addr result.stop, Manual) != 0:
      `obsplugin_destroy name`(result)
      return

    # create the thread to handle dbus
    createThread(result.thread, runThread,
                 Payload[ptr `Obs name`](data: data, plugin: result[]))

    # mark the object as initialized for destroy purposes
    result.initialized = true

  proc `obsplugin_get_name name`*(plugin: ptr Plugin[ptr `Obs name`]): cstring
    {.cdecl, exportc, dynlib.} =
    result = pluginName.cstring

generator source
generator encoder
generator service
generator output

### registry
proc registerPlugin(info: ptr ObsSourceInfo; size: csize_t)
  {.cdecl, dynlib: obsLibrary, importc: "obs_register_source_s".}

proc registerPlugin(info: ptr ObsOutputInfo; size: csize_t)
  {.cdecl, dynlib: obsLibrary, importc: "obs_register_output_s".}

proc registerPlugin(info: ptr ObsEncoderInfo; size: csize_t)
  {.cdecl, dynlib: obsLibrary, importc: "obs_register_encoder_s".}

proc registerPlugin(info: ptr ObsServiceInfo; size: csize_t)
  {.cdecl, dynlib: obsLibrary, importc: "obs_register_service_s".}

### module procs
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
nim_source.get_name     = obsplugin_get_namesource;
nim_source.create       = obsplugin_createsource;
nim_source.destroy      = obsplugin_destroysource;

struct obs_output_info nim_output = { 0 };
nim_output.id           = "nim_output";
nim_output.flags        = OBS_OUTPUT_AV | OBS_OUTPUT_ENCODED;
nim_output.get_name     = obsplugin_get_nameoutput;
nim_output.create       = obsplugin_createoutput;
nim_output.destroy      = obsplugin_destroyoutput;

struct obs_encoder_info nim_encoder = { 0 };
nim_encoder.id           = "nim_encoder";
nim_encoder.type         = OBS_ENCODER_VIDEO;
nim_encoder.codec        = "h264";
nim_encoder.get_name     = obsplugin_get_nameencoder;
nim_encoder.create       = obsplugin_createencoder;
nim_encoder.destroy      = obsplugin_destroyencoder;

struct obs_service_info nim_service = { 0 };
nim_service.id           = "nim_service";
nim_service.get_name     = obsplugin_get_nameservice;
nim_service.create       = obsplugin_createservice;
nim_service.destroy      = obsplugin_destroyservice;

  """.}
  registerPlugin(addr nim_source, sizeof(ObsSourceInfo).csize_t)
  registerPlugin(addr nim_output, sizeof(ObsOutputInfo).csize_t)
  registerPlugin(addr nim_encoder, sizeof(ObsEncoderInfo).csize_t)
  registerPlugin(addr nim_service, sizeof(ObsServiceInfo).csize_t)
  result = true
