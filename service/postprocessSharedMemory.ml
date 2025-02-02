(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
module SharedMemory = Memory

module StringKey = struct
  type t = string

  let to_string = ident

  let compare = String.compare

  type out = t

  let from_string = ident
end

module LocationKey = struct
  type t = Location.t

  let to_string = Location.Reference.show

  let compare = Location.Reference.compare

  type out = string

  let from_string = ident
end

module HandleKey = struct
  type t = File.Handle.t

  let to_string = File.Handle.show

  let compare = File.Handle.compare

  type out = File.Handle.t

  let from_string = File.Handle.create_for_testing
end

module IgnoreValue = struct
  type t = Ast.Ignore.t list

  let prefix = Prefix.make ()

  let description = "Ignore"
end

module LocationListValue = struct
  type t = Location.t list

  let prefix = Prefix.make ()

  let description = "Location list"
end

module ModeValue = struct
  type t = Source.mode

  let prefix = Prefix.make ()

  let description = "Mode"
end

module IgnoreLines = SharedMemory.NoCache (LocationKey) (IgnoreValue)
module IgnoreKeys = SharedMemory.NoCache (StringKey) (LocationListValue)
module ErrorModes = SharedMemory.NoCache (StringKey) (ModeValue)
