(* A simple definition of [conjunction] in terms of [earliest]. *)

open Either

let[@inline] extract s =
  match s with Left x | Right x -> x

let conjunction task1 task2 =
  let fut1 = spawn (fun () -> Left  task1)
  and fut2 = spawn (fun () -> Right task2) in
  match wait (raw_earliest fut1 fut2) with
  | Left result1 ->
      if result1 then extract (wait fut2) else result1
  | Right result2 ->
      if result2 then extract (wait fut1) else result2

(* This definition seems pleasant, but is not as efficient as one might
   hope. Suppose, for example, that [fut1] wins the race. The edge that
   leads from [fut1] to [fut2] is deactivated when [earliest] terminates,
   but is possibly immediately reactivated if we find that we must wait on
   [fut2]. Furthermore, in this scenario, two calls to [wait] take place.
   Below, we give a lower-level definition of [conjunction], which avoids
   the deactivation/reactivation issue and needs only one call to [wait]. *)
