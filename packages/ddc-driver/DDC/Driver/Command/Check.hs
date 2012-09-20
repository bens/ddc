module DDC.Driver.Command.Check
        ( cmdUniverse
        , cmdUniverse1
        , cmdUniverse2
        , cmdUniverse3
        , cmdShowKind
        , cmdTypeEquiv
        , cmdShowWType
        , cmdShowType
        , cmdExpRecon
        , ShowTypeMode(..)
        , cmdParseCheckType
        , cmdParseCheckModule
        , cmdParseCheckExp)
where
import DDC.Driver.Bundle
import DDC.Driver.Source
import DDC.Driver.Output
import DDC.Build.Language
import DDC.Core.Fragment.Profile
import DDC.Core.Load
import DDC.Core.Parser
import DDC.Core.Lexer
import DDC.Core.Module
import DDC.Core.Exp
import DDC.Core.Pretty
import DDC.Type.Transform.SpreadT
import DDC.Type.Universe
import DDC.Type.Equiv
import qualified DDC.Base.Parser        as BP
import qualified DDC.Type.Check         as T


-- universe -------------------------------------------------------------------
-- | Show the universe of some type.
cmdUniverse :: Bundle -> Source -> String -> IO ()
cmdUniverse bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = do   result         <- cmdParseCheckType source frag str
        case result of
         Just (t, _)
          | Just u      <- universeOfType 
                                (profilePrimKinds $ fragmentProfile frag)
                                t
          ->    outDocLn $ ppr u

         _ ->   outDocLn $ text "no universe"


-- | Given the type of some thing (up one level)
--   show the universe of the thing.
cmdUniverse1 :: Bundle -> Source -> String -> IO ()
cmdUniverse1 bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = do   result         <- cmdParseCheckType source frag str
        case result of
         Just (t, _)
          | Just u      <- universeFromType1 
                                (profilePrimKinds $ fragmentProfile frag)
                                t
          ->    outDocLn $ ppr u

         _ ->   outDocLn $ text "no universe"


-- | Given the kind of some thing (up two levels)
--   show the universe of the thing.
cmdUniverse2 :: Bundle -> Source -> String -> IO ()
cmdUniverse2 bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = do   result         <- cmdParseCheckType source frag str
        case result of
         Just (t, _)
          | Just u      <- universeFromType2 t
          ->    outDocLn $ ppr u

         _ ->   outDocLn $ text "no universe"


-- | Given the sort of some thing (up three levels)
--   show the universe of the thing.
--   We can't type check naked sorts, so just parse them.
cmdUniverse3 :: Bundle -> Source -> String -> IO ()
cmdUniverse3 bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        profile = fragmentProfile frag
        kenv    = profilePrimKinds profile

        -- Parse the tokens.
        goParse toks                
         = case BP.runTokenParser describeTok srcName pType toks of
            Left err    -> outDocLn $ ppr err
            Right t     -> goUniverse3 (spreadT kenv t)

        goUniverse3 tt
         = case universeFromType3 tt of
            Just u      -> outDocLn $ ppr u
            Nothing     -> outDocLn $ text "no universe"

   in   goParse (fragmentLexExp frag srcName srcLine str)


-- kind ------------------------------------------------------------------------
-- | Show the kind of a type.
cmdShowKind :: Bundle -> Source -> String -> IO ()
cmdShowKind bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp frag srcName srcLine str
        eTK     = loadType (fragmentProfile frag) srcName toks
   in   case eTK of
         Left err       -> outDocLn $ ppr err
         Right (t, k)   -> outDocLn $ ppr t <+> text "::" <+> ppr k


-- tequiv ---------------------------------------------------------------------
-- | Check if two types are equivlant.
cmdTypeEquiv :: Bundle -> Source -> String -> IO ()
cmdTypeEquiv bundle source ss
 | Bundle frag _ _ _ _ <- bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        
        goParse toks
         = case BP.runTokenParser describeTok (nameOfSource source)
                        (do t1 <- pTypeAtom
                            t2 <- pTypeAtom
                            return (t1, t2))
                        toks
            of Left err -> outDocLn $ text "parse error " <> ppr err
               Right tt -> goEquiv tt
         
        goEquiv (t1, t2)
         = do   b1 <- checkT t1
                b2 <- checkT t2
                if b1 && b2 
                 then outStrLn $ show $ equivT t1 t2    
                 else return ()

        defs    = profilePrimDataDefs (fragmentProfile frag)
        kenv    = profilePrimKinds    (fragmentProfile frag)

        checkT t
         = case T.checkType defs kenv (spreadT kenv t) of
                Left err 
                 -> do  outDocLn $ ppr err
                        return False

                Right{} 
                 ->     return True

   in goParse (fragmentLexExp frag srcName srcLine ss)


-- wtype ----------------------------------------------------------------------
-- | Show the type of a witness.
cmdShowWType :: Bundle -> Source -> String -> IO ()
cmdShowWType bundle source str
 | Bundle frag _ _ _ _ <- bundle
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp frag srcName srcLine str
        eTK     = loadWitness (fragmentProfile frag) srcName toks
   in   case eTK of
         Left err       -> outDocLn $ ppr err
         Right (t, k)   -> outDocLn $ ppr t <+> text "::" <+> ppr k


