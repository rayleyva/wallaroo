use "net"
use "collections"
use "buffy/messages"

actor DataSender
  let _target_name: String
  var _conn: TCPConnection
  let _held: Queue[Array[U8] val] = Queue[Array[U8] val]
  var _sending: Bool = true

  new create(target_name: String, conn: TCPConnection) =>
    _target_name = target_name
    _conn = conn

  be write(msg_data: Array[U8] val) =>
    _held.enqueue(msg_data)
    if _sending then
      _conn.write(msg_data)
    end

  be ack(msg_count: U64) =>
    for i in Range(0, msg_count.usize()) do
      try _held.dequeue() end
    end

  be ack_reconnect(msg_count: U64) =>
    ack(msg_count)

    if not _sending then
      enable_sending()
    end

  be reconnect(conn: TCPConnection) =>
    _conn = conn
    _sending = false

  be enable_sending() =>
    for idx in Range(0, _held.size()) do
      try
        let next_msg = _held(idx)
        _conn.write(next_msg)
      end
    end
    _sending = true

  be dispose() =>
    _conn.dispose()