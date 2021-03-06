
-- | Single step evaluation of primitive operators and constructors.
---
--   This should implements the proper operational semantics of the core language,
--   so we're careful to check all premises of the evaluation rules are satisfied.
module DDC.Core.Eval.Prim
        ( stepPrimCon
        , stepPrimOp
        , primNewRegion
        , primDelRegion)
where
import DDC.Core.Eval.Compounds
import DDC.Core.Eval.Store
import DDC.Core.Eval.Name
import DDC.Core.Exp
import qualified DDC.Core.Eval.Store   as Store


-------------------------------------------------------------------------------
-- | Step a primitive constructor, which allocates an object in the store.
stepPrimCon
        :: DaCon Name           -- ^ Data constructor to evaluate.
        -> [Exp () Name]        -- ^ Arguments to constructor.
        -> Store                -- ^ Current store.
        -> Maybe ( Store        
                 , Exp () Name) -- ^ New store and result expression, 
                                --   if the operator steps, otherwise `Nothing`.

-- Redirect the unit constructor.
-- All unit values point to the same object in the store.
stepPrimCon dc xsArgs store
        | DaConUnit     <- dc
        , []            <- xsArgs
        = Just  ( store
                , xLoc locUnit tUnit )


stepPrimCon dc xsArgs store

    ------ Alloction of Ints ----------------------------------------
        | Just _        <- takeIntDC dc
        , [xR, xUnit']  <- xsArgs

        -- unpack the args
        , XType _ tR    <- xR
        , Just rgn      <- takeHandleT tR
        , isUnitOrLocX xUnit'

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store.
        , (store1, l)   <- Store.allocBind rgn 
                                (tInt tR) (SObj dc []) store

        = Just  ( store1
                , xLoc l (tInt tR))


    ------ Handle Pair specially until we have general data types --
        | Just (NamePrimCon PrimDaConPr) <- takeNameOfDaCon dc
        , [xR, xA, xB, x1, x2]           <- xsArgs
        
        -- unpack the args
        , XType _ tR    <- xR
        , Just    rgn   <- takeHandleT tR
        , XType _ tA    <- xA
        , XType _ tB    <- xB
        , Just    l1    <- takeLocX x1
        , Just    l2    <- takeLocX x2

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store
        , (store1, l)   <- Store.allocBind rgn
                                (tPair tR tA tB) (SObj dc [l1, l2]) store

        = Just  ( store1
                , xLoc l (tPair tR tA tB))


    ---- Handle Nil and Cons specially until we have general data types.
        | Just (NamePrimCon PrimDaConNil) <- takeNameOfDaCon dc
        , [xR, xA, xUnit']                <- xsArgs

        -- unpack the args
        , XType _ tR    <- xR
        , Just  rgn     <- takeHandleT tR
        , XType _ tA    <- xA
        , isUnitOrLocX xUnit'

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store
        , (store1, l)   <- Store.allocBind rgn
                                (tList tR tA) (SObj dc []) store
        = Just  ( store1
                , xLoc l (tList tR tA))


        | Just (NamePrimCon PrimDaConCons) <- takeNameOfDaCon dc
        , [xR, xA, xHead, xTail]           <- xsArgs

        -- unpack the args
        , XType _ tR    <- xR
        , Just rgn      <- takeHandleT tR
        , XType _ tA    <- xA
        , Just lHead    <- takeLocX xHead
        , Just lTail    <- takeLocX xTail

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store
        , (store1, l)   <- Store.allocBind rgn
                                (tList tR tA) (SObj dc [lHead, lTail]) store

        = Just  ( store1
                , xLoc l (tList tR tA))

stepPrimCon _ _ _
        = Nothing


-------------------------------------------------------------------------------
-- | Step a primitive operator.
stepPrimOp
        :: Name                 -- ^ Name of operator to evaluate.
        -> [Exp () Name]        -- ^ Arguments to operator.
        -> Store                -- ^ Current store.
        -> Maybe ( Store        
                 , Exp () Name) -- ^ New store and result expression, 
                                --   if the operator steps, otherwise `Nothing`.

-- Binary integer primop.
stepPrimOp (NamePrimOp op) [xR1, xR2, xR3, xL1, xL2] store
        -- unpack the args
        | Just fOp      <- lookup op 
                                [ (PrimOpAddInt, (+))
                                , (PrimOpSubInt, (-))
                                , (PrimOpMulInt, (*))
                                , (PrimOpDivInt, div) 
                                , (PrimOpEqInt,  (\x y -> if x == y then 1 else 0))]
        , Just r1       <- takeHandleX xR1
        , Just r2       <- takeHandleX xR2
        , XType _ tR3   <- xR3
        , Just r3       <- takeHandleX xR3        
        , Just l1       <- stripLocX xL1
        , Just l2       <- stripLocX xL2

        -- get the regions and values of each location
        , Just (r1', _, SObj dc1 [])    <- Store.lookupRegionTypeBind l1 store
        , Just i1                       <- takeIntDC dc1

        , Just (r2', _, SObj dc2 [])    <- Store.lookupRegionTypeBind l2 store
        , Just i2                       <- takeIntDC dc2
        
        -- the locations must be in the regions the args said they were in
        , r1' == r1
        , r2' == r2
        
        -- the destination region must exist
        , Store.hasRgn store r3

        -- do the actual computation
        , i3    <- i1 `fOp` i2
        
        -- write the result to a new location in the store
        , (store1, l3)  <- Store.allocBind r3 (tInt tR3) 
                                (SObj (dcInt i3) []) 
                                store

        = Just  ( store1
                , xLoc l3 (tInt tR3))


-- Update integer primop.
stepPrimOp (NamePrimOp PrimOpUpdateInt) [xR1, xR2, xMutR1, xL1, xL2] store
        -- unpack the args
        | Just r1       <- takeHandleX  xR1
        , Just r2       <- takeHandleX  xR2
        , Just r1W      <- takeMutableX xMutR1
        , Just l1       <- stripLocX     xL1
        , Just l2       <- stripLocX     xL2      

        -- the witness must be for the destination region
        , r1W == r1

        -- get the regions and values of each location
        , Just (r1L, tX1, SObj dc1 [])  <- Store.lookupRegionTypeBind l1 store
        , Just _i1                      <- takeIntDC dc1

        , Just (r2L, _,   SObj dc2 [])  <- Store.lookupRegionTypeBind l2 store
        , Just i2                       <- takeIntDC dc2

        -- the locations must be in the regions the args said they were in
        , r1L == r1
        , r2L == r2

        -- update the destination
        , store1        <- Store.addBind l1 r1 tX1 (SObj (dcInt i2) []) store
        = Just  ( store1
                , xUnit ())

-- Unary integer operations
stepPrimOp (NamePrimOp op) [xR1, xR2, xL1] store
        -- unpack the args
        | Just fOp      <- lookup op
                                [ (PrimOpCopyInt, id)
                                , (PrimOpNegInt,  negate) ]
        , Just r1       <- takeHandleX  xR1
        , XType _ tR2   <- xR2
        , Just r2       <- takeHandleX  xR2
        , Just l1       <- stripLocX    xL1

        -- get the region and value of the int
        , Just (r1L, _, SObj dc1  [])   <- Store.lookupRegionTypeBind l1 store
        , Just i1                       <- takeIntDC dc1

        -- the locations must be in the regions the args said they were in
        , r1L == r1

        -- the destination region must exist
        , Store.hasRgn store r2

        -- calculate
        , i2           <- fOp i1

        -- write the result to a new location in the store
        , (store1, l2)  <- Store.allocBind r2 (tInt tR2) (SObj (dcInt i2) []) store

        = Just  ( store1
                , xLoc l2 (tInt tR2))

stepPrimOp _ _ _
        = Nothing


-- Store ----------------------------------------------------------------------
-- | Like `Store.newRgn` but return the region handle wrapped in a `Bound`.
primNewRegion :: Store -> (Store, Bound Name)
primNewRegion store
 = let  (store', rgn)   = Store.newRgn store
        u               = UPrim (NameRgn rgn) kRegion
   in   (store', u)


-- | Like `Store.delRgn` but accept a region handle wrapped in a `Bound`.
primDelRegion :: Bound Name -> Store -> Maybe Store
primDelRegion uu store
 = case uu of
        UPrim (NameRgn rgn) _   -> Just $ Store.delRgn rgn store
        _                       -> Nothing

