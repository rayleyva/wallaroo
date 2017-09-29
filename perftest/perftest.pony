/*

Copyright 2017 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "buffered"
use "collections"
use "serialise"
use "wallaroo_labs/bytes"
use "wallaroo"
use "wallaroo/core/common"
use "wallaroo_labs/mort"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/source/tcp_source"
use "wallaroo/core/state"
use "wallaroo/core/topology"

actor Main
  new create(env: Env) =>
    try
      let letter_partition = Partition[Votes val, String](
        LetterPartitionFunction, PartitionFileReader("letters.txt",
          env.root as AmbientAuth))

      let application = recover val
        Application("Alphabet Popularity Contest")
          // I: Run with just new_pipeline() to done()
          .new_pipeline[Votes val, LetterTotal val]("Alphabet Votes",
            TCPSourceConfig[Votes val].from_options(VotesDecoder,
              TCPSourceConfigCLIParser(env.args)(0)))
            // II: Try with .to() as well
            .to[LetterTotal val](LTBuilder)
            // V: Later you could use this with .to_state_partition
            // .to[Votes val](IdentityBuilder[Votes val])
            // III: Comment out .to and try with to_state_partition()
            // .to_state_partition[Votes val, String, LetterTotal val,
            //   LetterState](AddVotes, LetterStateBuilder, "letter-state",
            //   letter_partition where multi_worker = true)
            .done()
            // IV: Comment out .done() and try with to_sink()
            // .to_sink(TCPSinkConfig[LetterTotal val].from_options(
            //   LetterTotalEncoder,
            //   TCPSinkConfigCLIParser(env.args)(0)))
            // VI: You could also try with multiple .to() in a row
      end
      Startup(env, application, "alphabet-contest")
    else
      @printf[I32]("Couldn't build topology\n".cstring())
    end

primitive LT
  fun name(): String => "identity"
  fun apply(r: Votes val): LetterTotal val =>
    LetterTotal("a", 20)

primitive LTBuilder
  fun apply(): Computation[Votes val, LetterTotal val] val =>
    LT

primitive Identity[In: Any val]
  fun name(): String => "identity"
  fun apply(r: In): In =>
    // @printf[I32]("Identity!!\n".cstring())
    r

primitive IdentityBuilder[In: Any val]
  fun apply(): Computation[In, In] val =>
    Identity[In]

class val LetterStateBuilder
  fun apply(): LetterState => LetterState
  fun name(): String => "Letter State"

class LetterState is State
  var letter: String = " "
  var count: U64 = 0

class AddVotesStateChange is StateChange[LetterState]
  var _id: U64
  var _votes: Votes val = Votes(" ", 0)

  new create(id': U64) =>
    _id = id'

  fun name(): String => "AddVotes"
  fun id(): U64 => _id

  fun ref update(votes': Votes val) =>
    _votes = votes'

  fun apply(state: LetterState ref) =>
    state.letter = _votes.letter
    state.count = state.count + _votes.count

  fun write_log_entry(out_writer: Writer) =>
    out_writer.u32_be(_votes.letter.size().u32())
    out_writer.write(_votes.letter)
    out_writer.u64_be(_votes.count)

  fun ref read_log_entry(in_reader: Reader) ? =>
    let letter_size = in_reader.u32_be().usize()
    let letter = String.from_array(in_reader.block(letter_size))
    let count = in_reader.u64_be()
    _votes = Votes(letter, count)

class AddVotesStateChangeBuilder is StateChangeBuilder[LetterState]
  fun apply(id: U64): StateChange[LetterState] =>
    AddVotesStateChange(id)

primitive AddVotes is StateComputation[Votes val, LetterTotal val, LetterState]
  fun name(): String => "Add Votes"

  fun apply(votes: Votes val,
    sc_repo: StateChangeRepository[LetterState],
    state: LetterState): (LetterTotal val, StateChange[LetterState] ref)
  =>
    let state_change: AddVotesStateChange ref =
      try
        sc_repo.lookup_by_name("AddVotes") as AddVotesStateChange
      else
        AddVotesStateChange(0)
      end

    state_change.update(votes)

    (LetterTotal(votes.letter, votes.count + state.count), state_change)

  fun state_change_builders():
    Array[StateChangeBuilder[LetterState]] val
  =>
    recover val
      let scbs = Array[StateChangeBuilder[LetterState]]
      scbs.push(recover val AddVotesStateChangeBuilder end)
      scbs
    end

primitive VotesDecoder is FramedSourceHandler[Votes val]
  fun header_length(): USize =>
    4

  fun payload_length(data: Array[U8] iso): USize =>
    5

  fun decode(data: Array[U8] val): Votes val ? =>
    // Assumption: 1 byte for letter
    let letter = String.from_array(data.trim(0, 1))
    let count = Bytes.to_u32(data(1), data(2), data(3), data(4))
    Votes(letter, count.u64())

primitive LetterPartitionFunction
  fun apply(votes: Votes val): String =>
    votes.letter

class Votes
  let letter: String
  let count: U64

  new val create(l: String, c: U64) =>
    letter = l
    count = c

class LetterTotal
  let letter: String
  let count: U64

  new val create(l: String, c: U64) =>
    letter = l
    count = c

primitive LetterTotalEncoder
  fun apply(t: LetterTotal val, wb: Writer = Writer): Array[ByteSeq] val =>
    wb.u32_be(9)
    wb.write(t.letter) // Assumption: letter is 1 byte
    wb.u64_be(t.count)
    wb.done()
