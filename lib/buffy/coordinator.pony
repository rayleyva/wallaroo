use "net"
use "buffy/messages"

actor Coordinator
  let _node_name: String
  let _listeners: Array[TCPListener] = Array[TCPListener]
  let _connections: Array[TCPConnection] = Array[TCPConnection]
  var _phone_home_connection: (TCPConnection | None) = None
  var _topology_manager: (TopologyManager | None) = None

  new create(name: String) =>
    _node_name = name

  be shutdown() =>
    match _topology_manager
    | let t: TopologyManager =>
      t.shutdown()
    else
      finish_shutdown()
    end

  be finish_shutdown() =>
    for listener in _listeners.values() do
      listener.dispose()
    end
    for conn in _connections.values() do
      conn.dispose()
    end

    match _phone_home_connection
    | let phc: TCPConnection =>
      phc.write(WireMsgEncoder.done_shutdown(_node_name))
      phc.dispose()
    end

  be add_phone_home_connection(conn: TCPConnection) =>
    _phone_home_connection = conn

  be add_listener(listener: TCPListener) =>
    _listeners.push(listener)

  be add_connection(conn: TCPConnection) =>
    _connections.push(conn)

  be add_topology_manager(tm: TopologyManager) =>
    _topology_manager = tm
