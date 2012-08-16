
let check_types = ref false

let sources = Misc.ImpList.create ()

let add_target target =
	match target with
	| "agal"    -> Eval.set_target_func Agal.do_all
	| "agalAsm" -> Eval.set_target_func Agal.do_all_asm
	| "dummy"   -> Eval.set_target_func (fun _ -> ())
	| _         -> ()

let add_source source =
	Misc.ImpList.add sources source

let cmd_args_options =
	[ "-T",          Arg.Set check_types, 
		"  Enable typechecking"
	; "--typecheck", Arg.Bool (fun b -> check_types := b), 
		"  Enable/disable typechecking"
	; "-t",          Arg.Symbol(["agal"; "agalAsm"; "dummy"], add_target),
		"  Same as --target"
	; "--target",    Arg.Symbol(["agal"; "agalAsm"; "dummy"], add_target),
		"  Target architecture"
	]

let _ =
	Builtin.init();
	Arg.parse cmd_args_options add_source "Usage: mlsl [OPTION]... [FILE]..."

let _ =
	if Misc.ImpList.is_empty sources then
		print_endline "No input files. For more information, try '--help' option."
	else begin
		Misc.ImpList.iter (fun file ->
			begin try match Parser.parse file with
			| Some td_list ->
				if !check_types then
					TypeCheck.check td_list
				else
					TypeCheck.fast_check td_list;
				if Errors.ok () then
					Eval.eval_all td_list
				else ()
			| None -> ()
			with
			| Parsing.Parse_error -> ()
			end;
		) sources;
		Final.perform_actions ();
		Errors.print_status ()
	end
