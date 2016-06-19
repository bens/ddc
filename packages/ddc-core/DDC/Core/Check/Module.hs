
module DDC.Core.Check.Module
        ( checkModule
        , checkModuleM)
where
import DDC.Core.Check.Base      (checkTypeM, applySolved)
import DDC.Core.Check.Exp
import DDC.Core.Check.Error
import DDC.Core.Transform.Reannotate
import DDC.Core.Transform.MapT
import DDC.Core.Module
import DDC.Core.Exp
import DDC.Type.Check.Context
import DDC.Type.Check.Data
import DDC.Type.Exp.Simple
import DDC.Type.DataDef
import DDC.Type.Universe
import DDC.Base.Pretty
import DDC.Type.Env             (KindEnv, TypeEnv)
import DDC.Control.Monad.Check  (runCheck, throw)
import DDC.Data.ListUtils
import Control.Monad
import qualified DDC.Type.Env           as Env
import qualified Data.Map.Strict        as Map


-- Wrappers ---------------------------------------------------------------------------------------
-- | Type check a module.
--
--   If it's good, you get a new version with types attached to all the bound
--   variables
--
--   If it's bad, you get a description of the error.
checkModule
        :: (Show a, Ord n, Show n, Pretty n)
        => Config n             -- ^ Static configuration.
        -> Module a n           -- ^ Module to check.
        -> Mode n               -- ^ Type checker mode.
        -> ( Either (Error a n) (Module (AnTEC a n) n)
           , CheckTrace )

checkModule !config !xx !mode
 = let  (s, result)     = runCheck (mempty, 0, 0)
                        $ checkModuleM config
                                (configPrimKinds config)
                                (configPrimTypes config)
                                xx mode
        (tr, _, _)      = s
   in   (result, tr)


-- checkModule ------------------------------------------------------------------------------------
-- | Like `checkModule` but using the `CheckM` monad to handle errors.
checkModuleM
        :: (Show a, Ord n, Show n, Pretty n)
        => Config n             -- ^ Static configuration.
        -> KindEnv n            -- ^ Starting kind environment.
        -> TypeEnv n            -- ^ Starting type environment.
        -> Module a n           -- ^ Module to check.
        -> Mode n               -- ^ Type checker mode.
        -> CheckM a n (Module (AnTEC a n) n)

