
module DDC.War.Create.CreateDCX
        (create)
where
import DDC.War.Interface.Config
import DDC.War.Job
import System.FilePath
import Data.List
import Data.Set                                 (Set)
import qualified DDC.War.Job.RunDCX             as RunDCX
import qualified DDC.War.Job.Diff               as Diff
import qualified Data.Set                       as Set


create :: Way -> Set FilePath -> FilePath -> Maybe Chain
create way allFiles filePath
 | isSuffixOf ".dcx" filePath
 = let  
        fileName         = takeFileName filePath
        sourceDir        = takeDirectory  filePath
        buildDir         = sourceDir </> "war-" ++ wayName way
        testName         = filePath

        testDDCiStdout   = buildDir  </> replaceExtension fileName ".ddci-core.stdout"
        testDDCiStderr   = buildDir  </> replaceExtension fileName ".ddci-core.stderr"

        testStdoutCheck  = sourceDir </> "Test.stdout.check"
        testStdoutDiff   = buildDir  </> "Test.stdout.check.diff"
        shouldDiffStdout = Set.member testStdoutCheck allFiles

        jobRun           = jobOfSpec $ RunDCX.Spec
                                testName (wayName way) filePath
                                buildDir testDDCiStdout testDDCiStderr

        jobDiff          = jobOfSpec  $ Diff.Spec
                                testName (wayName way) testStdoutCheck
                                testDDCiStdout testStdoutDiff

   in   Just $ Chain 
                $  [jobRun] 
                ++ (if shouldDiffStdout then [jobDiff] else [])

 | otherwise    = Nothing