(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                   Fabrice Le Fessant, INRIA Saclay                     *)
(*                                                                        *)
(*   Copyright 2012 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type pers_flags =
  | Rectypes
  | Deprecated of string
  | Opaque
  (* ELIOM *)
  | Side of Eliom_base.side

type error =
    Not_an_interface of string
  | Wrong_version_interface of string * string
  | Corrupted_interface of string

exception Error of error

type cmi_infos = {
    cmi_name : string;
    cmi_sign : Types.signature_item list;
    cmi_crcs : (string * Digest.t option) list;
    cmi_flags : pers_flags list;
}

let input_cmi ic =
  let (name, sign) = input_value ic in
  let crcs = input_value ic in
  let flags = input_value ic in
  {
      cmi_name = name;
      cmi_sign = sign;
      cmi_crcs = crcs;
      cmi_flags = flags;
    }

let read_cmi filename =
  let ic = open_in_bin filename in
  try
    let buffer =
      really_input_string ic (String.length Config.cmi_magic_number)
    in
    if buffer <> Config.cmi_magic_number
    && buffer <> Eliom_types.cmi_magic_number (* ELIOM *)
    then begin
      close_in ic;
      let pre_len = String.length Config.cmi_magic_number - 3 in
      if String.sub buffer 0 pre_len
          = String.sub Config.cmi_magic_number 0 pre_len then
      begin
        let msg =
          if buffer < Config.cmi_magic_number then "an older" else "a newer" in
        raise (Error (Wrong_version_interface (filename, msg)))
      end else begin
        raise(Error(Not_an_interface filename))
      end
    end;
    let cmi = input_cmi ic in
    close_in ic;
    (* ELIOM *)
    let rec get_side = function
      | Side s :: t -> t, (s :> Eliom_base.shside)
      | h::t -> let t, s = get_side t in (h::t), s
      | [] -> [], `Noside
    in
    let cmi, side =
      if buffer = Eliom_types.cmi_magic_number then
        let cmi_flags, side = get_side cmi.cmi_flags in
        {cmi with cmi_flags}, side
      else
        cmi, Eliom_base.get_side ()
    in
    (* We don't change sides inside the module if
       - The module already has sides (ie. is an eliom cmi)
       - The current side is Noside
    *)
    if buffer = Eliom_types.cmi_magic_number
    || Eliom_base.get_side () = `Noside
    then ()
    else Eliom_types.translate cmi.cmi_sign ;
    (* /ELIOM *)
    cmi
    , side (* ELIOM *)
  with End_of_file | Failure _ ->
      close_in ic;
      raise(Error(Corrupted_interface(filename)))
    | Error e ->
      close_in ic;
      raise (Error e)

let output_cmi filename oc cmi =
(* beware: the provided signature must have been substituted for saving *)
  (* ELIOM *)
  let cmi_magic_number =
    if Eliom_types.is_mixed cmi.cmi_sign
    then Eliom_types.cmi_magic_number
    else
      Config.cmi_magic_number
  in
  let cmi =
    match Eliom_base.get_side () with
    | `Noside -> cmi
    | (`Client | `Server | `Shared) as side ->
        {cmi with cmi_flags = Side side :: cmi.cmi_flags}
  in
  (* /ELIOM *)
  output_string oc cmi_magic_number;
  output_value oc (cmi.cmi_name, cmi.cmi_sign);
  flush oc;
  let crc = Digest.file filename in
  let crcs = (cmi.cmi_name, Some crc) :: cmi.cmi_crcs in
  output_value oc crcs;
  output_value oc cmi.cmi_flags;
  crc

(* Error report *)

open Format

let report_error ppf = function
  | Not_an_interface filename ->
      fprintf ppf "%a@ is not a compiled interface"
        Location.print_filename filename
  | Wrong_version_interface (filename, older_newer) ->
      fprintf ppf
        "%a@ is not a compiled interface for this version of OCaml.@.\
         It seems to be for %s version of OCaml."
        Location.print_filename filename older_newer
  | Corrupted_interface filename ->
      fprintf ppf "Corrupted compiled interface@ %a"
        Location.print_filename filename

let () =
  Location.register_error_of_exn
    (function
      | Error err -> Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )
