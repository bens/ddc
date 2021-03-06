
-- | Parser for type expressions.
module DDC.Core.Parser.Type
        ( pKind, pKindAtom
        , pType, pTypeAtom, pTypeApp
        , pBinder
        , pIndex
        , pTok
        , pTokAs)
where
import DDC.Core.Parser.Context
import DDC.Core.Parser.Base
import DDC.Core.Lexer.Tokens   
import DDC.Type.Exp.Simple
import DDC.Control.Parser               ((<?>))
import DDC.Data.Pretty
import qualified DDC.Control.Parser     as P
import qualified DDC.Type.Sum           as TS


---------------------------------------------------------------------------------------------------
-- | Parse a kind.
pKind   :: (Ord n, Pretty n)
        => Context n -> Parser n (Kind n)
pKind c
 = do     pKindFun c
 <?> "a kind"


-- | Parse a function type.
pKindFun 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)

pKindFun c
 = do   t1      <- pKindAtom c
        P.choice 
         [ -- T1 -> T2
           do   pSym    SArrowDashRight
                t2      <- pKindFun c
                return $ t1 `kFun`   t2

           -- Body type
         , do   return t1 ]
 <?> "an atomic kind or kind application"


-- | Parse a variable, constructor or parenthesised type.
pKindAtom 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)
pKindAtom c
 = P.choice
        [ -- (->)
          do    pTok (KOpVar "->")
                return  $ TCon $ TyConKind KiConFun

        -- (TYPE2)
        , do    pSym SRoundBra
                t       <- pKindFun c
                pSym SRoundKet
                return t 

        -- Named type constructors
        , do    ki      <- pKiCon
                return  $ TCon (TyConKind ki)

        , do    tc      <- pTyConNamed
                return  $ TCon tc

        -- Variables (and existentials)
        , do    v       <- pVar
                return  $  TVar (UName v)

        ]
 <?> "an atomic kind"


---------------------------------------------------------------------------------------------------
-- | Parse a type.
pType   :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)

pType c  
 =      pTypeSum c
 <?> "a type"


--  | Parse a type sum.
pTypeSum 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)
pTypeSum c
 = do   t1      <- pTypeForall c
        P.choice 
         [ -- Type sums.
           -- T2 + T3
           do   pTok (KOp "+")
                t2      <- pTypeSum c
                return  $ TSum $ TS.fromList (tBot sComp) [t1, t2]
                
         , do   return t1 ]
 <?> "a type"


-- | Parse a quantified type.
pTypeForall 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)
pTypeForall c
 = P.choice
         [ -- Type abstraction.
           do   pSym SLambda
                bs      <- P.many1 pBinder
                pTok (KOp ":")
                k       <- pKind c
                pSym SDot

                tBody    <- pTypeForall c

                return  $ foldr TAbs tBody 
                        $ map (\b -> makeBindFromBinder b k) bs

           -- Universal quantification.
           -- [v1 v1 ... vn : T1]. T2
         , do   pSym SSquareBra
                bs      <- P.many1 pBinder
                pTok (KOp ":")
                k       <- pKind c
                pSym SSquareKet
                pSym SDot

                body    <- pTypeForall c

                return  $ foldr TForall body 
                        $ map (\b -> makeBindFromBinder b k) bs

           -- Body type
         , do   pTypeFun c]
 <?> "a type"


-- | Parse a function type.
pTypeFun 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)

pTypeFun c
 = do   t1      <- pTypeApp c
        P.choice 
         [ 
           -- T1 -> T2
           do   pSym    SArrowDashRight
                t2      <- pTypeForall c
                return  $ TApp (TApp (TCon (TyConSpec TcConFunExplicit)) t1) t2

           -- T1 ~> T2
         , do   pSym    SArrowTilde
                t2      <- pTypeForall c
                return  $ TApp (TApp (TCon (TyConSpec TcConFunImplicit)) t1) t2

           -- T1 => T2
         , do   pSym    SArrowEquals
                t2      <- pTypeForall c
                return  $ TApp (TApp (TCon (TyConWitness TwConImpl)) t1) t2


           -- Body type
         , do   return t1 ]
 <?> "an atomic type or type application"


-- | Parse a type application.
pTypeApp 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)
pTypeApp c
 = do   (t:ts)  <- P.many1 (pTypeAtom c)
        return  $  foldl TApp t ts
 <?> "an atomic type or type application"


