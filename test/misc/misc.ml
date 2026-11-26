open Printf
module F = Fourmi.Make()
module H = Hashtbl.Make(Int)
module M = Fix.Memoize.ForHashedType(Int)

(* This file contains a small number of handwritten tests. *)

(* Messages. *)

let info format =
  ksprintf (fun msg -> eprintf "[client   ] %s\n%!" msg) format

let announce format =
  ksprintf (fun msg -> eprintf "******************************************************************************\n[new test ] %s\n%!" msg) format

(* Reference implementations. *)

let fact : int -> int =
  M.fix @@ fun fact n ->
    if n = 0 then 1 else n * fact (n-1)

let fib : int -> int =
  M.fix @@ fun fib n ->
    if n <= 1 then 1 else fib(n-1) + fib(n-2)

(* Tests. *)

open F

let () =
  let result = run @@ fun () -> 3 in
  assert (result = 3)

let rec ffact (n : int) : int =
  info "ffact(%d) invoked." n;
  yield();
  if n = 0 then 1
  else n * ffact (n-1)

let () =
  announce "fact 12";
  let result = run @@ fun () -> ffact 12 in
  assert (result = fact 12)

(* exponential time Fibonacci *)
let rec ffib (n : int) : int future =
  spawn @@ fun () ->
  info "ffib(%d) demanded." n;
  yield();
  if n <= 1 then
    1
  else
    let x = ffib (n-1)
    and y = ffib (n-2) in
    wait x + wait y

let () =
  announce "ffib 12";
  let result = run_fut (ffib 12) in
  assert (result = fib 12)

(* linear time Fibonacci, with memoization *)
let (mfib, mfib_table) : (int -> int future) * int future M.t =
  M.visibly_fix @@ fun mfib n ->
  spawn @@ fun () ->
  info "mfib(%d) demanded." n;
  yield();
  if n <= 1 then
    1
  else
    let x = mfib (n-1)
    and y = mfib (n-2) in
    wait x + wait y

let mfib_demanded n =
  H.mem mfib_table n

let () =
  announce "mfib 12";
  let result = run_fut (mfib 12) in
  assert (result = fib 12)

(* Disjunction. *)

let n1 = 24

let n2 = 100

let () =
  announce "disjunction between mfib(%d) and mfib(%d)" n1 n2;
  let b =
    run @@ fun () ->
    disjunction
      (fun () -> wait (mfib n1) = fib n1)
      (fun () -> wait (mfib n2) = fib n2)
  in
  assert (b = true);
  assert (mfib_demanded n2);
  (* [mfib n2] has not been fully computed yet because the left branch
     of the disjunction has returned [true] earlier. *)
  assert (not (mfib_demanded (n2/2)));
  (* We can now finish computing [mfib n2]. *)
  announce "finish computing mfib(%d)" n2;
  let x =
    run @@ fun () ->
    wait (mfib n2)
  in
  assert (x = fib n2)

let () =
  announce "earliest between ffact(%d) and ffact(%d)" n1 n2;
  let fut =
    spawn @@ fun () ->
    earliest
      (fun () -> ffact n1)
      (fun () -> ffact n2)
  in
  assert (run_fut fut = fact n1)

let () =
  announce "ffact(%d) alone" n1;
  assert (fact n1 = run @@ fun () -> ffact n1)

let () =
  announce "return 3";
  let result = run_fut @@ spawn @@ fun () -> 3 in
  assert (result = 3)

let () =
  announce "return 5";
  assert (run @@ fun () -> wait (return 5) = 5)

let () =
  announce "join";
  assert (run @@ fun () -> wait (join (return (ffib 5))) = 8)

let () =
  announce "bind";
  let z =
    run @@ fun () ->
      wait (bind (ffib 5) (fun x -> return (x + wait (mfib 6))))
  in
  assert (z = 21)

(* exponential time Fibonacci, in monadic style *)
let rec mofib (n : int) : int future =
  info "mofib(%d) invoked." n;
  if n <= 1 then
    return 1
  else
    bind (mofib (n-1)) @@ fun x ->
    bind (mofib (n-2)) @@ fun y ->
    return (x + y)

let () =
  announce "monadic fib 6";
  assert (run_fut (mofib 6) = 13)

let () =
  announce "map";
  assert (run_fut (map (fun x -> x + 7) (mofib 6)) = 20)
