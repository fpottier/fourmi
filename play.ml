#require "fourmi";;
open Fourmi.Async

let rec factorial (n : int) : int =
  if n = 0 then 1 else n * factorial (n-1)
;;

let (bar : int) =
  run @@ fun () ->
    let _unused = spawn @@ fun () -> 3 in
    42
;;

let rec fact (n : int) : int =
  Printf.printf "*********** fact(%d) invoked.\n%!" n;
  yield();
  if n = 0 then 1
  else wait (spawn @@ fun () -> n * fact (n-1))
;;

let fact5 : int =
  run @@ fun () ->
    fact 5
;;

let rec ffib (n : int) : int future =
  yield();
  if n <= 1 then
    return 1
  else
    let x = ffib (n-1)
    and y = ffib (n-2) in
    spawn @@ fun () ->
    wait x + wait y
;;

let () =
  assert (run @@ fun () -> wait (ffib 5) = 8)
;;

let mfib : int -> int future =
  let table = Hashtbl.create 128 in
  let rec mfib (n : int) : int future =
    yield();
    Printf.printf "*********** mfib(%d) invoked.\n%!" n;
    match Hashtbl.find table n with
    | fut ->
        fut
    | exception Not_found ->
        let fut =
          spawn @@ fun () ->
          if n <= 1 then 1
          else
            wait (mfib (n-1)) + wait (mfib (n-2))
        in
        Hashtbl.add table n fut;
        fut
  in
  mfib
;;

let () =
  run @@ fun () ->
    let big : bool future =
      spawn @@ fun () ->
      wait (mfib 10) = 89
    in
    (* This should start computing [fact 5 = 17] and [big] in parallel,
       then stop without finishing [big], because the result is [false]. *)
    let foo : bool =
      conjunction
        (spawn @@ fun () -> fact 5 = 17)
        big
      |> wait
    in
    assert (foo = false);
    Printf.printf "*********** The conjunction has returned false.\n%!";
    (* This should resume the computation of [big], producing [true]. *)
    let b = wait big in
    assert b
;;

(*
let fib25 : int =
  run @@ fun () ->
    wait (mfib 25)
;;
*)

let () =
  run @@ fun () ->
    let n1 = 5
    and n2 = 12 in
    let fact1 : int future = spawn @@ fun () -> fact n1
    and fact2 : int future = spawn @@ fun () -> fact n2 in
    let foo : (int, int) Either.t =
      select fact1 fact2
      |> wait
    in
    assert (foo = Either.Left (factorial n1));
    Printf.printf "*********** The selection has returned %d.\n%!" (factorial n1);
    (* This should resume the computation of [fact2]. *)
    Printf.printf "*********** fact(%d) is %d\n%!" n2 (wait fact2)
;;

let () =
  run @@ fun () ->
    let n1 = 5
    and n2 = 12 in
    let fact1 : int future = spawn @@ fun () -> fact n1
    and fact2 : int future = spawn @@ fun () -> fact n2 in
    let foo : int =
      first fact2 fact1
      |> wait
    in
    assert (foo = factorial n1);
    Printf.printf "*********** The cheapest future has returned %d.\n%!" (factorial n1)
;;

let () =
  assert (run @@ fun () -> wait (return 5) = 5)
;;

let () =
  assert (run @@ fun () -> wait (join (return (ffib 5))) = 8)
;;

let () =
  let z =
    run @@ fun () ->
      wait (bind (return 3) (fun x -> return (x + 4)))
  in
  assert (z = 7)
;;