checkModuleM !config !kenv !tenv mm@ModuleCore{} !mode
 = do
        -- Check sorts of imported types --------------------------------------
        --   These have explicit kind annotations on the type parameters,
        --   which we can sort check directly.
        nitsImported'
                <- checkImportTypes config mode
                $  moduleImportTypes mm

        let nksImported' 
                = [(n, kindOfImportType i) | (n, i) <- nitsImported']

        -- Check sorts of imported and local data types -----------------------
        --   These have explicit kind annotations on the type parameters,
        --   which we can sort check directly.
        nksImportDataDef'   
                <- checkSortsOfDataTypes config mode
                $  moduleImportDataDefs  mm

        nksLocalDataDef'
                <- checkSortsOfDataTypes config mode
                $  moduleDataDefsLocal   mm


        -- Check kinds of imported type equations -----------------------------
        --   The right of each type equation can mention both imported abstract
        --   types and data type definitions, so we need to include them in
        --   the kind environment as well.

        -- Kinds of type constructors in scope in the
        -- imported type equations.
        let kenv_importTypeDef 
                = Env.fromList 
                $ [BName n k | (n, k)
                        <- nksImported'
                        ++ nksImportDataDef']

        nktsImportTypeDef'
                <- checkKindsOfTypeDefs config kenv_importTypeDef
                $  moduleImportTypeDefs mm


        -- Check kinds of local type equations --------------------------------
        --   The right of each type equation can mention
        --   imported abstract types, imported and local data type definitions.

        -- Kinds of type constructors in scope in the
        -- locally defined type equations.
        let kenv_localTypeDef
                = Env.fromList
                $ [BName n k | (n, k) 
                        <- nksImported' 
                        ++ nksImportDataDef'
                        ++ nksLocalDataDef' 
                        ++ [(n, k) | (n, (k, _)) <- nktsImportTypeDef' ] 
                  ]

        nktsLocalTypeDef'
                <- checkKindsOfTypeDefs config kenv_localTypeDef
                $  moduleTypeDefsLocal  mm


        -- Check imported data type defs --------------------------------------
        -- TODO: The types of constructors can refer to imported abstract
        --       types as well as type equations.
        let dataDefsImported = moduleImportDataDefs mm
        dataDefsImported'  
         <- case checkDataDefs config dataDefsImported of
                (err : _, _)            -> throw $ ErrorData err
                ([], dataDefsImported') -> return dataDefsImported'


        -- Check the local data defs -----------------
        let dataDefsLocal =  moduleDataDefsLocal mm
        dataDefsLocal'  <- case checkDataDefs config dataDefsLocal of
                                (err : _, _)     -> throw $ ErrorData err
                                ([], dataDefsLocal') -> return dataDefsLocal'


        -----------------------------------------------------------------------
        -- Build the imported defs and kind environment.
        --  This contains kinds of type visible in the imported values.
        let config_import 
                = config
                { configDataDefs = unionDataDefs 
                                        (configDataDefs config)
                                        (fromListDataDefs dataDefsImported') }

        let kenv_import 
                = Env.union kenv 
                $ Env.fromListNT nksImported'

        -- Check types of imported capabilities -----------
        ntsImportCap'   <- checkImportCaps config_import kenv_import mode
                        $  moduleImportCaps mm

        let bsImportCap = [ BName n (typeOfImportCap   isrc)
                          | (n, isrc) <- ntsImportCap' ]

        -- Check types of imported values -----------------
        ntsImportValue' <- checkImportValues config_import kenv_import mode
                        $  moduleImportValues mm


        -----------------------------------------------------------------------
        -- Build the top-level config, defs and environments.
        --  These contain names that are visible to bindings in the module.
        let dataDefs_top    
                = unionDataDefs (configDataDefs config)
                $ unionDataDefs (fromListDataDefs dataDefsImported')
                                (fromListDataDefs dataDefsLocal')

        let typeDefs_top
                =  nktsLocalTypeDef'
                ++ nktsImportTypeDef'

        let caps_top
                = Env.fromList
                $ [BName n t    | (n, ImportCapAbstract t) <- ntsImportCap' ]

        let config_top
                = config 
                { configDataDefs        = dataDefs_top 
                , configTypeDefs        = Map.fromList typeDefs_top
                , configGlobalCaps      = caps_top }

        let kenv_top    
                = Env.unions
                [ kenv_import
                , Env.fromList  [ BName n k | (n, (k, _)) <- typeDefs_top ] ]

        let tenv_top    
                = Env.unions 
                [ tenv
                , Env.fromList  [ BName n (typeOfImportValue isrc)
                                | (n, isrc) <- ntsImportValue' ]

                , Env.fromList  [ BName n (typeOfImportCap   isrc)
                                | (n, isrc) <- ntsImportCap'   ]
                ]

        let ctx_top
                = pushTypes bsImportCap emptyContext

        -- Check the sigs of exported types ---------------
        esrcsType'
                <- checkExportTypes  config_top
                $  moduleExportTypes mm


        -- Check the sigs of exported values --------------
        esrcsValue'
                <- checkExportValues config_top kenv_top
                $  moduleExportValues mm


        -- Check the body of the module -------------------
        (x', _, _effs, ctx)
         <- checkExpM   (makeTable config_top kenv_top tenv_top)
                        ctx_top mode DemandNone (moduleBody mm) 

        -- Apply the final context to the annotations in expressions.
        let applyToAnnot (AnTEC t0 e0 _ x0)
             = do t0' <- applySolved ctx t0
                  e0' <- applySolved ctx e0
                  return $ AnTEC t0' e0' (tBot kClosure) x0

        xx_solved <- mapT (applySolved ctx) x'
        xx_annot  <- reannotateM applyToAnnot xx_solved

        -- Build new module with infered annotations ------
        let mm_inferred
                = mm
                { moduleExportTypes     = esrcsType'
                , moduleImportTypes     = nitsImported'
                , moduleImportTypeDefs  = nktsImportTypeDef'
                , moduleImportCaps      = ntsImportCap'
                , moduleImportValues    = ntsImportValue'
                , moduleTypeDefsLocal   = nktsLocalTypeDef'
                , moduleBody            = xx_annot }


        -- Check that each exported signature matches the type of its binding.
        -- This returns an environment containing all the bindings defined
        -- in the module.
        tenv_binds
         <- checkModuleBinds
                (moduleExportTypes  mm_inferred)
                (moduleExportValues mm_inferred) 
                xx_annot

        -- Build the environment containing all names that can be exported.
        let tenv_exportable = Env.union tenv_top tenv_binds

        -- Check that all exported bindings are defined by the module,
        --   either directly as bindings, or by importing them from somewhere else.
        --   Header modules don't need to contain the complete set of bindings,
        --   but all other modules do.
        when (not $ moduleIsHeader mm_inferred)
                $ mapM_ (checkBindDefined tenv_exportable)
                $ map fst $ moduleExportValues mm_inferred

        -- If exported names are missing types then fill them in.
        let updateExportSource e
                | ExportSourceLocalNoType n <- e
                , Just t  <- Env.lookup (UName n) tenv_exportable
                = ExportSourceLocal n t

                | otherwise = e

        let esrcsValue_updated
                = [ (n, updateExportSource e) | (n, e) <- esrcsValue' ]

        -- Return the checked bindings as they have explicit type annotations.
        let mm_final
                = mm_inferred
                { moduleExportValues    = esrcsValue_updated }

        return mm_final


---------------------------------------------------------------------------------------------------
-- | Check exported types.
checkExportTypes
        :: (Show n, Pretty n, Ord n)
        => Config n
        -> [(n, ExportSource n (Type n))]
        -> CheckM a n [(n, ExportSource n (Type n))]

checkExportTypes config nesrcs
 = let  check (n, esrc)
         | Just k          <- takeTypeOfExportSource esrc
         = do   (k', _, _) <- checkTypeM config Env.empty emptyContext UniverseKind k Recon
                return  $ (n, mapTypeOfExportSource (const k') esrc)

         | otherwise
         = return (n, esrc)
   in do
        -- Check for duplicate exports.
        let dups = findDuplicates $ map fst nesrcs
        (case takeHead dups of
          Just n -> throw $ ErrorExportDuplicate n
          _      -> return ())


        -- Check the kinds of the export specs.
        mapM check nesrcs


---------------------------------------------------------------------------------------------------
-- | Check exported types.
checkExportValues
        :: (Show n, Pretty n, Ord n)
        => Config n -> KindEnv n
        -> [(n, ExportSource n (Type n))]
        -> CheckM a n [(n, ExportSource n (Type n))]

checkExportValues config kenv nesrcs
 = let  check (n, esrc)
         | Just t          <- takeTypeOfExportSource esrc
         = do   (t', _, _) <- checkTypeM config kenv emptyContext UniverseSpec t Recon
                return  $ (n, mapTypeOfExportSource (const t') esrc)

         | otherwise
         = return (n, esrc)

   in do
        -- Check for duplicate exports.
        let dups = findDuplicates $ map fst nesrcs
        (case takeHead dups of
          Just n -> throw $ ErrorExportDuplicate n
          _      -> return ())

        -- Check the types of the exported values.
        mapM check nesrcs


---------------------------------------------------------------------------------------------------
-- | Check kinds of imported types.
checkImportTypes
        :: (Ord n, Show n, Pretty n)
        => Config n -> Mode n
        -> [(n, ImportType n (Type n))]
        -> CheckM a n [(n, ImportType n (Type n))]

checkImportTypes config mode nisrcs
 = let
        -- Checker mode to use.
        modeCheckImportTypes
         = case mode of
                Recon   -> Recon
                _       -> Synth

        -- Check an import definition.
        check (n, isrc)
         = do   let k      =  kindOfImportType isrc
                (k', _, _) <- checkTypeM 
                                config Env.empty emptyContext
                                UniverseKind k 
                                modeCheckImportTypes
                return  (n, mapKindOfImportType (const k') isrc)

        -- Pack down duplicate import definitions.
        --   We can import the same value via multiple modules,
        --   which is ok provided all instances have the same kind.
        pack !mm []
         = return $ Map.toList mm

        pack !mm ((n, isrc) : nis)
         = case Map.lookup n mm of
                Just isrc'
                 | compat isrc isrc' -> pack mm nis
                 | otherwise         -> throw $ ErrorImportDuplicate n

                Nothing              -> pack (Map.insert n isrc mm) nis

        -- Check if two import definitions with the same name are compatible.
        -- The same import definition can appear multiple times provided
        -- each instance has the same name and kind.
        compat (ImportTypeAbstract k1) (ImportTypeAbstract k2) = equivT k1 k2
        compat (ImportTypeBoxed    k1) (ImportTypeBoxed    k2) = equivT k1 k2
        compat _ _ = False

   in do
        -- Check all the imports individually.
        nisrcs' <- mapM check nisrcs

        -- Check that exports with the same name are compatable,
        -- and pack down duplicates.
        pack Map.empty nisrcs'


-------------------------------------------------------------------------------
-- | Check kinds of data type definitions,
--   returning a map of data type constructor constructor name to its kind.
checkSortsOfDataTypes
        :: (Ord n, Show n, Pretty n)
        => Config n -> Mode n
        -> [DataDef n]
        -> CheckM a n [(n, Kind n)]

checkSortsOfDataTypes config mode defs
 = let
        -- Checker mode to use.
        modeCheckDataTypes
         = case mode of
                Recon   -> Recon
                _       -> Synth

        -- Check kind of a data type constructor.
        check def
         = do   let k   = kindOfDataDef def
                (k', _, _) <- checkTypeM
                                config Env.empty emptyContext
                                UniverseKind k
                                modeCheckDataTypes
                return (dataDefTypeName def, k')

   in do
        -- Check all the imports individually.
        nks     <- mapM check defs
        return  nks


---------------------------------------------------------------------------------------------------
-- | Check kinds of imported type equations.
checkKindsOfTypeDefs
        :: (Ord n, Show n, Pretty n)
        => Config n -> KindEnv n
        -> [(n, (Kind n, Type n))]
        -> CheckM a n [(n, (Kind n, Type n))]

checkKindsOfTypeDefs config kenv nkts
 = let
        -- Check a single type equation.
        check (n, (_k, t))
         = do   (t', k', _) 
                 <- checkTypeM config kenv emptyContext
                        UniverseSpec t Recon

                -- TODO: If the kind was specified then check it against the reconstructed one.
                return (n, (k', t'))

   in do
        -- TODO: We need to sort these into dependency order.
        nkts' <- mapM check nkts
        return nkts'


---------------------------------------------------------------------------------------------------
-- | Check types of imported capabilities.
checkImportCaps
        :: (Ord n, Show n, Pretty n)
        => Config n -> KindEnv n -> Mode n
        -> [(n, ImportCap n (Type n))]
        -> CheckM a n [(n, ImportCap n (Type n))]

checkImportCaps config kenv mode nisrcs
 = let
        -- Checker mode to use.
        modeCheckImportCaps
         = case mode of
                Recon   -> Recon
                _       -> Check kEffect

        -- Check an import definition.
        check (n, isrc)
         = do   let t      =  typeOfImportCap isrc
                (t', k, _) <- checkTypeM config kenv emptyContext UniverseSpec
                                         t modeCheckImportCaps

                -- In Recon mode we need to post-check that the imported
                -- capability really has kind Effect.
                --
                -- In Check mode we pass down the expected kind,
                -- so this is checked locally.
                -- 
                when (not $ isEffectKind k)
                 $ throw $ ErrorImportCapNotEffect n

                return (n, mapTypeOfImportCap (const t') isrc)

        -- Pack down duplicate import definitions.
        --   We can import the same capability via multiple modules,
        --   which is ok provided all instances have the same type.
        pack !mm []
         = return $ Map.toList mm

        pack !mm ((n, isrc) : nis)
         = case Map.lookup n mm of
                Just isrc'
                 | compat isrc isrc'    -> pack mm nis
                 | otherwise            -> throw $ ErrorImportDuplicate n

                Nothing                 -> pack (Map.insert n isrc mm) nis

        -- Check if two imported capabilities of the same name are compatiable.
        -- The same import definition can appear multiple times provided each 
        -- instance has the same name and type.
        compat (ImportCapAbstract t1) (ImportCapAbstract t2) = equivT t1 t2

    in do
        -- Check all the imports individually.
        nisrcs' <- mapM check nisrcs

        -- Check that imports with the same name are compatable,
        -- and pack down duplicates.
        pack Map.empty nisrcs'


---------------------------------------------------------------------------------------------------
-- | Check types of imported values.
checkImportValues
        :: (Ord n, Show n, Pretty n)
        => Config n -> KindEnv n -> Mode n
        -> [(n, ImportValue n (Type n))]
        -> CheckM a n [(n, ImportValue n (Type n))]

checkImportValues config kenv mode nisrcs
 = let
        -- Checker mode to use.
        modeCheckImportTypes
         = case mode of
                Recon   -> Recon
                _       -> Check kData

        -- Check an import definition.
        check (n, isrc)
         = do   let t      =  typeOfImportValue isrc
                (t', k, _) <- checkTypeM config kenv emptyContext UniverseSpec
                                         t modeCheckImportTypes

                -- In Recon mode we need to post-check that the imported
                -- value really has kind Data.
                --
                -- In Check mode we pass down the expected kind,
                -- so this is checked locally.
                --
                when (not $ isDataKind k)
                 $ throw $ ErrorImportValueNotData n

                return  (n, mapTypeOfImportValue (const t') isrc)

        -- Pack down duplicate import definitions.
        --   We can import the same value via multiple modules,
        --   which is ok provided all instances have the same type.
        pack !mm []
         = return $ Map.toList mm

        pack !mm ((n, isrc) : nis)
         = case Map.lookup n mm of
                Just isrc'
                  | compat isrc isrc'   -> pack mm nis
                  | otherwise           -> throw $ ErrorImportDuplicate n

                Nothing                 -> pack (Map.insert n isrc mm) nis

        -- Check if two imported values of the same name are compatable.
        compat (ImportValueModule _ _ t1 a1) 
               (ImportValueModule _ _ t2 a2)
         = equivT t1 t2 && a1 == a2

        compat (ImportValueSea _ t1)
               (ImportValueSea _ t2)
         = equivT t1 t2 

        compat _ _ = False

   in do
        -- Check all the imports individually.
        nisrcs' <- mapM check nisrcs

        -- Check that imports with the same name are compatable,
        -- and pack down duplicates.
        pack Map.empty nisrcs'


---------------------------------------------------------------------------------------------------
-- | Check that the exported signatures match the types of their bindings.
checkModuleBinds
        :: Ord n
        => [(n, ExportSource n (Type n))]       -- ^ Exported types.
        -> [(n, ExportSource n (Type n))]       -- ^ Exported values
        -> Exp (AnTEC a n) n
        -> CheckM a n (TypeEnv n)               -- ^ Environment of top-level bindings
                                                --   defined by the module

checkModuleBinds !ksExports !tsExports !xx
 = case xx of
        XLet _ (LLet b _) x2
         -> do  checkModuleBind  ksExports tsExports b
                env     <- checkModuleBinds ksExports tsExports x2
                return  $ Env.extend b env

        XLet _ (LRec bxs) x2
         -> do  mapM_ (checkModuleBind ksExports tsExports) $ map fst bxs
                env     <- checkModuleBinds ksExports tsExports x2
                return  $ Env.extends (map fst bxs) env

        XLet _ (LPrivate _ _ _) x2
         ->     checkModuleBinds ksExports tsExports x2

        _ ->    return Env.empty


-- | If some bind is exported, then check that it matches the exported version.
checkModuleBind
        :: Ord n
        => [(n, ExportSource n (Type n))]       -- ^ Exported types.
        -> [(n, ExportSource n (Type n))]       -- ^ Exported values.
        -> Bind n
        -> CheckM a n ()

checkModuleBind !_ksExports !tsExports !b
 | BName n tDef <- b
 = case join $ liftM takeTypeOfExportSource $ lookup n tsExports of
        Nothing                 -> return ()
        Just tExport
         | equivT tDef tExport  -> return ()
         | otherwise            -> throw $ ErrorExportMismatch n tExport tDef

 -- Only named bindings can be exported,
 --  so we don't need to worry about non-named ones.
 | otherwise
 = return ()


---------------------------------------------------------------------------------------------------
-- | Check that an exported top-level value is actually defined by the module.
checkBindDefined
        :: Ord n
        => TypeEnv n            -- ^ Types defined by the module.
        -> n                    -- ^ Name of an exported binding.
        -> CheckM a n ()

checkBindDefined env n
 = case Env.lookup (UName n) env of
        Just _  -> return ()
        _       -> throw $ ErrorExportUndefined n

