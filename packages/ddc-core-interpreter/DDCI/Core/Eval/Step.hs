
-- | Single step evalation for the DDC core language.
--
--   These are the rules for the plain calculus. The rules for primitive
--   operators and constructors are defined in the interpreter package, 
--   as they depend on the exact representation of the store.
--
module DDCI.Core.Eval.Step 
        ( step
        , isWnf
        , regionWitnessOfType )
where
import DDCI.Core.Eval.Store
import DDCI.Core.Eval.Name
import DDCI.Core.Eval.Prim
import DDCI.Core.Eval.Env
import DDCI.Core.Eval.Compounds
import DDC.Core.Check
import DDC.Core.Transform
import DDC.Core.Compounds
import DDC.Core.Exp
import DDC.Type.Compounds
import DDC.Base.Pretty


-- step -----------------------------------------------------------------------
-- | Perform a single step reduction of a core expression.
step    :: Store                      -- ^ Current store.
        -> Exp () Name                -- ^ Expression to check.
        -> Maybe (Store, Exp () Name) -- ^ New store and expression.

-- TODO: split casts off the front.
step store xx
  = step' store xx


-- (EvPrim): Step a primitive operator or constructor defined by the client.
step' store xx
        | Just (p, xs)          <- takeXPrimApps xx
        , and $ map (isWnf store) xs
        , Just (store', x')     <- stepPrimOp p xs store
        = Just (store', x')


