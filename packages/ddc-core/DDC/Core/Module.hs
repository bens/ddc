module DDC.Core.Module
        ( -- * Modules
          Module        (..)
        , isMainModule
        , moduleDataDefs
        , moduleTypeDefs
        , moduleKindEnv, moduleTypeEnv
        , moduleEnvT,    moduleEnvX
        , modulesEnvT,   modulesEnvX
        , moduleTopBinds
        , moduleTopBindTypes
        , mapTopBinds

          -- * Module maps
        , ModuleMap
        , modulesExportTypes
        , modulesExportValues

         -- * Module Names
        , ModuleName    (..)
        , readModuleName
        , isMainModuleName
        , moduleNameMatchesPath
        
         -- * Qualified names.
        , QualName      (..)

         -- * Export Definitions
        , ExportSource  (..)
        , takeTypeOfExportSource
        , mapTypeOfExportSource

         -- * Import Definitions
         -- ** Import Types
        , ImportType    (..)
        , kindOfImportType
        , mapKindOfImportType

         -- ** Import Capabilities
        , ImportCap     (..)
        , typeOfImportCap
        , mapTypeOfImportCap

         -- ** Import Types
        , ImportValue   (..)
        , typeOfImportValue
        , mapTypeOfImportValue)
where
import DDC.Core.Module.Export
import DDC.Core.Module.Import
import DDC.Core.Module.Name
import DDC.Core.Exp.Annot
import DDC.Type.DataDef                 
import Data.Typeable
import Data.Map.Strict                  (Map)
import Data.Set                         (Set)
import DDC.Core.Env.EnvT                (EnvT (EnvT))
import DDC.Core.Env.EnvX                (EnvX)
import DDC.Type.Env                     as Env
import qualified DDC.Type.DataDef       as DataDef
import qualified Data.Map.Strict        as Map
import qualified Data.Set               as Set
import qualified DDC.Core.Env.EnvT      as EnvT
import qualified DDC.Core.Env.EnvX      as EnvX
import Control.DeepSeq
import Data.Maybe


-- Module -----------------------------------------------------------------------------------------
-- | A module can be mutually recursive with other modules.
data Module a n
        = ModuleCore
        { -- | Name of this module.
          moduleName            :: !ModuleName

          -- | Whether this is a module header only.
          --   Module headers contain type definitions, as well as imports and exports, 
          --   but no function definitions. Module headers are used in interface files.
        , moduleIsHeader        :: !Bool

          -- Exports ------------------
          -- | Kinds of exported types.
        , moduleExportTypes     :: ![(n, ExportSource n (Type n))]

          -- | Types of exported values.
        , moduleExportValues    :: ![(n, ExportSource n (Type n))]

          -- Imports ------------------
          -- | Define imported types.
        , moduleImportTypes     :: ![(n, ImportType   n (Type n))]

          -- | Define imported capabilities.
        , moduleImportCaps      :: ![(n, ImportCap    n (Type n))]

          -- | Define imported values.
        , moduleImportValues    :: ![(n, ImportValue  n (Type n))]

          -- | Data defs imported from other modules.
        , moduleImportDataDefs  :: ![DataDef n]

          -- | Type defs imported from other modules.
        , moduleImportTypeDefs  :: ![(n, (Kind n, Type n))]

          -- Local defs ---------------
          -- | Data types defined in this module.
        , moduleDataDefsLocal   :: ![DataDef n]

          -- | Type definitions in this module.
        , moduleTypeDefsLocal   :: ![(n, (Kind n, Type n))]

          -- | The module body consists of some let-bindings wrapping a unit
          --   data constructor. We're only interested in the bindings, with
          --   the unit being just a place-holder.
        , moduleBody            :: !(Exp a n)
        }
        deriving (Show, Typeable)


instance (NFData a, NFData n) => NFData (Module a n) where
 rnf !mm
        =     rnf (moduleName           mm)
        `seq` rnf (moduleIsHeader       mm)
        `seq` rnf (moduleExportTypes    mm)
        `seq` rnf (moduleExportValues   mm)
        `seq` rnf (moduleImportTypes    mm)
        `seq` rnf (moduleImportCaps     mm)
        `seq` rnf (moduleImportValues   mm)
        `seq` rnf (moduleImportDataDefs mm)
        `seq` rnf (moduleImportTypeDefs mm)
        `seq` rnf (moduleDataDefsLocal  mm)
        `seq` rnf (moduleTypeDefsLocal  mm)
        `seq` rnf (moduleBody           mm)


