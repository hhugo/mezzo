(*****************************************************************************)
(*  ChaML, a type-checker that uses constraints and a kernel language        *)
(*  Copyright (C) 2010 Jonathan Protzenko                                    *)
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


let debug_level = ref 0
let enable_debug level = debug_level := level

let debug ?level fmt =
  (* If no level is provided, the message is always displayed. *)
  let level = Option.map_none 1 level in
  if level <= !debug_level then begin
    Hml_String.bfprintf ~new_line:() stderr fmt
  end else begin
    Hml_String.biprintf fmt
  end

let warn x = debug ~level:0 x

let error fmt =
  Printf.kbprintf (fun buf ->
    Buffer.add_char buf '\n';
    Buffer.output_buffer stderr buf;
    raise (Failure (Buffer.contents buf))
  ) (Buffer.create 16) fmt

let check b fmt =
  let open Printf in
  if b then
    ifprintf stderr fmt
  else begin
    output_string stderr Bash.colors.Bash.red;
    kfprintf (fun oc -> output_string oc (Bash.colors.Bash.default ^ "\n"); assert false) stderr fmt
  end
