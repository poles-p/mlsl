(* File: midlang.ml *)

module StrMap = Map.Make(String)

type typ =
| TFloat
| TInt
| TMat44
| TVec2
| TVec3
| TVec4

type variable =
	{ var_id   : int
	; var_typ  : typ
	}

type semantics =
| SPosition

type attr =
	{ attr_semantics : semantics
	; attr_name      : string
	; attr_var       : variable
	}

type param =
	{ param_name : string
	; param_var  : variable
	}

type instr =
| IMov     of variable * variable
| IMulFF   of variable * variable * variable
| IMulMV44 of variable * variable * variable
| IRet     of variable

type shader =
	{ sh_name     : string
	; sh_attr     : attr list
	; sh_v_const  : param list
	; sh_f_const  : param list
	; sh_varying  : param list
	; sh_vertex   : instr list
	; sh_fragment : instr list
	}

let string_of_typ tp =
	match tp with
	| TFloat -> "float"
	| TInt   -> "int"
	| TMat44 -> "mat44"
	| TVec2  -> "vec2"
	| TVec3  -> "vec3"
	| TVec4  -> "vec4"

(* ========================================================================= *)

let fresh_id = ref 0
let fresh () =
	let id = !fresh_id in
	fresh_id := id + 1;
	id

let create_var_ast ast_typ =
	{ var_id = fresh ()
	; var_typ =
		match ast_typ with
		| MlslAst.TFloat -> TFloat
		| MlslAst.TInt   -> TInt
		| MlslAst.TMat44 -> TMat44
		| MlslAst.TVec2  -> TVec2
		| MlslAst.TVec3  -> TVec3
		| MlslAst.TVec4  -> TVec4
		| MlslAst.TBool | MlslAst.TUnit | MlslAst.TArrow _ | MlslAst.TPair _
		| MlslAst.TRecord _ | MlslAst.TVertex _ | MlslAst.TFragment _
		| MlslAst.TVertexTop -> raise Misc.InternalError
	}

let create_variable typ =
	{ var_id  = fresh ()
	; var_typ = typ
	}

(* ========================================================================= *)

type value =
	{ v_pos  : Lexing.position
	; v_kind : value_kind
	}
and value_kind =
| VPair     of value * value
| VVertex   of value StrMap.t * MlslAst.expr
| VFragment of value StrMap.t * MlslAst.expr

let credits = ref 1024
let globals = Hashtbl.create 32

let rec eval_expr gamma expr =
	match expr.MlslAst.e_kind with
	| MlslAst.EVar x ->
		begin try
			Some (StrMap.find x gamma)
		with
		| Not_found ->
			eval_global gamma expr.MlslAst.e_pos x
		end
	| MlslAst.EVarying x ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: eval_expr EVarying.";
		None
	| MlslAst.EInt n ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: eval_expr EInt.";
		None
	| MlslAst.ERecord rd ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: eval_expr ERecord.";
		None
	| MlslAst.EPair(e1, e2) ->
		Misc.Opt.bind  (eval_expr gamma e1) (fun v1 ->
		Misc.Opt.map_f (eval_expr gamma e2) (fun v2 ->
			{ v_pos = expr.MlslAst.e_pos; v_kind = VPair(v1, v2) }
		))
	| _ ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: eval_expr.";
		None
and eval_global gamma pos x =
	if Hashtbl.mem globals x then
		Some (Hashtbl.find globals x)
	else match TopDef.check_name x with
	| None ->
		Errors.fatal_error "Internal error!!!"; None
	| Some (_, td) ->
		let result = 
			match td.MlslAst.td_kind with
			| MlslAst.TDAttrDecl _ ->
				Errors.error "Unimplemented: eval_global TDAttrDecl.";
				None
			| MlslAst.TDConstDecl _ ->
				Errors.error "Unimplemented: eval_global TDConstDecl.";
				None
			| MlslAst.TDFragmentShader(_, body) ->
				Some { v_pos = pos; v_kind = VFragment(gamma, body) }
			| MlslAst.TDVertexShader(_, body) ->
				Some { v_pos = pos; v_kind = VVertex(gamma, body) }
			| _ ->
				Errors.error "Unimplemented: eval_global.";
				None
		in begin match result with
		| None -> None
		| Some r ->
			Hashtbl.add globals x r;
			Some r
		end

(* ========================================================================= *)

let attr_map    = Hashtbl.create 32
let v_const_map = Hashtbl.create 32
let f_const_map = Hashtbl.create 32
let varying_map = Hashtbl.create 32

