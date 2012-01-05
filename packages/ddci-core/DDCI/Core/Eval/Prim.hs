
-- | Single step evaluation of primitive operators and constructors.
-- 
--   This should implements the proper operational semantics of the core language,
--   so we're careful to check all premises of the evaluation rules are satisfied.
module DDCI.Core.Eval.Prim
        ( stepPrimCon
        , stepPrimOp
        , primNewRegion
        , primDelRegion)
where
import DDCI.Core.Eval.Compounds
import DDCI.Core.Eval.Store
import DDCI.Core.Eval.Name
import DDC.Core.Exp
import qualified DDCI.Core.Eval.Store   as Store


-------------------------------------------------------------------------------
-- | Single step a primitive constructor.
stepPrimCon
        :: Name                 -- ^ Name of constructor to allocate.
        -> [Exp () Name]        -- ^ Arguments to constructor.
        -> Store                -- ^ Current store.
        -> Maybe ( Store        
                 , Exp () Name) -- ^ New store and result expression, 
                                --   if the operator steps, otherwise Nothing.

-- Alloction of Ints.
stepPrimCon (NameInt i) [xR, xUnit] store
        -- unpack the args
        | XType tR      <- xR
        , Just rgn      <- takeHandleT tR
        , isUnitX xUnit

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store.
        , (store1, l)   <- Store.allocBind rgn (tInt tR) (SObj (NameInt i) []) store

        = Just  ( store1
                , XCon () (UPrim (NameLoc l) (tInt tR)))


-- Handle Nil and Cons specially until we have general data types.
stepPrimCon n@(NamePrimCon PrimDaConNil) [xR, xA, xUnit] store
        -- unpack the args
        | XType tR      <- xR
        , Just rgn      <- takeHandleT tR
        , XType tA      <- xA
        , isUnitX xUnit

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store
        , (store1, l)   <- Store.allocBind rgn (tList tR tA) (SObj n []) store

        = Just  ( store1
                , XCon () (UPrim (NameLoc l) (tList tR tA)))


stepPrimCon n@(NamePrimCon PrimDaConCons) [xR, xA, xHead, xTail] store
        -- unpack the args
        | XType tR      <- xR
        , Just rgn      <- takeHandleT tR
        , XType tA      <- xA
        , Just lHead    <- takeLocX xHead
        , Just lTail    <- takeLocX xTail

        -- the store must contain the region we're going to allocate into.
        , Store.hasRgn store rgn

        -- add the binding to the store
        , (store1, l)   <- Store.allocBind rgn (tList tR tA) (SObj n [lHead, lTail]) store

        = Just  ( store1
                , XCon () (UPrim (NameLoc l) (tList tR tA)))

stepPrimCon _ _ _
        = Nothing


-------------------------------------------------------------------------------
-- | Single step a primitive operator.
stepPrimOp
        :: Name                 -- ^ Name of operator to evaluate.
        -> [Exp () Name]        -- ^ Arguments to operator.
        -> Store                -- ^ Current store.
        -> Maybe ( Store        
                 , Exp () Name) -- ^ New store and result expression, 
                                --   if the operator steps, otherwise Nothing.

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
        , XType tR3     <- xR3
        , Just r3       <- takeHandleX xR3        
        , Just l1       <- takeLocX xL1
        , Just l2       <- takeLocX xL2

        -- get the regions and values of each location
        , Just (r1', _, SObj (NameInt i1) [])  <- Store.lookupRegionTypeBind l1 store
        , Just (r2', _, SObj (NameInt i2) [])  <- Store.lookupRegionTypeBind l2 store
        
        -- the locations must be in the regions the args said they were in
        , r1' == r1
        , r2' == r2
        
        -- the destination region must exist
        , Store.hasRgn store r3

        -- do the actual computation
        , i3    <- i1 `fOp` i2
        
        -- write the result to a new location in the store
        , (store1, l3)  <- Store.allocBind r3 (tInt tR3) (SObj (NameInt i3) []) store

        = Just  ( store1
                , XCon () (UPrim (NameLoc l3) (tInt tR3)))


-- Unary integer primop.
stepPrimOp (NamePrimOp PrimOpUpdateInt) [xR1, xR2, xMutR1, xL1, xL2] store
        -- unpack the args
        | Just r1       <- takeHandleX  xR1
        , Just r2       <- takeHandleX  xR2
        , Just r1W      <- takeMutableX xMutR1
        , Just l1       <- takeLocX     xL1
        , Just l2       <- takeLocX     xL2      

        -- the witness must be for the destination region
        , r1W == r1

        -- get the regions and values of each location
        , Just (r1L, tX1, SObj (NameInt _)  [])  <- Store.lookupRegionTypeBind l1 store
        , Just (r2L, _,   SObj (NameInt i2) [])  <- Store.lookupRegionTypeBind l2 store

        -- the locations must be in the regions the args said they were in
        , r1L == r1
        , r2L == r2

        -- update the destination
        , store1     <- Store.addBind l1 r1 tX1 (SObj (NameInt i2) []) store

        = Just  ( store1
                , XCon () (UPrim (NamePrimCon PrimDaConUnit) tUnit))

stepPrimOp _ _ _
        = Nothing

