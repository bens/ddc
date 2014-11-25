
module DDC.Core.Transform.Resolve
        ( resolveNamesInModule )
where
import DDC.Core.Module
import DDC.Core.Exp
import DDC.Core.Collect.Support
import DDC.Type.Env             (KindEnv, TypeEnv)
import Data.Maybe
import Data.Map                 (Map)
import qualified Data.Map       as Map
import qualified Data.Set       as Set

-- TODO: handle re-exports of foreign types and values.
--       Saying "export type foo" should work even if "foo" was a foreign type.

-- | For all the names that are free in this module, if there is a
--   corresponding export in one of the modules in the given map,
--   then add the appropriate import definition.
resolveNamesInModule 
        :: Ord n
        => KindEnv n
        -> TypeEnv n
        -> Map ModuleName (Module b n)
        -> Module a n
        -> Module a n

resolveNamesInModule kenv tenv deps mm
 = let
        sp      = support kenv tenv mm

   in   mm { moduleImportTypes   
                =  moduleImportTypes  mm 
                ++ importsForTyCons deps (Set.toList $ supportTyCon sp)

           , moduleImportDataDefs
                =  moduleImportDataDefs mm 
                ++ [(def, moduleName m) | m   <- Map.elems deps
                                        , def <- moduleDataDefsLocal m ] 
           , moduleImportValues  
                =  moduleImportValues mm 
                ++ importsForDaVars deps (Set.toList $ supportDaVar sp) }


---------------------------------------------------------------------------------------------------
-- | Build import statements for the given list of unbound type constructors.
--
--   We look in the dependency modules for a matching export,
--   and produce the corresponding import statement to use it.
--
importsForTyCons
        :: Ord n
        => Map ModuleName (Module b n)  -- ^ Modules which this one depends on.
        -> [Bound n]                    -- ^ Unbound type constructors to find imports for.
        -> [(n, ImportSource n)]

-- TODO: we're just re-importing everything imported by the dependencies.
--       The support set doesn't seem to include tycons just mentioned in 
--       types of imported values, so they're incomplete.
importsForTyCons deps _tyCons
 = concat
        [ [(n, ImportSourceAbstract k)
                | (n, k)        <- Map.toList $ Map.unions 
                                $  map importedTyConsAbs   $ Map.elems deps]

        , [(n, ImportSourceAbstract k)
                | (n, (_, k))   <- Map.toList $ Map.unions 
                                $  map exportedTyConsLocal $ Map.elems deps]

        , [(n, ImportSourceBoxed k) 
                | (n, k)        <- Map.toList $ Map.unions 
                                $  map importedTyConsBoxed $ Map.elems deps]
        ]


---------------------------------------------------------------------------------------------------
-- | Build import statements for the given list of unbound value variables.
--
--   We look in dependency modules for a matching export, 
--   and produce the corresponding import statement to use it.
--
importsForDaVars 
        :: Ord n
        => Map ModuleName (Module b n)  -- ^ Modules which this one depends on.
        -> [Bound n]                    -- ^ Unbound type constructors to find imports for.
        -> [(n, ImportSource n)]

importsForDaVars deps daVars
 = let
        -- Variables defined locally by each module and exported.
        daVarsLocal     
         = Map.unions $ map exportedDaVarsLocal $ Map.elems deps

        -- Variables imported by each module via the C calling convention.
        -- TODO: Don't auto-export all foreign imported values.
        daVarsForeign
         = Map.unions $ map importedDaVarsSea   $ Map.elems deps

        findImport n
         | Just (modName, t) <- Map.lookup n daVarsLocal
         = Just (n, ImportSourceModule modName n t)

         | Just (s, t)       <- Map.lookup n daVarsForeign
         = Just (n, ImportSourceSea    s t)

         | otherwise
         = Nothing

   in   catMaybes [ findImport n | UName n <- daVars ]


---------------------------------------------------------------------------------------------------
-- | Get the tycons that are locally defined, then exported by a module.
exportedTyConsLocal :: Ord n => Module b n -> Map n (ModuleName, Kind n)
exportedTyConsLocal mm
        = Map.fromList
        $ [ (n, (moduleName mm, t)) 
                        | (n, ExportSourceLocal _ t) <- moduleExportTypes mm ]


-- | Get the data variable names that are locally defined, then exported by a module.
exportedDaVarsLocal :: Ord n => Module b n -> Map n (ModuleName, Type n)
exportedDaVarsLocal mm
        = Map.fromList
        $ [ (n, (moduleName mm, t)) 
                        | (n, ExportSourceLocal _ t) <- moduleExportValues mm ]


-- | Get the type constructors that are imported abstractly by a module.
importedTyConsAbs  :: Ord n => Module b n -> Map n (Kind n)
importedTyConsAbs mm
        = Map.fromList
        $ [ (n, k)      | (n, ImportSourceAbstract k)  <- moduleImportTypes mm ]


-- | Get the type constructors that are imported as boxed foreign types.
importedTyConsBoxed :: Ord n => Module b n -> Map n (Kind n)
importedTyConsBoxed mm
        = Map.fromList
        $ [ (n, k)      | (n, ImportSourceBoxed k)      <- moduleImportTypes mm ]


-- | Get the data variables that are imported from C land by a module.
importedDaVarsSea  :: Ord n => Module b n -> Map n (String, Type n)
importedDaVarsSea mm
        = Map.fromList
        $ [ (n, (s, t)) | (n, ImportSourceSea s t)     <- moduleImportValues mm ]

