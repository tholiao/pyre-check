(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
module ServiceTypeOrder = TypeOrder
open Analysis
open Ast
open Pyre
open EnvironmentSharedMemory
open PostprocessSharedMemory

let populate
    (module Handler : Environment.Handler)
    ~configuration:({ Configuration.Analysis.debug; _ } as configuration)
    ~scheduler
    sources
  =
  let resolution = Environment.resolution (module Handler) () in
  let populate () =
    List.iter sources ~f:(Environment.register_module (module Handler));
    sources
    |> List.map ~f:(fun { Ast.Source.qualifier; _ } -> qualifier)
    |> List.iter ~f:(Environment.register_implicit_submodules (module Handler));
    let all_annotations =
      List.fold
        ~init:Environment.built_in_annotations
        ~f:(fun annotations source ->
          Set.union annotations (Environment.register_class_definitions (module Handler) source))
        sources
      |> Set.to_list
    in
    Environment.register_aliases (module Handler) sources;
    List.iter ~f:(Environment.register_dependencies (module Handler)) sources;

    (* Build type order. *)
    List.iter ~f:(Environment.connect_type_order (module Handler) resolution) sources;
    ClassHierarchy.deduplicate (module Handler.TypeOrderHandler) ~annotations:all_annotations;
    if debug then
      (* Validate integrity of the type order built so far before moving forward. Further
         transformations might be incorrect or not terminate otherwise. *)
      ClassHierarchy.check_integrity (module Handler.TypeOrderHandler);
    ClassHierarchy.connect_annotations_to_object (module Handler.TypeOrderHandler) all_annotations;
    ClassHierarchy.remove_extra_edges_to_object (module Handler.TypeOrderHandler) all_annotations;
    List.iter all_annotations ~f:Handler.register_class_metadata;
    List.iter ~f:(Environment.propagate_nested_classes (module Handler)) sources
  in
  Handler.transaction ~f:populate ();
  let register_undecorated_functions sources =
    let register = Environment.register_undecorated_functions (module Handler) resolution in
    List.iter sources ~f:register
  in
  Scheduler.iter scheduler ~configuration ~f:register_undecorated_functions ~inputs:sources;
  let register_values sources =
    EnvironmentSharedMemory.GlobalKeys.LocalChanges.push_stack ();
    Environment.register_values (module Handler) resolution sources;
    EnvironmentSharedMemory.GlobalKeys.LocalChanges.commit_all ();
    EnvironmentSharedMemory.GlobalKeys.LocalChanges.pop_stack ()
  in
  Scheduler.iter
    scheduler
    ~configuration
    ~f:(fun sources -> List.iter sources ~f:register_values)
    ~inputs:sources;
  Handler.transaction
    ~f:(fun () -> List.iter ~f:(Plugin.apply_to_environment (module Handler) resolution) sources)
    ();

  (* Calls to `attribute` might populate this cache, ensure it's cleared. *)
  Annotated.Class.AttributeCache.clear ();
  GlobalResolution.Cache.clear ()


let build ((module Handler : Environment.Handler) as handler) ~configuration ~scheduler qualifiers =
  Log.info "Building type environment...";

  (* This grabs all sources from shared memory. It is unavoidable: Environment must be built
     sequentially until we find a way to build the environment in parallel. *)
  let timer = Timer.start () in
  let sources = List.filter_map qualifiers ~f:Ast.SharedMemory.Sources.get in
  populate ~configuration ~scheduler handler sources;
  Statistics.performance ~name:"full environment built" ~timer ();
  if Log.is_enabled `Dotty then (
    let type_order_file =
      Path.create_relative
        ~root:(Configuration.Analysis.pyre_root configuration)
        ~relative:"type_order.dot"
    in
    let (module Handler : Environment.Handler) = handler in
    Log.info "Emitting type order dotty file to %s" (Path.absolute type_order_file);
    File.create ~content:(ClassHierarchy.to_dot (module Handler.TypeOrderHandler)) type_order_file
    |> File.write )


module SharedHandler : Analysis.Environment.Handler = struct
  let transaction ~f () =
    Modules.LocalChanges.push_stack ();
    FunctionKeys.LocalChanges.push_stack ();
    ClassKeys.LocalChanges.push_stack ();
    AliasKeys.LocalChanges.push_stack ();
    GlobalKeys.LocalChanges.push_stack ();
    DependentKeys.LocalChanges.push_stack ();
    Dependents.LocalChanges.push_stack ();
    ClassDefinitions.LocalChanges.push_stack ();
    ClassMetadata.LocalChanges.push_stack ();
    Globals.LocalChanges.push_stack ();
    Aliases.LocalChanges.push_stack ();
    OrderEdges.LocalChanges.push_stack ();
    OrderBackedges.LocalChanges.push_stack ();
    OrderAnnotations.LocalChanges.push_stack ();
    OrderKeys.LocalChanges.push_stack ();
    OrderIndices.LocalChanges.push_stack ();
    let result = f () in
    Modules.LocalChanges.commit_all ();
    FunctionKeys.LocalChanges.commit_all ();
    ClassKeys.LocalChanges.commit_all ();
    AliasKeys.LocalChanges.commit_all ();
    GlobalKeys.LocalChanges.commit_all ();
    DependentKeys.LocalChanges.commit_all ();
    Dependents.LocalChanges.commit_all ();
    ClassDefinitions.LocalChanges.commit_all ();
    ClassMetadata.LocalChanges.commit_all ();
    Globals.LocalChanges.commit_all ();
    Aliases.LocalChanges.commit_all ();
    OrderEdges.LocalChanges.commit_all ();
    OrderBackedges.LocalChanges.commit_all ();
    OrderAnnotations.LocalChanges.commit_all ();
    OrderKeys.LocalChanges.commit_all ();
    OrderIndices.LocalChanges.commit_all ();
    Modules.LocalChanges.pop_stack ();
    FunctionKeys.LocalChanges.pop_stack ();
    ClassKeys.LocalChanges.pop_stack ();
    AliasKeys.LocalChanges.pop_stack ();
    GlobalKeys.LocalChanges.pop_stack ();
    DependentKeys.LocalChanges.pop_stack ();
    Dependents.LocalChanges.pop_stack ();
    ClassDefinitions.LocalChanges.pop_stack ();
    ClassMetadata.LocalChanges.pop_stack ();
    Globals.LocalChanges.pop_stack ();
    Aliases.LocalChanges.pop_stack ();
    OrderEdges.LocalChanges.pop_stack ();
    OrderBackedges.LocalChanges.pop_stack ();
    OrderAnnotations.LocalChanges.pop_stack ();
    OrderKeys.LocalChanges.pop_stack ();
    OrderIndices.LocalChanges.pop_stack ();
    result


  module DependencyHandler : Dependencies.Handler = struct
    let add_new_key ~get ~add ~qualifier ~key =
      let existing = get qualifier in
      match existing with
      | None -> add qualifier [key]
      | Some keys -> add qualifier (key :: keys)


    let add_function_key ~qualifier reference =
      add_new_key ~qualifier ~key:reference ~get:FunctionKeys.get ~add:FunctionKeys.add


    let add_class_key ~qualifier class_type =
      add_new_key ~qualifier ~key:class_type ~get:ClassKeys.get ~add:ClassKeys.add


    let add_alias_key ~qualifier alias =
      add_new_key ~qualifier ~key:alias ~get:AliasKeys.get ~add:AliasKeys.add


    let add_global_key ~qualifier global =
      add_new_key ~qualifier ~key:global ~get:GlobalKeys.get ~add:GlobalKeys.add


    let add_dependent_key ~qualifier dependent =
      add_new_key ~qualifier ~key:dependent ~get:DependentKeys.get ~add:DependentKeys.add


    let add_dependent ~qualifier dependent =
      add_dependent_key ~qualifier dependent;
      match Dependents.get dependent with
      | None -> Dependents.add dependent (Reference.Set.Tree.singleton qualifier)
      | Some dependencies ->
          Dependents.add dependent (Reference.Set.Tree.add dependencies qualifier)


    let get_function_keys ~qualifier = FunctionKeys.get qualifier |> Option.value ~default:[]

    let get_class_keys ~qualifier = ClassKeys.get qualifier |> Option.value ~default:[]

    let get_alias_keys ~qualifier = AliasKeys.get qualifier |> Option.value ~default:[]

    let get_global_keys ~qualifier = GlobalKeys.get qualifier |> Option.value ~default:[]

    let get_dependent_keys ~qualifier = DependentKeys.get qualifier |> Option.value ~default:[]

    let clear_keys_batch qualifiers =
      FunctionKeys.remove_batch (FunctionKeys.KeySet.of_list qualifiers);
      ClassKeys.remove_batch (ClassKeys.KeySet.of_list qualifiers);
      AliasKeys.remove_batch (AliasKeys.KeySet.of_list qualifiers);
      GlobalKeys.remove_batch (GlobalKeys.KeySet.of_list qualifiers);
      DependentKeys.remove_batch (DependentKeys.KeySet.of_list qualifiers)


    let dependents = Dependents.get

    let normalize qualifiers =
      let normalize_keys qualifier =
        ( match FunctionKeys.get qualifier with
        | Some keys ->
            FunctionKeys.remove_batch (FunctionKeys.KeySet.singleton qualifier);
            FunctionKeys.add qualifier (List.dedup_and_sort ~compare:Reference.compare keys)
        | None -> () );
        ( match ClassKeys.get qualifier with
        | Some keys ->
            ClassKeys.remove_batch (ClassKeys.KeySet.singleton qualifier);
            ClassKeys.add qualifier (List.dedup_and_sort ~compare:Identifier.compare keys)
        | None -> () );
        ( match AliasKeys.get qualifier with
        | Some keys ->
            AliasKeys.remove_batch (AliasKeys.KeySet.singleton qualifier);
            AliasKeys.add qualifier (List.dedup_and_sort ~compare:Identifier.compare keys)
        | None -> () );
        ( match GlobalKeys.get qualifier with
        | Some keys ->
            GlobalKeys.remove_batch (GlobalKeys.KeySet.singleton qualifier);
            GlobalKeys.add qualifier (List.dedup_and_sort ~compare:Reference.compare keys)
        | None -> () );
        match DependentKeys.get qualifier with
        | Some keys ->
            DependentKeys.remove_batch (DependentKeys.KeySet.singleton qualifier);
            DependentKeys.add qualifier (List.dedup_and_sort ~compare:Reference.compare keys)
        | None -> ()
      in
      List.iter qualifiers ~f:normalize_keys;
      let normalize_dependents name =
        match Dependents.get name with
        | Some unnormalized ->
            Dependents.remove_batch (Dependents.KeySet.singleton name);
            Reference.Set.Tree.to_list unnormalized
            |> List.sort ~compare:Reference.compare
            |> Reference.Set.Tree.of_list
            |> Dependents.add name
        | None -> ()
      in
      List.concat_map qualifiers ~f:(fun qualifier -> get_dependent_keys ~qualifier)
      |> List.dedup_and_sort ~compare:Reference.compare
      |> List.iter ~f:normalize_dependents
  end

  let class_definition annotation = ClassDefinitions.get annotation

  let class_metadata = ClassMetadata.get

  let register_module qualifier registered_module = Modules.add qualifier registered_module

  let register_implicit_submodule qualifier =
    match Modules.get qualifier with
    | Some _ -> ()
    | None -> (
      match ImplicitSubmodules.get qualifier with
      | None -> ImplicitSubmodules.add qualifier 1
      | Some count ->
          let count = count + 1 in
          ImplicitSubmodules.remove_batch (ImplicitSubmodules.KeySet.of_list [qualifier]);
          ImplicitSubmodules.add qualifier count )


  let register_undecorated_function ~reference ~annotation =
    UndecoratedFunctions.add reference annotation


  let is_module qualifier = Modules.mem qualifier || ImplicitSubmodules.mem qualifier

  let module_definition qualifier =
    match Modules.get qualifier with
    | Some _ as result -> result
    | None -> (
      match ImplicitSubmodules.get qualifier with
      | Some _ -> Some (Module.create_implicit ())
      | None -> None )


  let in_class_definition_keys annotation = ClassDefinitions.mem annotation

  let aliases = Aliases.get

  let globals = Globals.get

  let dependencies = Dependents.get

  let undecorated_signature = UndecoratedFunctions.get

  module TypeOrderHandler = ServiceTypeOrder.Handler

  let register_class_metadata class_name =
    let open Statement in
    let successors = ClassHierarchy.successors (module TypeOrderHandler) class_name in
    let is_final =
      ClassDefinitions.get class_name
      >>| (fun { Node.value = definition; _ } -> Class.is_final definition)
      |> Option.value ~default:false
    in
    let in_test =
      let is_unit_test { Node.value = definition; _ } = Class.is_unit_test definition in
      let successor_classes = List.filter_map ~f:ClassDefinitions.get successors in
      List.exists ~f:is_unit_test successor_classes
    in
    let extends_placeholder_stub_class =
      ClassDefinitions.get class_name
      >>| Annotated.Class.create
      >>| Annotated.Class.extends_placeholder_stub_class ~aliases ~module_definition
      |> Option.value ~default:false
    in
    ClassMetadata.add
      class_name
      { GlobalResolution.is_test = in_test; successors; is_final; extends_placeholder_stub_class }


  let register_dependency ~qualifier ~dependency =
    Log.log
      ~section:`Dependencies
      "Adding dependency from %a to %a"
      Reference.pp
      dependency
      Reference.pp
      qualifier;
    DependencyHandler.add_dependent ~qualifier dependency


  let register_global ?qualifier ~reference ~global =
    Option.iter qualifier ~f:(fun qualifier ->
        DependencyHandler.add_global_key ~qualifier reference);
    Globals.add reference global


  let set_class_definition ~name ~definition =
    let definition =
      match ClassDefinitions.get name with
      | Some { Node.location; value = preexisting } ->
          { Node.location;
            value = Statement.Class.update preexisting ~definition:(Node.value definition)
          }
      | _ -> definition
    in
    ClassDefinitions.add name definition


  let register_alias ~qualifier ~key ~data =
    DependencyHandler.add_alias_key ~qualifier key;
    Aliases.add key data


  let purge ?(debug = false) (qualifiers : Reference.t list) =
    let purge_dependents keys =
      let new_dependents = Reference.Table.create () in
      let recompute_dependents key dependents =
        let qualifiers = Reference.Set.Tree.of_list qualifiers in
        Hashtbl.set new_dependents ~key ~data:(Reference.Set.Tree.diff dependents qualifiers)
      in
      List.iter ~f:(fun key -> Dependents.get key >>| recompute_dependents key |> ignore) keys;
      Dependents.remove_batch (Dependents.KeySet.of_list (Hashtbl.keys new_dependents));
      Hashtbl.iteri new_dependents ~f:(fun ~key ~data -> Dependents.add key data);
      DependentKeys.remove_batch (Dependents.KeySet.of_list qualifiers)
    in
    List.concat_map ~f:(fun qualifier -> DependencyHandler.get_function_keys ~qualifier) qualifiers
    |> fun keys ->
    (* We add a global name for each function definition as well. *)
    Globals.remove_batch (Globals.KeySet.of_list keys);

    (* Remove the connection to the parent (if any) for all classes defined in the updated handles. *)
    List.concat_map ~f:(fun qualifier -> DependencyHandler.get_class_keys ~qualifier) qualifiers
    |> ClassHierarchy.disconnect_successors (module TypeOrderHandler);
    let class_keys =
      List.concat_map ~f:(fun qualifier -> DependencyHandler.get_class_keys ~qualifier) qualifiers
      |> ClassDefinitions.KeySet.of_list
    in
    ClassDefinitions.remove_batch class_keys;
    ClassMetadata.remove_batch class_keys;
    List.concat_map ~f:(fun qualifier -> DependencyHandler.get_alias_keys ~qualifier) qualifiers
    |> fun keys ->
    Aliases.remove_batch (Aliases.KeySet.of_list keys);
    let global_keys =
      List.concat_map ~f:(fun qualifier -> DependencyHandler.get_global_keys ~qualifier) qualifiers
      |> Globals.KeySet.of_list
    in
    Globals.remove_batch global_keys;
    UndecoratedFunctions.remove_batch global_keys;
    List.concat_map
      ~f:(fun qualifier -> DependencyHandler.get_dependent_keys ~qualifier)
      qualifiers
    |> List.dedup_and_sort ~compare:Reference.compare
    |> purge_dependents;
    DependencyHandler.clear_keys_batch qualifiers;
    Modules.remove_batch (Modules.KeySet.of_list qualifiers);
    if debug then (* If in debug mode, make sure the ClassHierarchy is still consistent. *)
      ClassHierarchy.check_integrity (module TypeOrderHandler)


  let local_mode = ErrorModes.get
end

(** First dumps environment to shared memory, then exposes through Environment_handler *)
let populate_shared_memory
    ~configuration:({ Configuration.Analysis.debug; _ } as configuration)
    ~scheduler
    qualifiers
  =
  Log.info "Adding built-in environment information to shared memory...";
  let timer = Timer.start () in
  let add_table f = Hashtbl.iteri ~f:(fun ~key ~data -> f key data) in
  let add_type_order { ClassHierarchy.edges; backedges; indices; annotations } =
    (* Writing through the caches because we are doing a batch-add. Especially while still adding
       amounts of data that exceed the cache size, the time spent doing cache bookkeeping is
       wasted. *)
    add_table OrderEdges.write_through edges;
    add_table
      OrderBackedges.write_through
      (Hashtbl.map ~f:ClassHierarchy.Target.Set.to_tree backedges);
    add_table OrderIndices.write_through indices;
    add_table OrderAnnotations.write_through annotations;
    OrderKeys.write_through SharedMemory.SingletonKey.key (Hashtbl.keys annotations)
  in
  add_type_order (ClassHierarchy.Builder.default ());
  Statistics.performance ~name:"added environment to shared memory" ~timer ();
  Environment.add_special_classes (module SharedHandler);
  Environment.add_dummy_modules (module SharedHandler);
  Environment.add_special_globals (module SharedHandler);
  build (module SharedHandler) ~configuration ~scheduler qualifiers;
  if debug then
    ClassHierarchy.check_integrity (module SharedHandler.TypeOrderHandler);
  Statistics.event
    ~section:`Memory
    ~name:"shared memory size"
    ~integers:["size", Ast.SharedMemory.heap_size ()]
    ()


let normalize_shared_memory qualifiers =
  (* Since we don't provide an API to the raw order keys in the type order handler, handle it
     inline here. *)
  ( match OrderKeys.get SharedMemory.SingletonKey.key with
  | None -> ()
  | Some keys ->
      OrderKeys.remove_batch (OrderKeys.KeySet.singleton SharedMemory.SingletonKey.key);
      List.sort ~compare:Int.compare keys |> OrderKeys.add SharedMemory.SingletonKey.key );
  SharedHandler.DependencyHandler.normalize qualifiers
