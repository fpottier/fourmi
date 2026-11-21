type 'a task =
  unit -> 'a
  (* task is allowed to spawn, wait, yield *)

type 'a future
  (* can a future created by one instance of [run] be used outside of it? *)

val spawn: 'a task -> 'a future
  (* the new thread does not start running immediately; it starts
     running only if and when its result is awaited. A thread can be
     paused if its result is no longer awaited, and can be resumed if
     its result is awaited again. *)

(**[spawn_join task] is equivalent to [spawn task |> join].
   It is also equivalent to [spawn (fun () -> wait (task()))]. *)
val spawn_join : 'a future task -> 'a future

val wait : 'a future -> 'a

val yield: unit -> unit

val par  : 'a task -> 'b task -> 'a * 'b

val earliest: 'a task -> 'a task -> 'a

val select: 'a task -> 'b task -> ('a, 'b) Either.t

val conjunction: bool task -> bool task -> bool

val run : 'a task -> 'a

(**[return x] is equivalent to [spawn (fun () -> x)],
   and is more efficient. *)
val return : 'a -> 'a future
val bind : 'a future -> ('a -> 'b future) -> 'b future

(**[map f fut] is equivalent to [spawn @@ fun () -> wait fut |> f].
   It is also equivalent to [bind fut (fun x -> return (f x))].
   It is more efficient than either of these expressions. *)
val map : ('a -> 'b) -> 'a future -> 'b future

val join : 'a future future -> 'a future

module Future : sig
  val earliest: 'a future -> 'a future -> 'a future
  val select: 'a future -> 'b future -> ('a, 'b) Either.t future
  val conjunction: bool future -> bool future -> bool future
end
