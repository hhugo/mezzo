(*****************************************************************************)
(*  Mezzo, a programming language based on permissions                       *)
(*  Copyright (C) 2011, 2012 Jonathan Protzenko and François Pottier         *)
(*                                                                           *)
(*  This program is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU General Public License as published by     *)
(*  the Free Software Foundation, either version 3 of the License, or        *)
(*  (at your option) any later version.                                      *)
(*                                                                           *)
(*  This program is distributed in the hope that it will be useful,          *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(*  GNU General Public License for more details.                             *)
(*                                                                           *)
(*  You should have received a copy of the GNU General Public License        *)
(*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*                                                                           *)
(*****************************************************************************)

let output_string (s: string): unit =
  let s = Js.string s |> Js.Unsafe.inject in
  let mezzo_ui = Js.Unsafe.variable "mezzo_ui" in
  let log = Js.Unsafe.get mezzo_ui "log" in
  Js.Unsafe.fun_call log [| s |]
;;

let get_file (f: string): string =
  let f = Js.string f |> Js.Unsafe.inject in
  let mezzo_fs = Js.Unsafe.variable "mezzo_fs" in
  let get = Js.Unsafe.get mezzo_fs "get" in
  Js.Unsafe.fun_call get [| f |] |>
  Js.to_string
;;

let highlight_range (l1: Lexing.position) (l2: Lexing.position): unit =
  let open Lexing in
  let row1 = l1.pos_lnum - 1 in
  let col1 = l1.pos_cnum - l1.pos_bol in
  let row2 = l2.pos_lnum - 1 in
  let col2 = l2.pos_cnum - l2.pos_bol in
  let mezzo_ui = Js.Unsafe.variable "mezzo_ui" in
  let hl = Js.Unsafe.get mezzo_ui "highlight_range" in
  Js.Unsafe.fun_call hl (Array.map Js.Unsafe.inject [| row1; col1; row2; col2 |])
;;

let process
    (f: string)
    (type_check: bool)
    (interpret: bool)
    (debug_level: int)
    (warn_error: string) =
  (* Reset to the default value and then parse the user-provided one. *)
  TypeErrors.parse_warn_error !Options.warn_error;
  TypeErrors.parse_warn_error warn_error;

  (* Debug level. *)
  Log.enable_debug debug_level;

  let opts =
    { Driver.html_errors = false; backtraces = false }
  in
  if type_check then
    ignore (Driver.run opts (fun () -> Driver.process f));
  if interpret then
    Driver.run opts (fun () -> Driver.interpret f)
;;

let _ =
  let w = Js.Unsafe.coerce Dom_html.window in
  w ## mezzo <- Js.Unsafe.obj [|
    "process",
      Js.wrap_callback process |> Js.Unsafe.inject;
  |]
;;

let _ =
  Driver.add_include_dir "corelib";
  Driver.add_include_dir "stdlib";
  Driver.add_include_dir ".";
  Options.js := true;
  JsGlue.output_string_ := output_string;
  JsGlue.get_file_ := get_file;
  JsGlue.highlight_range_ := highlight_range;
;;

