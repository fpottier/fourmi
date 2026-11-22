(* -------------------------------------------------------------------------- *)

(* [draw weights] returns a valid index into the array [weights].
   This index is chosen at random according to the distribution
   of weights given by the array [weights]. *)

type weight =
  int

type weights =
  weight array

exception ZeroPick

let draw weights : int =
  let weight = Array.fold_left (+) 0 weights in
  if weight = 0 then raise ZeroPick;
  let w = Random.int weight in
  (* Use a linear scan. *)
  let rec loop i sum =
    let sum = sum + weights.(i) in
    if w < sum then i
    else loop (i+1) sum
  in
  loop 0 0

(* -------------------------------------------------------------------------- *)

(* [choose choices] chooses an action from the array of weighted actions
   [choices] and runs it, producing a result of type ['a]. *)

type 'a action =
  unit -> 'a

type 'a choice =
  weight * 'a action

type 'a choices =
  'a choice array

let choose (choices : 'a choices) : 'a =
  let i = draw (Array.map fst choices) in
  let _weight, action = choices.(i) in
  action()

(* [constants w xs] turns an array of values into an array of weighted
   actions, where every action has weight [w]. *)

let constants w (xs : 'a array) : 'a choices =
  Array.map (fun x -> w, (fun () -> x)) xs

(* [map] transforms a list of choices. *)

let map (f : 'a -> 'b) (choices : 'a choices) : 'b choices =
  choices |> Array.map @@ fun (w, action) ->
  w, fun () -> f (action())

(* [nope] is an empty list of choices. *)

let nope =
  [||]

(* [singleton w action] builds a singleton choice with weight [w]. *)

let singleton w action =
  [| (w, action) |]

(* Concatenation. *)

let (@) =
  Array.append

(* -------------------------------------------------------------------------- *)

(* [postincrement c] is [c++]. *)

let postincrement c =
  let x = !c in
  c := x + 1;
  x

(* [mkfresh()] returns a generator of fresh variables named [x0], [x1],
   etc. *)

let mkfresh () : _ -> string =
  let c = ref 0 in
  fun _ ->
    Printf.sprintf "x%d" (postincrement c)
