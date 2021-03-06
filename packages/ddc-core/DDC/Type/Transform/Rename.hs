
-- | Renaming of variable binders to anonymous form to avoid capture.
module DDC.Type.Transform.Rename
        ( Rename(..)

        -- * Substitution states
        , Sub(..)

        -- * Binding stacks
        , BindStack(..)
        , pushBind
        , pushBinds
        , substBound

        -- * Rewriting binding occurences
        , bind1, bind1s, bind0, bind0s

        -- * Rewriting bound occurences
        , use1,  use0)
where
import DDC.Type.Exp.Simple
import Data.List
import Data.Set                         (Set)
import qualified DDC.Type.Sum           as Sum
import qualified Data.Set               as Set


-------------------------------------------------------------------------------
class Rename (c :: * -> *) where
 -- | Rewrite names in some thing to anonymous form if they conflict with
--    any names in the `Sub` state. We use this to avoid variable capture
--    during substitution.
 renameWith :: Ord n => Sub n -> c n -> c n 


instance Rename Type where
 renameWith sub tt 
  = {-# SCC renameWith #-}
    let down    = renameWith 
    in case tt of
        TVar u          -> TVar (use1 sub u)

        TCon{}          -> tt

        TAbs b t
         -> let (sub1, b')      = bind1 sub b
                t'              = down  sub1 t
            in  TAbs b' t'

        TApp t1 t2      -> TApp (down sub t1) (down sub t2)

        TForall b t
         -> let (sub1, b')      = bind1 sub b
                t'              = down  sub1 t
            in  TForall b' t'

        TSum ts         -> TSum (down sub ts)


instance Rename TypeSum where
 renameWith sub ts
        = Sum.fromList (Sum.kindOfSum ts)
        $ map (renameWith sub)
        $ Sum.toList ts


instance Rename Bind where
 renameWith sub bb
  = replaceTypeOfBind  (renameWith sub (typeOfBind bb))  bb


-------------------------------------------------------------------------------
-- | Substitution state.
--   Keeps track of the binders in the environment that have been rewrittten
--   to avoid variable capture or spec binder shadowing.
data Sub n
        = Sub
        { -- | Bound variable that we're substituting for.
          subBound      :: !(Bound n)

          -- | We've decended past a binder that shadows the one that we're
          --   substituting for. We're no longer substituting, but still may
          --   need to anonymise variables in types. 
          --   This can only happen for level-0 named binders.
        , subShadow0    :: !Bool 

          -- | Level-1 names that need to be rewritten to avoid capture.
        , subConflict1  :: !(Set n)

          -- | Level-0 names that need to be rewritten to avoid capture.
        , subConflict0  :: !(Set n)

          -- | Rewriting stack for level-1 names.
        , subStack1     :: !(BindStack n)

          -- | Rewriting stack for level-0 names.
        , subStack0     :: !(BindStack n)  }


-- | Stack of anonymous binders that we've entered under during substitution. 
data BindStack n
        = BindStack
        { -- | Holds anonymous binders that were already in the program,
          --   as well as named binders that are being rewritten to anonymous ones.
          --   In the resulting expression all these binders will be anonymous.
          stackBinds    :: ![Bind n]

          -- | Holds all binders, independent of whether they are being rewritten or not.
        , stackAll      :: ![Bind n] 

          -- | Number of `BAnon` in `stackBinds`.
        , stackAnons    :: !Int

          -- | Number of `BName` in `stackBinds`.
        , stackNamed    :: !Int }


-- | Push several binds onto the bind stack,
--   anonymyzing them if need be to avoid variable capture.
pushBinds :: Ord n => Set n -> BindStack n -> [Bind n]  -> (BindStack n, [Bind n])
pushBinds fns stack bs
        = mapAccumL (pushBind fns) stack bs


-- | Push a bind onto a bind stack, 
--   anonymizing it if need be to avoid variable capture.
pushBind
        :: Ord n
        => Set n                  -- ^ Names that need to be rewritten.
        -> BindStack n            -- ^ Current bind stack.
        -> Bind n                 -- ^ Bind to push.
        -> (BindStack n, Bind n)  -- ^ New stack and possibly anonymised bind.

pushBind fns bs@(BindStack stack env dAnon dName) bb
 = case bb of
        -- Push already anonymous bind on stack.
        BAnon t                 
         -> ( BindStack (BAnon t   : stack) (BAnon t : env) (dAnon + 1) dName
            , BAnon t)
            
        -- If the binder needs to be rewritten then push the original name on the
        -- 'stackBinds' to remember this.
        BName n t
         | Set.member n fns     
         -> ( BindStack (BName n t : stack) (BAnon t : env)  dAnon       (dName + 1)
            , BAnon t)

         | otherwise
         -> ( BindStack stack               (BName n t : env) dAnon dName
            , bb)

        -- Binder was a wildcard.
        _ -> (bs, bb)



-- | Compare a `Bound` against the one we're substituting for.
substBound
        :: Ord n
        => BindStack n      -- ^ Current Bind stack during substitution.
        -> Bound n          -- ^ Bound we're substituting for.
        -> Bound n          -- ^ Bound we're looking at now.
        -> Either 
                (Bound n)   --   Bound doesn't match, but replace with this one.
                Int         --   Bound matches, drop the thing being substituted and 
                            --   and lift indices this many steps.

substBound (BindStack binds _ dAnon dName) u u'
        -- Bound name matches the one that we're substituting for.
        | UName n1      <- u
        , UName n2      <- u'
        , n1 == n2
        = Right (dAnon + dName)

        -- Bound index matches the one that we're substituting for.
        | UIx  i1       <- u
        , UIx  i2       <- u'
        , i1 + dAnon == i2 
        = Right (dAnon + dName)

        -- The Bind for this name was rewritten to avoid variable capture,
        -- so we also have to update the bound occurrence.
        | UName _       <- u'
        , Just ix       <- findIndex (boundMatchesBind u') binds
        = Left $ UIx ix

        -- Bound index doesn't match, but lower this index by one to account
        -- for the removal of the outer binder.
        | UIx  i2       <- u'
        , i2 > dAnon
        , cutOffset     <- case u of
                                UIx{}   -> 1
                                _       -> 0
        = Left $ UIx (i2 + dName - cutOffset)

        -- Some name that didn't match.
        | otherwise
        = Left u'


-------------------------------------------------------------------------------
-- | Push a level-1 binder on the rewrite stack.
bind1 :: Ord n => Sub n -> Bind n -> (Sub n, Bind n)
bind1 sub b 
 = let  (stackT', b')     = pushBind (subConflict1 sub) (subStack1 sub) b
   in   (sub { subStack1  = stackT' }, b')


-- | Push some level-1 binders on the rewrite stack.
bind1s :: Ord n => Sub n -> [Bind n] -> (Sub n, [Bind n])
bind1s = mapAccumL bind1


-- | Push a level-0 binder on the rewrite stack.
bind0 :: Ord n => Sub n -> Bind n -> (Sub n, Bind n)
bind0 sub b 
 = let  b1                  = renameWith sub b
        (stackX', b2)       = pushBind (subConflict0 sub) (subStack0 sub) b1
   in   ( sub { subStack0   = stackX'
              , subShadow0  =  subShadow0 sub 
                            || namedBoundMatchesBind (subBound sub) b2 }
        , b2)


-- | Push some level-0 binders on the rewrite stack.
bind0s :: Ord n => Sub n -> [Bind n] -> (Sub n, [Bind n])
bind0s = mapAccumL bind0


-- | Rewrite the use of a level-1 binder if need be.
use1 :: Ord n => Sub n -> Bound n -> Bound n
use1 sub u
        | UName _               <- u
        , BindStack binds _ _ _ <- subStack1 sub
        , Just ix               <- findIndex (boundMatchesBind u) binds
        = UIx ix

        | otherwise
        = u


-- | Rewrite the use of a level-0 binder if need be.
use0 :: Ord n => Sub n -> Bound n -> Bound n
use0 sub u
        | UName _               <- u
        , BindStack binds _ _ _ <- subStack0 sub
        , Just ix               <- findIndex (boundMatchesBind u) binds
        = UIx ix

        | otherwise
        = u

