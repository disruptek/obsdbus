import dbus
import dbus/lowlevel

import deebus

import spec

template path(kind: ModuleKind): ObjectPath = ObjectPath($kind)

proc init*(): Interface =
  let
    bus = getBus(DBUS_BUS_SESSION)
  result = Interface(bus: bus, service: "com.obsproject.OBS",
                     path: ObjectPath("/"), name: "com.obsproject.OBS")

proc process*(iface: Interface) =
  let
    read = dbusConnectionReadWrite(iface.bus.conn, 0)
    msg = dbusConnectionPopMessage(iface.bus.conn)
  echo "read from iface: ", read.toBool
  if msg == nil:
    return
  if dbus_message_is_method_call(msg, $iface, "Get"):
    echo "got a get"
    var
      args: DBusMessageIter
      param: cstring

    if not dbus_message_iter_init(msg, addr args):
      echo "no arguments"
    elif dtString != dbus_message_iter_get_arg_type(addr args).DbusTypeChar:
      echo "arg wasn't a string"
    else:
      dbus_message_iter_get_basic(addr args, addr param)
      echo "arg is a string `", $param, "`"
    when false:
      var
        query: DBusValue
      try:
        var
          iter = msg.iterate()
        query = iter.unpackCurrent(DBusValue)
      except DBusException: # i hate it
        query = asDbusValue(nil)
    echo "shoulda replied"
    when false:
      var
        reply = dbus_message_new_method_return(msg)
      reply.appendPtr dtString, "i cannot help you".asDbusValue
      sendMessage(iface.bus.conn, reply)
  else:
    echo "got a method call that wasn't get"
