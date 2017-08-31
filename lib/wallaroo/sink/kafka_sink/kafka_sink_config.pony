use "net"
use "options"
use "pony-kafka"
use "pony-kafka/customlogger"
use "sendence/mort"
use "wallaroo/messages"
use "wallaroo/metrics"
use "wallaroo/sink"


class val KafkaSinkConfigError
  let _message: String

  new val create(m: String) =>
    _message = m

  fun message(): String =>
    _message


primitive KafkaSinkConfigFactory
  fun apply(ksco: KafkaSinkConfigOptions val):
    (KafkaConfig val | KafkaSinkConfigError)
  =>
    let log_level = match ksco.kafka_log_level
      | "Fine" => Fine
      | "Info" => Info
      | "Warn" => Warn
      | "Error" => Error
      else
        return KafkaSinkConfigError("Error! Invalid kafka_sink_log_level: " +
          ksco.kafka_log_level)
      end

    let logger = StringLogger(log_level, ksco.out)

    if (ksco.kafka_brokers.size() == 0) or (ksco.kafka_topic == "") then
      return
        KafkaSinkConfigError("Error! Either brokers is empty or topics is empty!")
    end

    recover
      let kc = KafkaConfig(logger, "Wallaroo Kafka Sink " + ksco.kafka_topic
        where max_message_size' = ksco.kafka_max_message_size,
        max_produce_buffer_ms' = ksco.kafka_max_produce_buffer_ms)

      // add topic config to consumer
      kc.add_topic_config(ksco.kafka_topic, KafkaProduceOnly)

      for (host, port) in ksco.kafka_brokers.values() do
        kc.add_broker(host, port)
      end

      kc
    end

class KafkaSinkConfigOptions
  let kafka_topic: String
  let kafka_brokers: Array[(String, I32)] val
  let kafka_log_level: String
  let kafka_max_produce_buffer_ms: U64
  let kafka_max_message_size: I32
  let out: OutStream

  new val create(kafka_topic': String,
    kafka_brokers': Array[(String, I32)] val,
    kafka_log_level': String,
    kafka_max_produce_buffer_ms': U64,
    kafka_max_message_size': I32,
    out': OutStream)
  =>
    kafka_topic = kafka_topic'
    kafka_brokers = kafka_brokers'
    kafka_log_level = kafka_log_level'
    kafka_max_produce_buffer_ms = kafka_max_produce_buffer_ms'
    kafka_max_message_size = kafka_max_message_size'
    out = out'

primitive KafkaSinkConfigCLIParser
  fun opts(): Array[(String, (None | String), ArgumentType, (Required |
    Optional), String)]
  =>
    // items in the tuple are: Argument Name, Argument Short Name,
    //   Argument Type, Required or Optional, Help Text
    let opts_array = Array[(String, (None | String), ArgumentType, (Required |
      Optional), String)]

    opts_array.push(("kafka_sink_topic", None, StringArgument, Required,
      "Kafka topic to consume from"))
    opts_array.push(("kafka_sink_brokers", None, StringArgument, Required,
      "Initial brokers to connect to. Format: 'host:port,host:port,...'"))
    opts_array.push(("kafka_sink_log_level", None, StringArgument, Required,
      "Log Level (Fine, Info, Warn, Error)"))
    opts_array.push(("kafka_sink_max_produce_buffer_ms", None, I64Argument,
      Required, "# ms to buffer for producing to kafka"))
    opts_array.push(("kafka_sink_max_message_size", None, I64Argument, Required,
      "Max message size in bytes for producing to kafka"))

    opts_array

  fun print_usage(out: OutStream) =>
    for (long, short, arg_type, arg_req, help) in opts().values() do
      let short_str = match short
             | let s: String => "/-" + s
             else "" end

      let arg_type_str = match arg_type
             | StringArgument => "(String)"
             | I64Argument => "(Integer)"
             | F64Argument => "(Float)"
             else "" end

      out.print("--" + long + short_str + "       " + arg_type_str + "    "
        + help)
    end

  fun apply(args: Array[String] val, out: OutStream):
    KafkaSinkConfigOptions val ?
  =>
    var log_level = "Warn"

    var topic = ""
    var brokers = recover val Array[(String, I32)] end

    var max_message_size: I32 = 1000000
    var max_produce_buffer_ms: U64 = 0

    let options = Options(args, false)

    for (long, short, arg_type, arg_req, _) in opts().values() do
      options.add(long, short, arg_type, arg_req)
    end

    // TODO: implement all the other options that kafka client supports
    for option in options do
      match option
      | ("kafka_sink_max_produce_buffer_ms", let input: I64) =>
        max_produce_buffer_ms = input.u64()
      | ("kafka_sink_max_message_size", let input: I64) =>
        max_message_size = input.i32()
      | ("kafka_sink_topic", let input: String) =>
        topic = input
      | ("kafka_sink_brokers", let input: String) =>
        brokers = _brokers_from_input_string(input)
      | ("kafka_sink_log_level", let input: String) =>
        log_level = input
      end
    end

    KafkaSinkConfigOptions(topic, brokers, log_level,
      max_produce_buffer_ms, max_message_size, out)

  fun _brokers_from_input_string(inputs: String): Array[(String, I32)] val ? =>
    let brokers = recover trn Array[(String, I32)] end

    for input in inputs.split(",").values() do
      let i = input.split(":")
      let host = i(0)
      let port: I32 = try i(1).i32() else 9092 end
      brokers.push((host, port))
    end

    consume brokers

  fun _topics_from_input_string(inputs: String): Array[String] val =>
    let topics = recover trn Array[String] end

    for input in inputs.split(",").values() do
      topics.push(input)
    end

    consume topics

class val KafkaSinkConfig[Out: Any val] is SinkConfig[Out]
  let _encoder: KafkaSinkEncoder[Out]
  let _ksco: KafkaSinkConfigOptions val
  let _auth: TCPConnectionAuth

  new val create(encoder: KafkaSinkEncoder[Out],
    ksco: KafkaSinkConfigOptions val,
    auth: TCPConnectionAuth)
  =>
    _encoder = encoder
    _ksco = ksco
    _auth = auth

  fun apply(): SinkBuilder =>
    KafkaSinkBuilder(TypedKafkaEncoderWrapper[Out](_encoder), _ksco, _auth)

class val KafkaSinkBuilder
  let _encoder_wrapper: KafkaEncoderWrapper
  let _ksco: KafkaSinkConfigOptions val
  let _auth: TCPConnectionAuth

  new val create(encoder_wrapper: KafkaEncoderWrapper,
    ksco: KafkaSinkConfigOptions val,
    auth: TCPConnectionAuth)
  =>
    _encoder_wrapper = encoder_wrapper
    _ksco = ksco
    _auth = auth

  fun apply(reporter: MetricsReporter iso): Sink =>
    @printf[I32]("Creating Kafka Sink\n".cstring())

    // create kafka config

    match KafkaSinkConfigFactory(_ksco)
    | let kc: KafkaConfig val =>
      KafkaSink(_encoder_wrapper, consume reporter, kc, _auth)
    | let ksce: KafkaSinkConfigError =>
      @printf[U32]("%s\n".cstring(), ksce.message().cstring())
      Fail()
      EmptySink
    else
      @printf[U32]("Error creating Kafka Sink Config\n".cstring())
      Fail()
      EmptySink
    end
