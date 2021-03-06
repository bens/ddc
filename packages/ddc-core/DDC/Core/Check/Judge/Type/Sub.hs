
module DDC.Core.Check.Judge.Type.Sub
        (checkSub)
where
import DDC.Core.Check.Judge.Type.Base
import qualified DDC.Core.Env.EnvT      as EnvT
import qualified DDC.Type.Sum           as Sum
import qualified Data.Map               as Map


-- This is the subtyping rule for the type checking judgment.
checkSub table !a ctx0 demand xx0 tExpect
 = do   
        ctrace  $ vcat 
                [ text "*>  Sub Check"
                , text "    demand:  " <> (text $ show demand)
                , text "    tExpect: " <> (ppr tExpect) 
                , indent 4 $ ppr ctx0
                , empty ]

        let config      = tableConfig table

        -- Synthesise a type for the expression.
        (xx1, tSynth, effs1, ctx1)
         <- tableCheckExp table table
                ctx0 (Synth $ slurpExists tExpect)
                demand xx0 

        -- Substitute context into synthesised and expected types.
        tSynth_ctx1     <- applyContext ctx1 tSynth
        tExpect_ctx1    <- applyContext ctx1 tExpect

        -- If the synthesised type is not quantified,
        -- but the expected one is then instantiate it at some new existentials.
        -- The expected type needs to be an existential so we know where to 
        -- insert the new existentials we create into the context.
        (xx_dequant, tDequant, ctx2)
         <- case takeExists tExpect of
                Just iExpect
                 -> dequantify table a ctx1 iExpect xx1 tSynth_ctx1 tExpect_ctx1

                Nothing
                 -> return (xx1, tSynth_ctx1, ctx1)

        ctrace  $ vcat
                [ text "*.  Sub Check"
                , text "    demand:   " <> (text $ show demand)
                , text "    tExpect:  " <> ppr tExpect_ctx1
                , text "    tSynth:   " <> ppr tSynth_ctx1
                , text "    tDequant: " <> ppr tDequant
                , empty ]

        -- Make the synthesised type a subtype of the expected one.
        (xx2, effs3, ctx3)
         <- makeSub config a ctx2 xx0 xx_dequant tDequant tExpect_ctx1
         $  ErrorMismatch  a tDequant tExpect_ctx1 xx0

        let effs' = Sum.union effs1 effs3

        ctrace  $ vcat
                [ text "*<  Sub"
                , indent 4 $ ppr xx0
                , text "    tExpect:  " <> ppr tExpect
                , text "    tSynth:   " <> ppr tSynth
                , text "    tDequant: " <> ppr tDequant
                , text "    tExpect': " <> ppr tExpect_ctx1
                , text "    tSynth':  " <> ppr tSynth_ctx1
                , indent 4 $ ppr ctx0
                , indent 4 $ ppr ctx1
                , indent 4 $ ppr ctx3
                , empty ]

        returnX a
                (\_ -> xx2)
                tExpect
                effs' ctx3


dequantify !_table !aApp ctx0 iBefore xx0 tSynth tExpect 
 | TCon (TyConExists _n _k)  <- tExpect
 , shouldDequantifyX xx0
 = do   
        (bsParam, tBody)     <- stripQuantifiers ctx0 tSynth
        case bsParam of
         []     -> return (xx0, tSynth, ctx0)
         _      -> addTypeApps aApp ctx0 iBefore xx0 (reverse bsParam) tBody

 | otherwise
 = return (xx0, tSynth, ctx0)


shouldDequantifyX :: Exp a n -> Bool
shouldDequantifyX xx
 = case xx of
        XLAM{}  -> False
        _       -> True


-- | Apply the given expression to existentials to instantiate its type.
--
--   The new existentials are inserted into the context just before
--   the given one so that the context scoping works out.
--
addTypeApps 
        :: Ord n
        => a                    -- ^ Annotation for new AST nodes.
        -> Context n            -- ^ Current type checker context.
        -> Exists n             -- ^ Add new existentials before this one.
        -> Exp (AnTEC a n) n    -- ^ Expression to add type applications to.
        -> [Bind n]             -- ^ Forall quantifiers.
        -> Type n               -- ^ Body of the forall.
        -> CheckM a n 
                ( Exp (AnTEC a n) n
                , Type n
                , Context n)

addTypeApps !_aApp ctx0 _ xx0 [] tBody
 = return (xx0, tBody, ctx0)

addTypeApps !aApp  ctx0 iBefore xx0 (bParam : bsParam) tBody
 = do   
        let kParam = typeOfBind bParam

        (xx1, tBody', ctx1)
         <- addTypeApps aApp ctx0 iBefore xx0 bsParam tBody 

        iArg        <- newExists kParam
        let tArg    =  typeOfExists iArg
        let ctx2    =  pushExistsBefore iArg iBefore ctx1

        let tResult =  substituteT bParam tArg tBody'

        let aApp'   = AnTEC tResult (tBot kEffect) (tBot kClosure) aApp
        let xx2     = XApp aApp' xx1 (RType tArg)

        return (xx2, tResult, ctx2)


-- | Strip quantifiers from the front of a type, looking through any type synonyms.
--
--   ISSUE #385: Make type inference work for non trivial type synonyms.
--   If the synonym is higher kinded then we need to reduce the application.
--   trying to strip the TForall.
--
stripQuantifiers 
        :: Ord n 
        => Context n
        -> Type n 
        -> CheckM a n ([Bind n], Type n)

stripQuantifiers ctx tt
 = case tt of
        -- Look through type synonyms.
        TCon (TyConBound (UName n) _)
         | Just tt' <- Map.lookup n 
                    $  EnvT.envtEquations $ contextEnvT ctx
         -> stripQuantifiers ctx tt'

        -- Strip quantifier.
        TForall bParam tBody
         -> do  (bsParam, tBody')
                 <- stripQuantifiers ctx tBody
                return (bParam : bsParam, tBody')

        _ ->    return ([], tt)