let create_attr_list () =
	Misc.ListExt.map_filter (fun (name, semantics, _) ->
		if Hashtbl.mem attr_map name then
			Some
				{ attr_name      = name
				; attr_semantics =
					begin match semantics.MlslAst.asem_name with
					| "POSITION" -> SPosition
					| _ -> SPosition
					end
				; attr_var       = Hashtbl.find attr_map name
				}
		else None) (TopDef.attr_list ())

let create_v_const_list () =
	Misc.ListExt.map_filter (fun (name, _) ->
		if Hashtbl.mem v_const_map name then
			Some
				{ param_name = name
				; param_var  = Hashtbl.find v_const_map name
				}
		else None) (TopDef.const_list ())

let create_f_const_list () =
	Misc.ListExt.map_filter (fun (name, _) ->
		if Hashtbl.mem f_const_map name then
			Some
				{ param_name = name
				; param_var  = Hashtbl.find f_const_map name
				}
		else None) (TopDef.const_list ())

let create_varying_list () =
	Hashtbl.fold (fun name var l ->
		{ param_name = name
		; param_var  = var
		} :: l) varying_map []

(* ========================================================================= *)

type reg_value =
	{ rv_pos  : Lexing.position
	; rv_kind : reg_value_kind
	}
and reg_value_kind =
| RVReg    of variable
| RVRecord of reg_value StrMap.t