-- | Parse a variable, constructor or parenthesised type.
pTypeAtom 
        :: (Ord n, Pretty n)
        => Context n -> Parser n (Type n)
pTypeAtom c
 = P.choice
        [ -- (=>) Witness implication.
          do    pTok (KOpVar "=>")
                return (TCon $ TyConWitness TwConImpl)

          -- (->) Explicit function type constructor.
        , do    pTok (KOpVar "->")
                return (TCon $ TyConSpec TcConFunExplicit)

          -- (~>) Implicit function type constructor.
        , do    pTok (KOpVar "~>")
                return (TCon $ TyConSpec TcConFunImplicit)

        -- Record type constructors.
        , P.try
           $ do pSym SRoundBra
                ns      <- P.sepBy pVarName (pSym SComma)
                pSym SRoundKet
                pSym SHash
                return  $ TCon (TyConSpec (TcConRecord ns))

        -- The syntax for the nullary record type constructor '()#' overlaps
        -- with that of the unit data construtor '()', so try the former first.
        , P.try
           $ do pTok (KBuiltin BDaConUnit)
                pSym SHash
                return  $ TCon (TyConSpec (TcConRecord []))

        -- (TYPE2)
        , do    pSym SRoundBra
                t       <- pTypeSum c
                pSym SRoundKet
                return t 

        -- Named type constructors
        , do    so      <- pSoCon
                return  $ TCon (TyConSort so)

        , do    ki      <- pKiCon
                return  $ TCon (TyConKind ki)

        , do    tc      <- pTcCon
                return  $ TCon (TyConSpec tc)

        , do    tc      <- pTwCon
                return  $ TCon (TyConWitness tc)

        , do    tc      <- pTyConNamed
                return  $ TCon tc
            
        -- Bottoms.
        , do    pTokAs (KBuiltin BPure)  (tBot kEffect)
        , do    pTokAs (KBuiltin BEmpty) (tBot kClosure)
      
        -- Bound occurrence of a variable.
        --  We don't know the kind of this variable yet, so fill in the
        --  field with the bottom element of computation kinds. This isn't
        --  really part of the language, but makes sense implentation-wise.
        , do    v       <- pVar
                return  $  TVar (UName v)

        , do    i       <- pIndex
                return  $  TVar (UIx i)
        ]
 <?> "an atomic type"


-------------------------------------------------------------------------------
-- | Parse a binder.
pBinder :: (Ord n, Pretty n)
        => Parser n (Binder n)
pBinder
 = P.choice
        -- Named binders.
        [ do    v       <- pVar
                return  $ RName v
                
        -- Anonymous binders.
        , do    pSym    SHat
                return  $ RAnon 
        
        -- Vacant binders.
        , do    pSym    SUnderscore
                return  $ RNone ]
 <?> "a binder"


-------------------------------------------------------------------------------
-- | Parse a builtin sort constructor.
pSoCon :: Parser n SoCon
pSoCon  =   P.pTokMaybe f
        <?> "a sort constructor"
 where f (KA (KBuiltin (BSoCon c))) = Just c
       f _                          = Nothing 


-- | Parse a builtin kind constructor.
pKiCon :: Parser n KiCon
pKiCon  =   P.pTokMaybe f
        <?> "a kind constructor"
 where f (KA (KBuiltin (BKiCon c))) = Just c
       f _                          = Nothing 


-- | Parse a builtin type constructor.
pTcCon :: Parser n TcCon
pTcCon  =   P.pTokMaybe f
        <?> "a type constructor"
 where f (KA (KBuiltin (BTcCon c))) = Just c
       f _                          = Nothing 


-- | Parse a builtin witness type constructor.
pTwCon :: Parser n TwCon
pTwCon  =   P.pTokMaybe f
        <?> "a witness constructor"
 where f (KA (KBuiltin (BTwCon c))) = Just c
       f _                          = Nothing


-- | Parse a user defined type constructor.
pTyConNamed :: Parser n (TyCon n)
pTyConNamed  
        =   P.pTokMaybe f
        <?> "a type constructor"
 where  f (KN (KCon n))          = Just (TyConBound (UName n) (tBot kData))
        f _                      = Nothing

