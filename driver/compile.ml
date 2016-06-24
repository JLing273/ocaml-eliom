(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 2002 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Libcompile

let tool_name = "ocamlc"

let c_file = Libcompile.c_file
let interface = Libcompile.interface ~tool_name

(** Compile a .ml file to bytecode *)

let to_bytecode i (typedtree, coercion) =
  (typedtree, coercion)
  |> Timings.(time (Transl i.sourcefile))
    (Translmod.transl_implementation i.modulename)
  |> print_if i Clflags.dump_rawlambda Printlambda.lambda
  |> Timings.(accumulate_time (Generate i.sourcefile))
    (fun lambda ->
       Simplif.simplify_lambda lambda
       |> print_if i Clflags.dump_lambda Printlambda.lambda
       |> Bytegen.compile_implementation i.modulename
       |> print_if i Clflags.dump_instr Printinstr.instrlist)

let emit_bytecode i bytecode =
  let objfile = i.outputprefix ^ ".cmo" in
  let oc = open_out_bin objfile in
  try
    bytecode
    |> Timings.(accumulate_time (Generate i.sourcefile))
      (Emitcode.to_file oc i.modulename objfile);
    Warnings.check_fatal ();
    close_out oc;
    Stypes.dump (Some (i.outputprefix ^ ".annot"))
  with x ->
    close_out oc;
    Misc.remove_file objfile;
    raise x

let frontend info = typecheck_impl info @@ parse_impl info
let backend info typed = emit_bytecode info @@ to_bytecode info typed

let implementation ppf sourcefile outputprefix =
  let info = init ppf ~init_path:false ~tool_name ~sourcefile ~outputprefix in

  wrap_compilation ~frontend ~backend info

(* ELIOM *)
let eliom_implementation ppf sourcefile outputprefix =
  let info = init ppf ~init_path:false ~tool_name ~sourcefile ~outputprefix in
  let comp_side s ast =
    Envaux.reset_cache () ;
    let client_info = eliom_init s
        ppf ~init_path:false ~tool_name ~sourcefile ~outputprefix
    in
    backend client_info @@ silent_typing client_info ast ;
  in
  try
    let {Eliom_emit. client ; server } = eliom_pretype info in
    if not !Clflags.print_types then begin
      comp_side "server" server ;
      comp_side "client" client ;
    end else begin
      Warnings.check_fatal ();
      Stypes.dump (Some (info.outputprefix ^ ".annot"));
    end
  with x ->
    Stypes.dump (Some (info.outputprefix ^ ".annot"));
    Misc.remove_file (obj info);
    Misc.remove_file (cmx info);
    raise x
(* /ELIOM *)