-- | Check if this is the `Main` module.
isMainModule :: Module a n -> Bool
isMainModule mm
        = isMainModuleName 
        $ moduleName mm


-- | Get the data type definitions visible in a module.
moduleDataDefs :: Ord n => Module a n -> DataDefs n
moduleDataDefs mm
        = fromListDataDefs 
        $ (moduleImportDataDefs mm ++ moduleDataDefsLocal mm)


-- | Get the data type definitions visible in a module.
moduleTypeDefs :: Ord n => Module a n -> [(n, (Kind n, Type n))]
moduleTypeDefs mm
        = moduleImportTypeDefs mm ++ moduleTypeDefsLocal mm


-- | Get the top-level kind environment of a module,
--   from its imported types.
moduleKindEnv :: Ord n => Module a n -> KindEnv n
moduleKindEnv mm
        = Env.fromList 
        $ [BName n (kindOfImportType isrc) | (n, isrc) <- moduleImportTypes mm]


-- | Get the top-level type environment of a module,
--   from its imported values.
moduleTypeEnv :: Ord n => Module a n -> TypeEnv n
moduleTypeEnv mm
        = Env.fromList 
        $ [BName n (typeOfImportValue isrc) | (n, isrc) <- moduleImportValues mm]


-- | Extract the top-level `EnvT` environment from a module.
--
--   This includes kinds for abstract types, data types, and type equations, 
--   but not primitive types which are fragment specific.
--
moduleEnvT 
        :: Ord n 
        => KindEnv n    -- ^ Primitive kind environment.
        -> Module a n   -- ^ Module to extract environemnt from.
        -> EnvT n

moduleEnvT kenvPrim mm
 = EnvT
 { EnvT.envtEquations   
        = Map.unions
        [ Map.fromList [(n, t)  | (n, (_, t)) <- moduleImportTypeDefs mm]
        , Map.fromList [(n, t)  | (n, (_, t)) <- moduleTypeDefsLocal  mm]]

 , EnvT.envtCapabilities
        = Map.fromList [(n, typeOfImportCap ic) | (n, ic) <- moduleImportCaps mm]

 , EnvT.envtPrimFun
        = Env.envPrimFun kenvPrim

 , EnvT.envtMap         
        = let -- Kinds of imported foreign types.
              nksImportForeignType
                = Map.fromList [(n, kindOfImportType isrc) 
                               | (n, isrc) <- moduleImportTypes mm]

              -- Kinds of imported data types.
              nksImportDataType
               = Map.fromList  [(dataDefTypeName def, kindOfDataDef def) 
                               | def <- moduleImportDataDefs mm]

              -- Kinds of imported type defs.
              nksImportTypeDef
               = Map.fromList  [(n, k) | (n, (k, _)) <- moduleImportTypeDefs mm]

              -- Kinds of locally defined data types.
              nksLocalDataType
               = Map.fromList  [(dataDefTypeName def, kindOfDataDef def) 
                               | def <- moduleImportDataDefs mm]

              -- Kinds of imported type defs.
              nksLocalTypeDef
               = Map.fromList  [(n, k) | (n, (k, _)) <- moduleTypeDefsLocal mm]

          in  -- Build a map of all the kinds, 
              -- Where kinds of locally defined type shadow the imported ones.
              Map.unions
                [ nksImportForeignType
                , nksImportDataType
                , nksImportTypeDef
                , nksLocalDataType
                , nksLocalTypeDef ]

 , EnvT.envtStack       = []
 , EnvT.envtStackLength = 0

 }


-- | Extract the top-level `EnvT` environment from several modules.
---
--   After unioning all the individual environments we reset the prim 
--   function so we only have a single version of it.
modulesEnvT 
        :: Ord n
        => KindEnv n    -- ^ Primitive kind environment.
        -> [Module a n] -- ^ Modules to build environment from.
        -> EnvT n

modulesEnvT kenv ms
        = (EnvT.unions $ map (moduleEnvT kenv) ms)
        { EnvT.envtPrimFun = Env.envPrimFun kenv }


-- | Extract the top-level `EnvX` environment from a module.
moduleEnvX 
        :: Ord n 
        => KindEnv n    -- ^ Primitive kind environment.
        -> TypeEnv n    -- ^ Primitive type environment.
        -> DataDefs n   -- ^ Primitive data type definitions.
        -> Module a n   -- ^ Module to extract environemnt from.
        -> EnvX n