-- check / type / effect / closure --------------------------------------------
-- | What components of the checked type to display.
data ShowTypeMode
        = ShowTypeAll
        | ShowTypeValue
        | ShowTypeEffect
        | ShowTypeClosure
        deriving (Eq, Show)


-- | Show the type of an expression.
cmdShowType :: Bundle -> ShowTypeMode -> Source -> String -> IO ()
cmdShowType bundle mode source ss
 | Bundle frag modules _ _ _ <- bundle
 = cmdParseCheckExp frag modules True source ss >>= goResult
 where
        goResult Nothing
         = return ()

        goResult (Just (x, t, eff, clo))
         = case mode of
                ShowTypeAll
                 -> do  outDocLn $ ppr x
                        outDocLn $ text ":*: " <+> ppr t
                        outDocLn $ text ":!:" <+> ppr eff
                        outDocLn $ text ":$:" <+> ppr clo
        
                ShowTypeValue
                 ->     outDocLn $ ppr x <+> text "::" <+> ppr t
        
                ShowTypeEffect
                 ->     outDocLn $ ppr x <+> text ":!" <+> ppr eff

                ShowTypeClosure
                 ->     outDocLn $ ppr x <+> text ":$" <+> ppr clo


-- Recon ----------------------------------------------------------------------
-- | Check expression and reconstruct type annotations on binders.
cmdExpRecon :: Bundle -> Source -> String -> IO ()
cmdExpRecon bundle source ss
 |   Bundle frag modules _ _ _ <- bundle
 =   cmdParseCheckExp frag modules True source ss 
 >>= goResult
 where
        goResult Nothing
         = return ()

        goResult (Just (x, _, _, _))
         = outDocLn $ ppr x


-- Check ----------------------------------------------------------------------
-- | Parse a core type, and check its kind.
cmdParseCheckType 
        :: (Ord n, Show n, Pretty n)
        => Source
        -> Fragment n err
        -> String 
        -> IO (Maybe (Type n, Kind n))

cmdParseCheckType source frag str
 = let  srcName = nameOfSource source
        srcLine = lineStartOfSource source
        toks    = fragmentLexExp frag srcName srcLine str
        eTK     = loadType (fragmentProfile frag) srcName toks
   in   case eTK of
         Left err       
          -> do outDocLn $ ppr err
                return Nothing

         Right (t, k)
          ->    return $ Just (t, k)


-- | Parse and type-check the given core module.
cmdParseCheckModule 
        :: (Ord n, Show n, Pretty n, Pretty (err (AnTEC () n)))
        => Fragment n err
        -> Source
        -> String
        -> IO (Maybe (Module (AnTEC () n) n))

cmdParseCheckModule frag source str
 = goLoad (fragmentLexModule frag 
                (nameOfSource source) (lineStartOfSource source) str)
 where
        -- Parse and type-check the module.
        goLoad toks
         = case loadModule (fragmentProfile frag) (nameOfSource source) toks of
                Left err
                 -> do  outDocLn $ ppr err
                        return Nothing

                Right result
                 -> do  goCheckFragment result

        goCheckFragment m
         = case fragmentCheckModule frag m of
                Just err
                 -> do outDocLn $ ppr err
                       return Nothing

                Nothing
                 ->     return (Just m)


-- | Parse the given core expression, 
--   and return it, along with its type, effect and closure.
--
--   If the expression had a parse error, undefined vars, or type error
--   then print this to the console.
--
--   We include a flag to override the language profile to allow partially
--   applied primitives. Although a paticular evaluator (or backend) may not
--   support partially applied primitives, we want to accept them if we are
--   only loading an expression to check its type.
--
cmdParseCheckExp 
        :: (Ord n, Show n, Pretty n, Pretty (err (AnTEC () n)))
        => Fragment n err       -- ^ The current language fragment.
        -> ModuleMap (AnTEC () n) n -- ^ Current modules
        -> Bool                 -- ^ Allow partial application of primitives.
        -> Source               -- ^ Where this expression was sourced from.
        -> String               -- ^ Text to parse.
        -> IO (Maybe ( Exp (AnTEC () n) n
                     , Type n, Effect n, Closure n))

cmdParseCheckExp frag modules permitPartialPrims source str
 = goLoad (fragmentLexExp frag (nameOfSource source) (lineStartOfSource source) str)
 where
        -- Override profile to allow partially applied primitives if we were
        -- told to do so.
        profile   = fragmentProfile frag
        features  = profileFeatures profile
        features' = features { featuresPartialPrims 
                             = featuresPartialPrims features || permitPartialPrims}
        profile'  = profile  { profileFeatures  = features' }
        frag'     = frag     { fragmentProfile  = profile'  }

        -- Parse and type check the expression.
        goLoad toks
         = case loadExp (fragmentProfile frag') modules (nameOfSource source) toks of
              Left err
               -> do    putStrLn $ renderIndent $ ppr err
                        return Nothing

              Right result
               -> goCheckFragment result

        -- Do fragment specific checks.
        goCheckFragment (x, t, e, c)
         = case fragmentCheckExp frag' x of
             Just err 
              -> do     putStrLn $ renderIndent $ ppr err
                        return Nothing

             Nothing  
              -> do     return (Just (x, t, e, c))