let rec unfold_code vertex code gamma expr =
	match expr.MlslAst.e_kind with
	| MlslAst.EVar x ->
		if StrMap.mem x gamma then begin 
			Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_code EVar gamma(x).";
			None
		end else begin match TopDef.check_name x with
		| None ->
			Errors.error_p expr.MlslAst.e_pos "Internal error!!!"; None
		| Some(_, td) ->
			begin match td.MlslAst.td_kind with
			| MlslAst.TDAttrDecl(name, _, typ) ->
				if vertex then
					Some (
						{ rv_pos  = td.MlslAst.td_pos
						; rv_kind = RVReg (
							try
								Hashtbl.find attr_map name
							with
							| Not_found ->
								let v = create_var_ast typ.MlslAst.tt_typ in
								Hashtbl.add attr_map name v;
								v
							)
						}, code)
				else begin
					Errors.error_p expr.MlslAst.e_pos "Attributes are not available for fragment shaders.";
					None
				end
			| MlslAst.TDConstDecl(name, typ) ->
				let const_map = if vertex then v_const_map else f_const_map in
				Some (
					{ rv_pos  = td.MlslAst.td_pos
					; rv_kind = RVReg (
						try
							Hashtbl.find const_map name
						with
						| Not_found ->
							let v = create_var_ast typ.MlslAst.tt_typ in
							Hashtbl.add const_map name v;
							v
						)
					}, code)
			| _ ->
				Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_code EVar global.";
				None
			end
		end
	| MlslAst.EVarying x ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_code EVarying.";
		None
	| MlslAst.EInt n ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_code EInt.";
		None
	| MlslAst.ERecord rd ->
		Misc.Opt.map_f (Misc.ListExt.opt_fold_left (fun field (regMap, code) ->
			Misc.Opt.map_f (unfold_code vertex code gamma field.MlslAst.rfv_value) 
			(fun (rv, code') ->
				(StrMap.add field.MlslAst.rfv_name rv regMap, code')
			)) (Some(StrMap.empty, code)) rd) (fun (rd', code') -> 
				( { rv_pos = expr.MlslAst.e_pos; rv_kind = RVRecord rd' }, code'))
	| MlslAst.EPair(e1, e2) ->
		Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_code EPair.";
		None
	| MlslAst.EMul(e1, e2) ->
		Misc.Opt.bind (unfold_code vertex code gamma e1) (fun (rv1, code) ->
		Misc.Opt.bind (unfold_code vertex code gamma e2) (fun (rv2, code) ->
			match rv1.rv_kind, rv2.rv_kind with
			| RVReg r1, RVReg r2 ->
				Misc.Opt.map_f (
					match r1.var_typ, r2.var_typ with
					| TFloat, TFloat -> Some (TFloat, fun r1 r2 r3 -> IMulFF(r1, r2, r3))
					| TMat44, TVec4  -> Some (TVec4,  fun r1 r2 r3 -> IMulMV44(r1, r2, r3))
					| t1, t2 ->
						Errors.error_p expr.MlslAst.e_pos
							(Printf.sprintf "Multiplication for types %s * %s is not defined."
								(string_of_typ t1) (string_of_typ t2));
						None
					) (fun (rtp, cons) ->
						let rreg = create_variable rtp in
						Misc.ImpList.add code (cons rreg r1 r2);
						( { rv_pos = expr.MlslAst.e_pos; rv_kind = RVReg rreg }, code )
					)
			| RVRecord _, _ ->
				Errors.error_p expr.MlslAst.e_pos 
					(Printf.sprintf "First operand defined at %s is a record, can not be multiplied."
						(Errors.string_of_pos rv1.rv_pos));
				None
			| _, RVRecord _ ->
				Errors.error_p expr.MlslAst.e_pos 
					(Printf.sprintf "Second operand defined at %s is a record, can not be multiplied."
						(Errors.string_of_pos rv2.rv_pos));
				None
		))

let unfold_vertex code gamma expr =
	Misc.Opt.bind (unfold_code true code gamma expr) (fun (reg_val, code') ->
	match reg_val.rv_kind with
	| RVRecord rd ->
		if not (StrMap.mem "position" rd) then begin
			Errors.error_p expr.MlslAst.e_pos 
				(Printf.sprintf "This record defined at %s has not \"position\" field."
					(Errors.string_of_pos reg_val.rv_pos));
			None
		end else begin
			let ok = StrMap.fold (fun v_name v_rv st ->
				if v_name = "position" then st
				else match v_rv.rv_kind with
				| RVReg vr ->
					Hashtbl.add varying_map v_name vr; st
				| _ ->
					Errors.error_p expr.MlslAst.e_pos 
						(Printf.sprintf "Field %s defined at %s is not a primitive value."
							v_name (Errors.string_of_pos v_rv.rv_pos));
					false
				) rd true in
			match (StrMap.find "position" rd).rv_kind with
			| RVReg rr ->
				begin match rr.var_typ with
				| TVec4 ->
					Misc.ImpList.add code (IRet rr);
					if ok then Some code
					else None
				| tp ->
					Errors.error_p expr.MlslAst.e_pos (Printf.sprintf 
						"Result position of vertex shader defined at %s has type %s, but expected vec4."
						(Errors.string_of_pos (StrMap.find "position" rd).rv_pos)
						(string_of_typ tp)
					); None
				end
			| _ ->
				Errors.error_p expr.MlslAst.e_pos (Printf.sprintf
					"Result position of vertex shader defined at %s is not a primitive value."
						(Errors.string_of_pos (StrMap.find "position" rd).rv_pos)
				); None
		end
	| _ ->
		Errors.error_p expr.MlslAst.e_pos "Non record result of vertex shader.";
		None
	)

let unfold_fragment code gamma expr =
	Errors.error_p expr.MlslAst.e_pos "Unimplemented: unfold_fragment.";
	None

let unfold_shader name expr =
	credits := 1024;
	Misc.Opt.bind (eval_expr StrMap.empty expr) (fun value ->
		match value.v_kind with
		| VPair(vs, fs) ->
			begin match vs.v_kind, fs.v_kind with
			| VVertex(vs_gamma, vs_code), VFragment(fs_gamma, fs_code) ->
				Hashtbl.clear attr_map;
				Hashtbl.clear v_const_map;
				Hashtbl.clear f_const_map;
				Hashtbl.clear varying_map;
				Misc.Opt.bind (unfold_vertex (Misc.ImpList.create ()) vs_gamma vs_code) (fun vertex ->
				Misc.Opt.bind (unfold_fragment (Misc.ImpList.create ()) fs_gamma fs_code) (fun fragment ->
					Some
						{ sh_name     = name
						; sh_attr     = create_attr_list ()
						; sh_v_const  = create_v_const_list ()
						; sh_f_const  = create_f_const_list ()
						; sh_varying  = create_varying_list ()
						; sh_vertex   = Misc.ImpList.to_list vertex
						; sh_fragment = Misc.ImpList.to_list fragment
						} ))
			| VVertex _, _ ->
				Errors.error_p fs.v_pos "This expression is not a fragment shader.";
				None
			| _, _ ->
				Errors.error_p vs.v_pos "This expression is not a vertex shader.";
				None
			end
		| _ ->
			Errors.error_p value.v_pos "Shader must be a pair of vertex and fragment shaders.";
			None
	)

(* TODO: better optimizer *)
let optimize s = s
