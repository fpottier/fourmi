type 'a diagnostic =
  | Valid of 'a
  | Invalid of string

type 'a task =
  unit -> 'a

let run task =
  task()

let yield () =
  ()

let conjunction task1 task2 =
  task1() && task2()

let disjunction task1 task2 =
  task1() || task2()

(* [earliest] is a non-deterministic operation, so we need to accept
   the candidate's result [result] and to compare it with our possible
   two results, [result1] and [result2]. We assume that the function
   [related] is able to determine whether a reference value and a
   candidate value are related. *)

let earliest
  (type r c)
  (related : r -> c -> bool)
  (task1 : r task)
  (task2 : r task)
  (result : c)
: r diagnostic =
  let result1 = task1()
  and result2 = task2() in
  if related result1 result then
    Valid result1
  else if related result2 result then
    Valid result2
  else
    Invalid "earliest"
