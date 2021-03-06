
module DDC.Build.Language
        ( Language      (..)
        , Bundle        (..)
        , Fragment      (..)
        , languages
        , languageOfExtension)
where
import DDC.Core.Fragment
import DDC.Build.Language.Base
import DDC.Build.Language.Flow    as Flow
import DDC.Build.Language.Machine as Machine
import DDC.Build.Language.Salt    as Salt
import DDC.Build.Language.Tetra   as Tetra
import DDC.Build.Language.Zero    as Zero


-- | Supported language profiles.
--   
--   One of @Tetra@, @Salt@, @Eval@, @Flow@, @Zero@.
languages :: [(String, Language)]
languages
 =      [ ( "Flow",    Flow.language)
        , ( "Machine", Machine.language)
        , ( "Salt",    Salt.language)
        , ( "Tetra",   Tetra.language) 
        , ( "Zero",    Zero.language) ]


-- | Return the language fragment definition corresponding to the given 
--   file extension. eg @dct@ gives the definition of the Tetra language.
languageOfExtension :: String -> Maybe Language
languageOfExtension ext
 = let  -- Strip of dots at the front.
        -- the 'takeExtension' function from System.FilePath
        -- doens't do this itself.
        ext'     = case ext of 
                        '.' : rest      -> rest
                        _               -> ext
   in case ext' of
        "dcf"   -> Just Flow.language
        "dcm"   -> Just Machine.language
        "dcs"   -> Just Salt.language
        "dct"   -> Just Tetra.language
        "dcz"   -> Just Zero.language
        _       -> Nothing