-- (EvLam): Add abstractions to the heap.
-- NOTE: If the abstraction is fully applied we could just reduce its arguments
--       and do the substitution without going via the heap. We only need the
--       heap to store partial applications.
step' store xx@(XLam _ b x)
 = let  (store', l)             = allocBind (Rgn 0) (SLam b x) store

        -- We need the type of the expression to attach to the location
        -- This fakes the store typing from the formal typing rules.
   in   case typeOfExp xx of
         Left err  -> error $ pretty 
                    $ text "step: abstracton is mistyped" <+> line <+> ppr err
         Right t   -> Just (store', XCon () (UPrim (NameLoc l) t))


-- (EvAlloc): Construct some data in the heap.
step' store xx
        | Just (u, xs)          <- takeXConApps xx
        , case u of
            UName NameCon{}     _     -> True
            UPrim NamePrimCon{} _     -> True
            UPrim NameInt{}     _     -> True
            _                         -> False
        , and $ map (isWnf store) xs
        = case u of
                UPrim n _       -> stepPrimCon n xs store
                _               -> error "step': non primitive constructor"


-- (EvAppSubst): Substitute argument into abstraction.
step' store (XApp _ xL1 x2)
        | Just l1                    <- takeLocX xL1
        , Just (Rgn 0, SLam b xBody) <- lookupRegionBind l1 store
        , isWnf store x2
        = case takeSubstBoundOfBind b of
           Nothing -> Just (store, xBody)
           Just u  
            | XType    t2 <- x2 -> Just (store, substituteT u t2 xBody)
            | XWitness w2 <- x2 -> Just (store, substituteW u w2 xBody)
            | otherwise         -> Just (store, substituteX u x2 xBody)


-- (EvApp2): Evaluate the right of an application.
step' store (XApp a x1 x2)
        | isWnf store x1
        , Just (store', x2')    <- step store x2
        = Just (store', XApp a x1 x2')


-- (EvApp1): Evaluate the left of an application.
step' store (XApp a x1 x2)
        | Just (store', x1')    <- step store x1
        = Just (store', XApp a x1' x2)


-- (EvLetSubst): Substitute in a bound value in a let expression.
step' store (XLet _ (LLet b x1) x2)
        | isWnf store x1
        = case takeSubstBoundOfBind b of
           Nothing      -> Just (store, x2)
           Just u       -> Just (store, substituteX u x1 x2)


-- (EvLetStep): Step the binding in a let-expression.
step' store (XLet a (LLet b x1) x2)
        | Just (store', x1')    <- step store x1
        = Just (store', XLet a (LLet b x1') x2)


-- (EvLetRec): Add recursive bindings to the store.
step' store (XLet _ (LRec bxs) x2)
 = let  -- TODO: check this doesn't fail, something.
        -- Maybe drop binding with non-binder.
        (bs, xs)        = unzip bxs
        Just us         = sequence $ map takeSubstBoundOfBind bs
        ts              = map typeOfBind bs

        -- Allocate new locations in the store to hold the expressions.
        (store1, ls)    = newLocs (length us) store
        xls             = [XCon () (UPrim (NameLoc l) t) | (l, t) <- zip ls ts]

        -- Substitute locations into all the bindings.
        xs'             = map (substituteXs (zip us xls)) xs

        -- Create store objects for each of the bindings.
        Just os         = sequence 
                        $ map (\x -> case x of
                                        XLam _ b xBody  -> Just $ SLam b xBody
                                        _               -> Nothing)
                              xs'

        -- Add all the objects to the store.
        store2          = foldr (\(l, o) -> addBind l (Rgn 0) o) store1
                        $ zip ls os
        
        -- Substitute locations into the body expression.
        x2'             = substituteXs (zip us xls) x2
   in   Just (store2, x2')


-- (EvCreateRegion): Create a new region.
step' store (XLet a (LLetRegion bRegion bws) x)
 | Just uRegion <- takeSubstBoundOfBind bRegion
 = let  
        -- Allocation a new region handle for the bound region.
        (store', uHandle) = primNewRegion store
        tHandle = TCon $ TyConBound uHandle

        -- Substitute handle into the witness types.
        bws'    = map (substituteT uRegion tHandle) bws

        -- Build witnesses for each of the witness types.
        uws'    = [(u, t) | Just u <- map takeSubstBoundOfBind bws'
                          | Just t <- map regionWitnessOfType $ map typeOfBind bws']
        
        -- Substitute handle and witnesses into body.
        x'      = substituteT  uRegion tHandle
                $ substituteWs uws' x

   in   Just (store', XLet a (LWithRegion uHandle) x')

 | otherwise
 = Just (store, x)


-- (EvEjectRegion): Eject completed value from the region context, and delete the region.
step' store (XLet _ (LWithRegion r) x)
        | isWnf store x
        , Just store'    <- primDelRegion r store
        = Just (store', x)

 
-- (EvWithRegion): Reduction within a region context.
step' store (XLet a (LWithRegion uRegion) x)
        | Just (store', x')     <- step store x
        = Just (store', XLet a (LWithRegion uRegion) x')


-- (EvCaseMatch): Case branching.
step' store (XCase a xDiscrim alts)
        | Just lDiscrim            <- takeLocX xDiscrim
        , Just (SObj nTag lsArgs)  <- lookupBind lDiscrim store
        , AAlt pat xBody : _       <- filter (tagMatchesAlt nTag) alts
        = case pat of
           PDefault         
            -> Just (store, xBody)

           PData _ bsArgs      
            | tsArgs    <- map typeOfBind bsArgs
            , uxsArgs   <- [ (u, XCon a (UPrim (NameLoc l) t))
                                | l       <- lsArgs
                                | t       <- tsArgs
                                | Just u  <- map takeSubstBoundOfBind bsArgs]
            -> Just ( store
                    , substituteXs uxsArgs xBody)


-- (EvCaseStep): Evaluation of discriminant.
step' store (XCase a xDiscrim alts)
        | Just (store', xDiscrim')      <- step store xDiscrim
        = Just (store', XCase a xDiscrim' alts)


-- (Done/Stuck): Either already a value, or expression is stuck.
step' _ _        
        = Nothing
        

-- | See if a constructor tag matches a case alternative.
tagMatchesAlt :: Name -> Alt a Name -> Bool
tagMatchesAlt n (AAlt p _)
        = tagMatchesPat n p


-- | See if a constructor tag matches a pattern.
tagMatchesPat :: Name -> Pat Name -> Bool
tagMatchesPat _ PDefault        = True
tagMatchesPat n (PData u' _)
 = case takeNameOfBound u' of
        Just n' -> n == n'
        _       -> False

        
-- isWnf ----------------------------------------------------------------------
-- | Check if an expression is a weak normal form (a value).
--   This is not /strong/ normal form because we don't require expressions
--   under lambdas to also be values.
isWnf :: Store -> Exp a Name -> Bool
isWnf store xx
 = case xx of
         XVar{}         -> True
         XCon{}         -> True
         XLam{}         -> False
         XLet{}         -> False
         XCase{}        -> False
         XCast _ _ x    -> isWnf store x
         XType{}        -> True
         XWitness{}     -> True

         XApp _ x1 x2

          | Just (n, xs)     <- takeXPrimApps xx
          , and $ map (isWnf store) xs
          , Just a           <- arityOfName n
          , length xs == a
          -> False

          -- Application of a lambda in the store is not wnf.
          | Just (u, _xs)       <- takeXConApps xx
          , UPrim (NameLoc l) _ <- u
          , Just SLam{}         <- lookupBind l store
          -> False

          | Just (u, xs)     <- takeXConApps xx
          , and $ map (isWnf store) xs
          , UPrim n _        <- u
          , Just a           <- arityOfName n
          , length xs == a   
          -> False

          | otherwise   
          -> isWnf store x1 && isWnf store x2



-- | Get the region witness corresponding to one of the witness types that are
--   permitted in a letregion.
regionWitnessOfType :: Type n -> Maybe (Witness n)
regionWitnessOfType tt
 = case tt of
        TApp (TCon (TyConWitness TwConMutable)) r 
         -> Just $ WApp (WCon (WiConMutable)) (WType r)
        
        TApp (TCon (TyConWitness TwConConst)) r
         -> Just $ WApp (WCon (WiConConst))   (WType r)

        _ -> Nothing

