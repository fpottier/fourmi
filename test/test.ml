type 'a task =
  unit -> 'a

(* The signature of an implementation. *)
module type S = sig
  val run : 'a task -> 'a
  val yield : unit -> unit
  val conjunction : bool task -> bool task -> bool
  val disjunction : bool task -> bool task -> bool
end

(* The syntax of a task. *)
type syntax =
| Var :
    int -> syntax
| BoolLit :
    bool -> syntax
| Seq :
    syntax * syntax -> syntax
| Let :
    syntax * syntax -> syntax
| Yield :
    syntax
| Conjunction :
    syntax * syntax -> syntax
| Disjunction :
    syntax * syntax -> syntax

let yield s =
  Seq (Yield, s)

(* Splitting a random budget. *)

let split budget =
  if budget = 0 then
    0, 0
  else
    let budget1 = Random.int (budget+1) in
    budget1, budget - budget1

(* A generator of random (well-typed) tasks. *)

(* [n] is the desired size. *)

(* For now, [env] is just an integer.
   Every variable has type [bool]. *)

let rec generate (env : int) (budget : int) : syntax =
  assert (0 <= budget);
  if budget = 0 then
    (* The target size is zero. Produce a variable or a Boolean literal. *)
    let x = Random.int (env + 1) in
    if x = env then
      BoolLit (Random.bool())
    else
      Var x
  else
    (* The target size is nonzero. *)
    yield @@
    (* Produce a conjunction or disjunction. *)
    (* For now, we bind no variables. *)
    match Random.int 2 with
    | 0 ->
        let budget1, budget2 = split (budget-1) in
        Conjunction (generate env budget1, generate env budget2)
    | _ ->
        let budget1, budget2 = split (budget-1) in
        Disjunction (generate env budget1, generate env budget2)

(* Values. *)

type value =
  | VBool of bool
  | VUnit

let vBool b =
  VBool b

let asBool v =
  match v with VBool b -> b | _ -> assert false

let vUnit () =
  VUnit

let asUnit v =
  match v with VUnit -> () | _ -> assert false

let related v1 v2 =
  match v1, v2 with
  | VBool b1, VBool b2 ->
      b1 = b2
  | VUnit, VUnit ->
      true
  | _, _ ->
      assert false

(* Environments. *)

let empty =
  []

let lookup env x =
  List.nth env x

let extend env v =
  v :: env

(* An interpreter of (well-typed) tasks. *)

module Eval (I : S) = struct

let rec eval env (s : syntax) : value =
  match s with
  | Var x ->
      lookup env x
  | BoolLit b ->
      b
      |> vBool
  | Seq (s1, s2) ->
      let () = eval env s1 |> asUnit in
      eval env s2
  | Let (s1, s2) ->
      let v1 = eval env s1 in
      let env = extend env v1 in
      eval env s2
  | Yield ->
      I.yield()
      |> vUnit
  | Conjunction (s1, s2) ->
      I.conjunction
        (fun () -> eval env s1 |> asBool)
        (fun () -> eval env s2 |> asBool)
      |> vBool
  | Disjunction (s1, s2) ->
      I.disjunction
        (fun () -> eval env s1 |> asBool)
        (fun () -> eval env s2 |> asBool)
      |> vBool

let run (s : syntax) : value =
  I.run (fun () -> eval empty s)

end

(* The reference implementation. *)
module R = Eval(Reference)

(* The candidate implementation. *)
module C = Eval(Fourmi.Async)

(* One test run. *)

exception Fail

let test budget =
  let s = generate 0 budget in
  let rv = R.run s in
  let cv = C.run s in
  if not (related rv cv) then
    raise Fail

(* The main program. *)

let iterations =
  1000

let budget =
  1000

let () =
  for _i = 1 to iterations do
    test budget
  done;
  Printf.eprintf "Successfully performed %d test runs.\n%!" iterations
