-- | Compiler stages.
--
--   A compiler 'stage' is a compound pipeline that depends on DDCI specific
--   configuration information. 
--
--   This is where we select optimisation passes based on command line
--   flags, and dump the intermediate representation after the various transforms.
--
--   These stages are then invoked by the DDCI commands.
--
module DDCI.Core.Stage
        ( stageLiteToSalt
        , stageSaltToC
        , stageSaltToLLVM
        , stageCompileLLVM)
where
import DDCI.Core.State
import DDC.Build.Builder
import DDC.Build.Pipeline
import DDC.Build.Language
import System.FilePath
import Data.Monoid
import Data.Maybe
import DDC.Core.Simplifier.Recipie      as Simpl
import qualified DDC.Core.Lite.Name     as Lite
import qualified DDC.Core.Salt.Name     as Salt
import qualified DDC.Core.Check         as C
import qualified Data.Set               as Set


------------------------------------------------------------------------------
-- | If the Dump mode is set 
--    then produce a SinkFile to write a module to a file, 
--    otherwise produce SinkDiscard to drop it on the floor.
dump :: State -> Source -> String -> Sink
dump state source dumpFile 
        | Set.member Dump $ stateModes state
        = let   outputDir
                 | SourceFile filePath  <- source
                 = fromMaybe (takeDirectory filePath) 
                             (stateOutputDir state)

                 | otherwise
                 = fromMaybe "."
                             (stateOutputDir state)

          in    SinkFile $ outputDir </> dumpFile

        | otherwise
        = SinkDiscard


-------------------------------------------------------------------------------
-- | Convert Lite to Salt.
--   
--   Result is a-normalised.
--
stageLiteToSalt 
        :: State -> Source -> Builder
        -> [PipeCore (C.AnTEC () Salt.Name) Salt.Name] 
        -> PipeCore  (C.AnTEC () Lite.Name) Lite.Name

stageLiteToSalt state source builder pipesSalt
 = PipeCoreAsLite 
   [ PipeLiteOutput       (dump state source "dump.lite-loaded.dcl")
   , PipeLiteToSalt       (buildSpec builder)
     [ PipeCoreOutput     (dump state source "dump.lite-to-salt.dce")
     , PipeCoreSimplify   fragmentSalt Simpl.anormalize
       [ PipeCoreOutput   (dump state source "dump.salt-normalized.dce")
       , PipeCoreCheck    fragmentSalt
         pipesSalt]]]


-- | Convert Salt to C code.
stageSaltToC
        :: State -> Source -> Builder
        -> Sink
        -> PipeCore a Salt.Name

stageSaltToC state source _builder sink
 = PipeCoreSimplify       fragmentSalt
                          (stateSimplifier state <> Simpl.anormalize)
   [ PipeCoreOutput       (dump state source "dump.salt-simplified.dce")
   , PipeCoreCheck        fragmentSalt
     [ PipeCoreAsSalt
       [ PipeSaltTransfer
         [ PipeSaltOutput (dump state source "dump.salt-transfer.dce")
         , PipeSaltPrint  
                (Set.member SaltPrelude (stateModes state))
                sink]]]]


-- | Convert Salt to LLVM.
stageSaltToLLVM
        :: State -> Source -> Builder
        -> [PipeLlvm]
        -> PipeCore a Salt.Name

stageSaltToLLVM state source builder pipesLLVM
 = PipeCoreSimplify         fragmentSalt
                            (stateSimplifier state <> Simpl.anormalize)
   [ PipeCoreOutput         (dump state source "dump.salt-simplified.dce")
   , PipeCoreCheck          fragmentSalt
     [ PipeCoreAsSalt
       [ PipeSaltTransfer
         [ PipeSaltOutput   (dump state source "dump.salt-transfer.dce")
         , PipeSaltToLlvm   (buildSpec builder) 
           ( PipeLlvmPrint  (dump state source "dump.salt-to-llvm.ll")
           : pipesLLVM) ]]]]


-- | Compile LLVM code.
stageCompileLLVM 
        :: State -> Source -> Builder 
        -> FilePath             -- ^ Path of original source file.
                                --   Build products are placed into the same dir.
        -> Bool                 -- ^ Should we link this into an executable
        -> PipeLlvm

stageCompileLLVM state _source builder filePath shouldLinkExe
 = let  -- Decide where to place the build products.
        outputDir      = fromMaybe (takeDirectory filePath) (stateOutputDir state)
        outputDirBase  = dropExtension (replaceDirectory filePath outputDir)
        llPath         = outputDirBase ++ ".ddc.ll"
        sPath          = outputDirBase ++ ".ddc.s"
        oPath          = outputDirBase ++ ".o"
        exePathDefault = outputDirBase
        exePath        = fromMaybe exePathDefault (stateOutputFile state)
   in   -- Make the pipeline for the final compilation.
        PipeLlvmCompile
          { pipeBuilder           = builder
          , pipeFileLlvm          = llPath
          , pipeFileAsm           = sPath
          , pipeFileObject        = oPath
          , pipeFileExe           = if shouldLinkExe 
                                        then Just exePath 
                                        else Nothing }
