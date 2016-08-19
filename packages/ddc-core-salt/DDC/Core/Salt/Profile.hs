
-- | Language profile for Disciple Core Salt.
module DDC.Core.Salt.Profile
        ( profile
        , lexModuleString
        , lexExpString)
where
import DDC.Core.Salt.Env
import DDC.Core.Salt.Name
import DDC.Core.Fragment
import DDC.Core.Lexer
import DDC.Data.SourcePos

-- | Language profile for Disciple Core Salt.
profile :: Profile Name 
profile
        = Profile
        { profileName                   = "Salt"
        , profileFeatures               = features
        , profilePrimDataDefs           = primDataDefs
        , profilePrimKinds              = primKindEnv
        , profilePrimTypes              = primTypeEnv 
        , profileTypeIsUnboxed          = typeIsUnboxed 
        , profileNameIsHole             = Nothing 
        , profileMakeLiteralName        = Just makeLiteralName }


-- | Convert a literal to a Salt name.
makeLiteralName :: SourcePos -> Literal -> Bool -> Maybe Name
makeLiteralName _ lit True
 = case lit of
        LNat    n       -> Just $ NameLitNat     n
        LInt    i       -> Just $ NameLitInt     i
        LSize   s       -> Just $ NameLitSize    s
        LWord   i b     -> Just $ NameLitWord    i b
        LFloat  f b     -> Just $ NameLitFloat   f b
        LString tx      -> Just $ NameLitTextLit tx

makeLiteralName _ _ _
 = Nothing


-- | The Salt fragment doesn't support many features.
--   No nested functions, no partial application and so on.
features :: Features
features = zeroFeatures
        { featuresFunctionalEffects     = True
        , featuresFunctionalClosures    = True
        , featuresDebruijnBinders       = True
        , featuresUnusedBindings        = True 
        , featuresEffectCapabilities    = True

          -- ISSUE #340: Check for partial application of supers in Salt
          -- fragment check. This is enabled to support the reify# primitive,
          -- which takes the address of a top-level super. However, the Salt
          -- language itself doesn't support general partial application.
          -- The fragment compliance checker should distinguish between these
          -- two cases.
        , featuresPartialApplication    = True }


-- | Lex a string to tokens, using primitive names.
lexModuleString
         :: String      -- ^ Source file name.
         -> Int         -- ^ Starting line number.
         -> String      -- ^ String to parse.
         -> [Located (Token Name)]

lexModuleString sourceName lineStart str
 = map rn $ lexModuleWithOffside sourceName lineStart str
 where
        rn (Located sp strTok) 
         = case renameToken readName strTok of
                Just t' -> Located sp t'
                Nothing -> Located sp (KErrorJunk "lexical error")


-- | Lex a string to tokens, using primitive names.
lexExpString
         :: String      -- ^ Source file name.
         -> Int         -- ^ Starting line number.
         -> String      -- ^ String to parse.
         -> [Located (Token Name)]

lexExpString sourceName lineStart str
 = map rn $ lexExp sourceName lineStart str
 where 
        rn (Located sp strTok) 
         = case renameToken readName strTok of
                Just t' -> Located sp t'
                Nothing -> Located sp (KErrorJunk "lexical error")