moduleEnvX kenvPrim tenvPrim dataDefs mm
 = EnvX.empty
 { EnvX.envxEnvT        = moduleEnvT kenvPrim mm
 , EnvX.envxPrimFun     = Env.envPrimFun tenvPrim 

 , EnvX.envxDataDefs    
        = DataDef.unionDataDefs dataDefs
        $ DataDef.unionDataDefs 
                (DataDef.fromListDataDefs $ moduleImportDataDefs mm)
                (DataDef.fromListDataDefs $ moduleDataDefsLocal  mm)

 , EnvX.envxMap
        = Map.fromList 
                [ (n, typeOfImportValue isrc)
                | (n, isrc) <- moduleImportValues mm ]
 }


-- | Extract the top-level `EnvT` environment from several modules.
modulesEnvX
        :: Ord n
        => KindEnv n    -- ^ Primitive kind environment.
        -> TypeEnv n    -- ^ Primitive type environment.
        -> DataDefs n   -- ^ Primitive data type definitions.
        -> [Module a n] -- ^ Modules to build environment from.
        -> EnvX n

modulesEnvX kenv tenv defs ms
 = let  -- Base environment contains all the prims.
        --   We need to include this for the case when there are no
        --   provided modules, so the prims are still end up in the result.
        env0    = EnvX.fromPrimEnvs kenv tenv defs

        -- Build environments for each of the modules
        envs    = map (moduleEnvX kenv tenv defs) ms

        -- Union the above into a composite environment.
        env     = EnvX.unions (env0 : envs)

        -- The EnvX.unions function combines the prim funs so that
        -- if a lookup fails the primfun from the next module will 
        -- be called, but as the primfuns in each module are identical
        -- we only need a single version.
        env'    = env
                { EnvX.envxPrimFun  = EnvX.envxPrimFun env0 }
   in   env'


-- | Get the set of top-level value bindings in a module.
moduleTopBinds :: Ord n => Module a n -> Set n
moduleTopBinds mm
 = go (moduleBody mm)
 where  go xx
         = case xx of
                XLet _ (LLet (BName n _) _) x2    
                 -> Set.insert n (go x2)

                XLet _ (LLet _ _) x2    
                 -> go x2

                XLet _ (LRec bxs) x2    
                 ->     Set.fromList (mapMaybe takeNameOfBind $ map fst bxs)
                 `Set.union` go x2

                _ -> Set.empty


-- | Get a map of named top-level bindings to their types.
moduleTopBindTypes :: Ord n => Module a n -> Map n (Type n)
moduleTopBindTypes mm
 = go Map.empty (moduleBody mm)
 where  go acc xx
         = case xx of
                XLet _ (LLet (BName n t) _) x2
                  -> go (Map.insert n t acc) x2

                XLet _ (LLet _ _) x2
                  -> go acc x2

                XLet _ (LRec bxs) x2
                  -> let nts    = Map.fromList [(n, t) | BName n t <- map fst bxs]
                     in  go (Map.union acc nts) x2
                 
                _ -> acc


-- | Apply a function to all the top-level bindings in a module,
--   producing a list of the results.
mapTopBinds :: (Bind n -> Exp a n -> b) -> Module a n -> [b]
mapTopBinds f mm
 = go [] (moduleBody mm)
 where 
        go acc xx
         = case xx of
                XLet _ (LLet b1 x1) x2
                 -> go (f b1 x1 : acc) x2

                XLet _ (LRec bxs)   x2
                 -> let rs      = reverse $ map (uncurry f) bxs
                    in  go (rs ++ acc)  x2

                _ -> reverse acc


-- ModuleMap --------------------------------------------------------------------------------------
-- | Map of module names to modules.
type ModuleMap a n 
        = Map ModuleName (Module a n)


-- | Add the kind environment exported by all these modules to the given one.
modulesExportTypes :: Ord n => ModuleMap a n -> KindEnv n -> KindEnv n
modulesExportTypes mods base
 = let  envOfModule m
         = Env.fromList
         $ [BName n t   |  (n, Just t) 
                        <- map (liftSnd takeTypeOfExportSource) $ moduleExportTypes m]

        liftSnd f (x, y) = (x, f y)

   in   Env.unions $ base : (map envOfModule $ Map.elems mods)
         

-- | Add the type environment exported by all these modules to the given one.
modulesExportValues :: Ord n => ModuleMap a n -> TypeEnv n -> TypeEnv n
modulesExportValues mods base
 = let  envOfModule m
         = Env.fromList
         $ [BName n t   | (n, Just t)
                        <- map (liftSnd takeTypeOfExportSource) $ moduleExportValues m] 

        liftSnd f (x, y) = (x, f y)

   in   Env.unions $ base : (map envOfModule $ Map.elems mods)

