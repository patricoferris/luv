open Imports

type idle
type t = idle Handle.t

val init : ?loop:Loop.t ptr -> unit -> (t, Error.Code.t) result
val start : callback:(t -> unit) -> t -> Error.Code.t
val stop : t -> Error.Code.t

(* TODO Note about Luv.Handle.close. *)
