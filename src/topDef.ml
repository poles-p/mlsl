(* File: topDef.ml *)

module StrMap = Map.Make(String)

let topdef_map = ref StrMap.empty

let add name types def =
	if StrMap.mem name !topdef_map then
		let (_, prev) = StrMap.find name !topdef_map in
		Errors.error_p def.MlslAst.td_pos
			(Printf.sprintf "Redefinition of %s. Previous definition at %s."
				name (Errors.string_of_pos prev.MlslAst.td_pos)
			);
	else
		topdef_map := StrMap.add name (types, def) !topdef_map
