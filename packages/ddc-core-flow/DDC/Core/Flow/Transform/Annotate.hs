
module DDC.Core.Flow.Transform.Annotate
        (Annotate (..))
where
import qualified DDC.Core.Exp.Annot             as A
import qualified DDC.Core.Flow.Exp.Simple.Exp   as S


-- | Convert the `Simple` version of the AST to the `Annot` version,
--   using a the provided default annotation value.
class Annotate  
        (c1 :: * -> * -> *) 
        (c2 :: * -> * -> *) | c1 -> c2 
 where
 annotate :: a -> c1 a n -> c2 a n


instance Annotate S.Exp A.Exp where
 annotate def xx
  = let down     = annotate def
    in case xx of
        S.XAnnot _ (S.XAnnot a x)       -> down (S.XAnnot a x)
        S.XAnnot a (S.XVar   u)         -> A.XVar      a u
        S.XAnnot a (S.XPrim  p)         -> A.XPrim     a p
        S.XAnnot a (S.XCon   dc)        -> A.XCon      a dc
        S.XAnnot a (S.XLAM   b x)       -> A.XLAM      a b   (down x)
        S.XAnnot a (S.XLam   b x)       -> A.XLam      a b   (down x)
        S.XAnnot a (S.XApp   x1 x2)     -> A.XApp      a     (down x1)  (annotateArg def x2)
        S.XAnnot a (S.XLet   lts x)     -> A.XLet      a     (down lts) (down x)
        S.XAnnot a (S.XCase  x alts)    -> A.XCase     a     (down x)   (map down alts)
        S.XAnnot a (S.XCast  c x)       -> A.XCast     a     (down c)   (down x)
        S.XAnnot a x'                   -> annotate a x'

        S.XVar  u                       -> A.XVar      def u
        S.XPrim p                       -> A.XPrim     def p
        S.XCon  dc                      -> A.XCon      def dc
        S.XLAM  b x                     -> A.XLAM      def b (down x)
        S.XLam  b x                     -> A.XLam      def b (down x)
        S.XApp  x1 x2                   -> A.XApp      def   (down x1)  (annotateArg def x2)
        S.XLet  lts x                   -> A.XLet      def   (down lts) (down x)
        S.XCase x alts                  -> A.XCase     def   (down x)   (map down alts)
        S.XCast c x                     -> A.XCast     def   (down c)   (down x)

        S.XType    _                    -> error "ddc-core-flow.annotate: naked Xtype"
        S.XWitness _                    -> error "ddc-core-flow.annotate: naked Xwitness"


annotateArg def xx
  = case xx of
        S.XType t                       -> A.RType t
        S.XWitness w                    -> A.RWitness (annotate def w)
        _                               -> A.RTerm    (annotate def xx)


instance Annotate S.Cast A.Cast where
 annotate def cc
  = let down    = annotate def
    in case cc of
        S.CastWeakenEffect eff          -> A.CastWeakenEffect  eff
        S.CastPurify w                  -> A.CastPurify        (down w)
        S.CastBox                       -> A.CastBox
        S.CastRun                       -> A.CastRun


instance Annotate S.Lets A.Lets where
 annotate def lts
  = let down    = annotate def
    in case lts of
        S.LLet b x                      -> A.LLet b (down x)
        S.LRec bxs                      -> A.LRec [(b, down x) | (b, x) <- bxs]
        S.LPrivate bks mT bts           -> A.LPrivate bks mT bts


instance Annotate S.Alt A.Alt where
 annotate def alt
  = let down    = annotate def
    in case alt of
        S.AAlt S.PDefault x             -> A.AAlt  A.PDefault (down x)
        S.AAlt (S.PData dc bs) x        -> A.AAlt (A.PData dc bs) (down x)


instance Annotate S.Witness A.Witness where
 annotate def wit
  = let down    = annotate def
    in case wit of
        S.WAnnot _ (S.WAnnot a x)       -> down (S.WAnnot a x)
        S.WAnnot a (S.WVar  u)          -> A.WVar  a u
        S.WAnnot a (S.WCon  wc)         -> A.WCon  a wc
        S.WAnnot a (S.WApp  w1 w2)      -> A.WApp  a (down w1) (down w2)
        S.WAnnot a (S.WType t)          -> A.WType a t

        S.WVar  u                       -> A.WVar  def u
        S.WCon  dc                      -> A.WCon  def dc        
        S.WApp  x1 x2                   -> A.WApp  def (down x1) (down x2)
        S.WType t                       -> A.WType def t


