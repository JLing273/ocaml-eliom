[@@@ocaml.warning "+a-4-9-40-42"]
open Parsetree

type side = [
  | `Client
  | `Server
  | `Shared
]

type shside = [
  | side
  | `Noside
]

let to_string = function
  | `Server -> "server"
  | `Client -> "client"
  | `Shared -> "shared"
  | `Noside -> "base"
let pp ppf x = Format.pp_print_string ppf (to_string x)

(** Check if identifier from side [id] can be used in scope [scope]. *)
let conform ~(scope:shside) ~(id:shside) = match scope, id with
  | `Server, `Server
  | `Client, `Client
  | (`Server | `Client | `Shared), `Shared
  | _, `Noside
    -> true
  | `Client, `Server
  | `Server, `Client
  | `Shared, (`Server | `Client)
  | `Noside, _
    -> false

let mirror = function
  | `Client -> `Server
  | `Server -> `Client
  | `Shared -> `Shared
  | `Noside -> `Noside

(** Handling of current side *)

let side : shside ref = ref `Noside
let get_side () = (!side : shside :> [>shside])
let change_side = function
  | "server" -> side := `Server
  | "client" -> side := `Client
  | "shared" -> side := `Shared
  | _ -> ()


(** In order to report exceptions with the proper scope, we wrap exceptions
    that cross side boundaries with a side annotation.

    The handling mechanism in {!Location} unwraps the exception transparently.
*)
exception Error of (shside * exn)

let in_side new_side body =
   let old_side = !side in
   side := (new_side : [<shside] :> shside ) ;
   try
    let r = body () in
    side := old_side; r
   with e ->
     let e' : exn = Error (!side, e) in
     side := old_side;
     raise e'

let () =
  let handler : exn -> _  = function
    | Error (side, exn) ->
        in_side side (fun () -> Location.error_of_exn exn)
    | _ -> None
  in Location.register_error_of_exn handler



let check ~loc mk_error side message =
  let current_side = get_side () in
  if not @@ conform ~scope:current_side ~id:side then
    raise @@ mk_error @@
    Location.errorf ~loc
      "%s are only allowed in a %s context, \
       but it is used in a %s context."
      message
      (to_string side)
      (to_string current_side)
  else ()

(** Load path utilities *)

let client_load_path = ref []
let server_load_path = ref []

let set_load_path ~client ~server =
  client_load_path := List.rev client ;
  server_load_path := List.rev server ;
  ()

let find_in_load_path file =
  let side = get_side () in
  try
    Misc.find_in_path_uncap !Config.load_path file, `Noside
  with Not_found as exn ->
    let l = match side with
      | `Server -> !server_load_path
      | `Client -> !client_load_path
      | _ -> raise exn
    in Misc.find_in_path_uncap l file, side

(** Utils *)

let exp_add_attr ~attrs e =
  {e with pexp_attributes = attrs @ e.pexp_attributes}

let is_annotation ~txt base =
  txt = base || txt = ("eliom."^base)

let error ~loc fmt =
  Location.raise_errorf ~loc ("Eliom: "^^fmt)

let is_authorized loc =
  match get_side () with
  | `Noside -> error ~loc
        "Side annotations are not authorized out of eliom files."
  | `Shared | `Server | `Client -> ()

(** Parsetree inspection and emission. *)

module Fragment = struct

  let name = "client"
  let attr loc = ({Location.txt=name; loc},PStr [])

  let check e =
    match e.pexp_desc with
    | Pexp_extension ({txt},payload) when is_annotation ~txt name ->
        begin match payload with
        | PStr [{pstr_desc = Pstr_eval (_e,_attrs)}] ->
            is_authorized e.pexp_loc ; true
        | _ -> error ~loc:e.pexp_loc "Wrong payload for client fragment"
        end
    | _ -> false

  let get e =
    is_authorized e.pexp_loc ;
    match e.pexp_desc with
    | Pexp_extension ({txt},PStr [{pstr_desc = Pstr_eval (e,attrs)}])
      when txt = name -> exp_add_attr ~attrs e
    | _ -> error ~loc:e.pexp_loc "A client fragment was expected"

end


module Injection = struct

  let op = "~%"

  let check e =
    match e.pexp_desc with
    | Pexp_apply ({pexp_desc = Pexp_ident {txt}}, args)
      when txt = Longident.Lident op ->
        begin match args with
        | [Nolabel, _] ->
            is_authorized e.pexp_loc ; true
        | _ -> error ~loc:e.pexp_loc "Wrong payload for an injection"
        end
    | _ -> false

  let get e =
    is_authorized e.pexp_loc ;
    match e.pexp_desc with
    | Pexp_apply ({pexp_desc=Pexp_ident {txt}}, [Nolabel, e])
      when txt = Longident.Lident op -> e
    | _ -> error ~loc:e.pexp_loc "An injection was expected"


  let name = "injection"
  let attr loc = ({Location.txt=name; loc},PStr [])

end

module Section = struct

  let client = "client"
  let server = "server"
  let shared = "shared"

  let check e =
    match e.pstr_desc with
    | Pstr_extension (({Location.txt},payload),_)
      when is_annotation ~txt client ||
           is_annotation ~txt server ||
           is_annotation ~txt shared ->
        begin match payload with
        | PStr [_str] ->
            is_authorized e.pstr_loc ; true
        | _ -> error ~loc:e.pstr_loc "Wrong payload for a section"
        end
    | _ -> false

  let get e =
    is_authorized e.pstr_loc ;
    match e.pstr_desc with
    | Pstr_extension (({Location.txt},PStr [str]),_)
      when is_annotation ~txt client -> (`Client, str)
    | Pstr_extension (({Location.txt},PStr [str]),_)
      when is_annotation ~txt server -> (`Server, str)
    | Pstr_extension (({Location.txt},PStr [str]),_)
      when is_annotation ~txt shared -> (`Shared, str)
    (* TODO : Drop attributes *)
    | _ -> error ~loc:e.pstr_loc "A section was expected"

  let split_internal l =
    let make ~loc ~attrs ext x =
      Ast_helper.Str.extension ~loc ~attrs (ext, PStr [x])
    in
    let aux l stri = match stri.pstr_desc with
      | Pstr_extension (({Location.txt} as ext, PStr str), attrs)
        when is_annotation ~txt client ||
             is_annotation ~txt server ||
             is_annotation ~txt shared ->
          let loc = stri.pstr_loc in
          let newl = List.map (make ~loc ~attrs ext) str in
          List.rev_append newl l
      | _ -> stri :: l
    in
    List.rev @@ List.fold_left aux [] l

  let split l =
    if List.exists check l then split_internal l
    else l

  let check_sig e =
    match e.psig_desc with
    | Psig_extension (({Location.txt},payload),_)
      when is_annotation ~txt client ||
           is_annotation ~txt server ||
           is_annotation ~txt shared ->
        begin match payload with
        | PSig _ ->
            is_authorized e.psig_loc ; true
        | _ -> error ~loc:e.psig_loc "Wrong payload for a section"
        end
    | _ -> false

  let get_sig e =
    is_authorized e.psig_loc ;
    match e.psig_desc with
    | Psig_extension (({Location.txt},PSig l),_)
      when is_annotation ~txt client -> (`Client, l)
    | Psig_extension (({Location.txt},PSig l),_)
      when is_annotation ~txt server -> (`Server, l)
    | Psig_extension (({Location.txt},PSig l),_)
      when is_annotation ~txt shared -> (`Shared, l)
    (* TODO : Drop attributes *)
    | _ -> error ~loc:e.psig_loc "A section was expected"

  let attr side loc =
    let txt = match side with
      | `Client -> client
      | `Server -> server
      | `Shared -> shared
    in ({Location.txt; loc},PStr [])

end
