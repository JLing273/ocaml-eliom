(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Format

type t = { stamp: int; name: string; mutable flags: int }

let global_flag = 1
let predef_exn_flag = 2

(* ELIOM *)
let client_flag = 4
let server_flag = 8

let side i =
  let s = (i.flags land server_flag) <> 0 in
  let c = (i.flags land client_flag) <> 0 in
  match s, c with
  | false, false -> Eliom_base.Poly
  | true , false -> Eliom_base.(Loc Server)
  | false, true  -> Eliom_base.(Loc Client)
  | true , true  ->
      invalid_arg
        ("Ident.side: both client and server flags on dentifier "^i.name)

let side_to_flag = let open Eliom_base in function
  | Loc Server -> server_flag
  | Loc Client -> client_flag
  | Poly -> 0

let show_side i = let open Eliom_base in match side i with
  | Loc Client -> "@c"
  | Loc Server -> "@s"
  | Poly -> ""

let flag_with_side s flg =
  (flg land (lnot @@ (client_flag lor server_flag)))
  lor (side_to_flag s)

let change_side s i = i.flags <- flag_with_side s i.flags

let with_side s i = {i with flags = flag_with_side s i.flags }

(* /ELIOM *)

(* A stamp of 0 denotes a persistent identifier *)

let currentstamp = ref 0

let create ?(side=Eliom_base.get_side ()) s =
  incr currentstamp;
  { name = s; stamp = !currentstamp; flags = side_to_flag side }

let create_predef_exn ?(side=Eliom_base.get_side ()) s =
  incr currentstamp;
  { name = s; stamp = !currentstamp; flags = predef_exn_flag lor side_to_flag side}

let create_persistent ?(side=Eliom_base.get_side ()) s =
  { name = s; stamp = 0; flags = global_flag lor side_to_flag side }

(* ELIOM *)
let test ~scope ~idside =
  let open Eliom_base in
  match idside, scope with
  | Poly, Loc l -> Some l
  | _ , Poly -> None
  | Loc _, _ -> None

let new_flag id =
  let idside = side id in
  let scope = Eliom_base.get_side () in
  match test ~scope ~idside with
  | Some l -> flag_with_side (Eliom_base.Loc l) id.flags
  | None -> id.flags
(* /ELIOM *)

let rename i =
  incr currentstamp;
  let flags = new_flag i in (*ELIOM*)
  { i with stamp = !currentstamp ; flags }

let name i = i.name

let with_name i name = {i with name}

let unique_name i = i.name ^ "_" ^ string_of_int i.stamp

let unique_toplevel_name i = i.name ^ "/" ^ string_of_int i.stamp

let persistent i = (i.stamp = 0)

let equal i1 i2 = i1.name = i2.name

let compare i1 i2 = Pervasives.compare i1 i2

let binding_time i = i.stamp

let current_time() = !currentstamp
let set_current_time t = currentstamp := max !currentstamp t

let reinit_level = ref (-1)

let reinit () =
  if !reinit_level < 0
  then reinit_level := !currentstamp
  else currentstamp := !reinit_level

let hide i =
  { i with stamp = -1 }

let make_global i =
  i.flags <- i.flags lor global_flag

let reset_flag i =
  i.flags <- 0

let global i =
  (i.flags land global_flag) <> 0

let is_predef_exn i =
  (i.flags land predef_exn_flag) <> 0

let print ppf i =
  match i.stamp with
  | 0 -> fprintf ppf "%s!%s" i.name (show_side i)
  | -1 -> fprintf ppf "%s#%s" i.name (show_side i)
  | n -> fprintf ppf "%s/%i%s%s" i.name n (if global i then "g" else "") (show_side i)

let not_predef i = i.stamp <= 0 || i.stamp > 35

let same i1 i2 =
  let b =
    if i1.stamp <> 0
    then i1.stamp = i2.stamp
    else i2.stamp = 0 && i1.name = i2.name
  in
  (* Emit a warning if same but not equal.
     This means we are comparing the same ident across different sides.
  *)
  begin if b && !Clflags.verbose && i1 <> i2 then
      Format.eprintf "Warning: Ident.same on different sides in %a scope: %a %a@."
        Eliom_base.pp (Eliom_base.get_side ())
        print i1  print i2
  end ;
  b

type 'a tbl =
    Empty
  | Node of 'a tbl * 'a data * 'a tbl * int

and 'a data =
  { ident: t;
    data: 'a;
    previous: 'a data option }

let empty = Empty

(* Inline expansion of height for better speed
 * let height = function
 *     Empty -> 0
 *   | Node(_,_,_,h) -> h
 *)

let mknode l d r =
  let hl = match l with Empty -> 0 | Node(_,_,_,h) -> h
  and hr = match r with Empty -> 0 | Node(_,_,_,h) -> h in
  Node(l, d, r, (if hl >= hr then hl + 1 else hr + 1))

let balance l d r =
  let hl = match l with Empty -> 0 | Node(_,_,_,h) -> h
  and hr = match r with Empty -> 0 | Node(_,_,_,h) -> h in
  if hl > hr + 1 then
    match l with
    | Node (ll, ld, lr, _)
      when (match ll with Empty -> 0 | Node(_,_,_,h) -> h) >=
           (match lr with Empty -> 0 | Node(_,_,_,h) -> h) ->
        mknode ll ld (mknode lr d r)
    | Node (ll, ld, Node(lrl, lrd, lrr, _), _) ->
        mknode (mknode ll ld lrl) lrd (mknode lrr d r)
    | _ -> assert false
  else if hr > hl + 1 then
    match r with
    | Node (rl, rd, rr, _)
      when (match rr with Empty -> 0 | Node(_,_,_,h) -> h) >=
           (match rl with Empty -> 0 | Node(_,_,_,h) -> h) ->
        mknode (mknode l d rl) rd rr
    | Node (Node (rll, rld, rlr, _), rd, rr, _) ->
        mknode (mknode l d rll) rld (mknode rlr rd rr)
    | _ -> assert false
  else
    mknode l d r

let rec add id data = function
    Empty ->
      Node(Empty, {ident = id; data = data; previous = None}, Empty, 1)
  | Node(l, k, r, h) ->
      let c = compare id.name k.ident.name in
      if c = 0 then
        Node(l, {ident = id; data = data; previous = Some k}, r, h)
      else if c < 0 then
        balance (add id data l) k r
      else
        balance l k (add id data r)

let rec find_stamp s = function
    None ->
      raise Not_found
  | Some k ->
      if k.ident.stamp = s then k.data else find_stamp s k.previous


let rec find_same id = function
    Empty ->
      raise Not_found
  | Node(l, k, r, _) ->
      let c = compare id.name k.ident.name in
      if c = 0 then
        if id.stamp = k.ident.stamp
        then k.data
        else find_stamp id.stamp k.previous
      else
        find_same id (if c < 0 then l else r)

let rec find_name_side s = function
    None ->
      raise Not_found
  | Some k ->
      if Eliom_base.conform ~scope:s ~id:(side k.ident)
      then k
      else find_name_side s k.previous

let rec find_side name s = function
    Empty ->
      raise Not_found
  | Node(l, k, r, _) ->
      let c = compare name k.ident.name in
      if c = 0 then
        if Eliom_base.conform ~scope:s ~id:(side k.ident)
        then k
        else find_name_side s k.previous
      else
        find_side name s (if c < 0 then l else r)

let find_data name = find_side name (Eliom_base.get_side ())

let find_name name tbl = (find_data name tbl).data
let find_ident name tbl = (find_data name tbl).ident

let rec get_all s = function
  | None -> []
  | Some k -> cons_ident s k

and cons_ident s k =
  if Eliom_base.conform s (side k.ident)
  then k.data :: get_all s k.previous
  else get_all s k.previous


let rec find_all name = function
    Empty ->
      []
  | Node(l, k, r, _) ->
      let c = compare name k.ident.name in
      if c = 0 then
        cons_ident (Eliom_base.get_side ()) k
      else
        find_all name (if c < 0 then l else r)

let rec fold_aux f stack accu = function
    Empty ->
      begin match stack with
        [] -> accu
      | a :: l -> fold_aux f l accu a
      end
  | Node(l, k, r, _) ->
      fold_aux f (l :: stack) (f k accu) r

let fold_name f tbl accu = fold_aux (fun k -> f k.ident k.data) [] accu tbl

let rec fold_data f d accu =
  match d with
    None -> accu
  | Some k -> f k.ident k.data (fold_data f k.previous accu)

let fold_all f tbl accu =
  fold_aux (fun k -> fold_data f (Some k)) [] accu tbl

(* let keys tbl = fold_name (fun k _ accu -> k::accu) tbl [] *)

let rec iter f = function
    Empty -> ()
  | Node(l, k, r, _) ->
      iter f l; f k.ident k.data; iter f r

(* Idents for sharing keys *)

(* They should be 'totally fresh' -> neg numbers *)
let key_name = ""

let make_key_generator () =
  let c = ref 1 in
  fun id ->
    let stamp = !c in
    decr c ;
    { id with name = key_name; stamp = stamp; }

let compare x y =
  let c = x.stamp - y.stamp in
  if c <> 0 then c
  else
    let c = compare x.name y.name in
    if c <> 0 then c
    else
      compare x.flags y.flags

let output oc id = output_string oc (unique_name id)
let hash i = (Char.code i.name.[0]) lxor i.stamp

let original_equal = equal
include Identifiable.Make (struct
  type nonrec t = t
  let compare = compare
  let output = output
  let print = print
  let hash = hash
  let equal = same
end)
let equal = original_equal
