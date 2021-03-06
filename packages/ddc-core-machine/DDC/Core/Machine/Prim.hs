
module DDC.Core.Machine.Prim
        ( -- * Names and lexing
          Name          (..)
        , readName

          -- * Fragment specific kind constructors
        , KiConMachine  (..)
        , readKiConMachine

          -- * Fragment specific type constructors
        , TyConMachine  (..)
        , readTyConMachine
        , kindTyConMachine

          -- * Fragment specific data constructors
        , DaConMachine (..)
        , readDaConMachine
        , typeDaConMachine

          -- * Fragment specific value primitives
        , OpMachine    (..)
        , readOpMachine
        , typeOpMachine

          -- * Compounds
        , kStatic
        , tTupleN
        , tStream
        , tSource
        , tSink
        , tProcess
        )

where
import DDC.Core.Lexer.Tokens            (isVarStart)
import DDC.Type.Exp.Simple.Exp
import DDC.Type.Exp.Simple.Compounds
import DDC.Data.Name
import DDC.Data.Pretty
import Control.DeepSeq
import Data.Char        
import Data.List
import Data.Typeable


-- | Names of things used in Disciple Core Machine.
-- This is a very small fragment with only the bare minimum of machine, process
-- and streaming types defined.
-- Any actual computation can be imported as foreign values from another fragment.
data Name
        -- | User defined variables.
        = NameVar               String

        -- | A name generated by modifying some other name `name$mod`
        | NameVarMod            Name String

        -- | User defined constructors.
        | NameCon               String

        -- Fragment specific primops -----------
        -- | Fragment specific kind constructors.
        | NameKiConMachine      KiConMachine

        -- | Fragment specific type constructors.
        | NameTyConMachine      TyConMachine

        -- | Fragment specific data constructors.
        | NameDaConMachine      DaConMachine

        -- | Fragment specific value primitives.
        | NameOpMachine         OpMachine

        deriving (Eq, Ord, Show, Typeable)


-- | Fragment specific kind constructors.
data KiConMachine
        -- | @Static@ kind.
        -- The main difference between @Data@ and @Static@ is that @Static@ cannot
        -- be put inside Streams.
        = KiConStatic
        deriving (Eq, Ord, Show)


-- | Fragment specific type constructors.
data TyConMachine
        -- | @Stream# : Data ~> Static@
        -- Streams are abstract and non-polarised, which makes them easy to compose
        -- in a group of combinators, but harder to fuse.
        = TyConStream

        -- | @Sink# : Data ~> Static@
        -- Sinks are polar versions of output streams.
        -- They can always accept items without needing to buffer (but might block).
        | TyConSink

        -- | @Source# : Data ~> Static@
        -- Sources are polar versions of input streams.
        -- You can always ask a Source for a new item (which may block).
        | TyConSource

        -- | @Process# : Static@
        -- Processes perform the computation - copying data from sources to sinks.
        | TyConProcess


        -- | @TupleN# : Data_0 ... ~> Data_N ~> Data @
        | TyConTuple Int
        deriving (Eq, Ord, Show)


-- | Primitive data constructors.
data DaConMachine
        -- | @TN@ data constructor.
        = DaConTuple Int            
        deriving (Eq, Ord, Show)


-- | Machine primops
data OpMachine
        -- | @stream_i_o#@ takes a process function of type
        --      @Source ... -> Sink ... -> Process@
        -- and converts into a stream version that is easier to compose
        --      @Stream ... -> Stream ...@
        = OpStream Int Int

        -- | @process_i_o#@ takes a stream function of type
        --      @Stream ... -> Stream ...@
        -- and converts into a process version that is easier to execute
        --      @Source ... -> Sink ... -> Process@
        | OpProcess Int Int


        -- | @pull#@ pulls from a source and then executes another process
        -- with the pulled value.
        | OpPull

        -- | @push#@ pushes a value to a sink and then executes another process.
        | OpPush

        -- | @drop#@ releases a value previously read from a source.
        -- This release is only for synchronisation between processes.
        | OpDrop
        deriving (Eq, Ord, Show)


instance NFData Name where
 rnf nn
  = case nn of
        NameVar         s       -> rnf s
        NameVarMod      n s     -> rnf n `seq` rnf s
        NameCon         s       -> rnf s

        NameKiConMachine con    -> rnf con
        NameTyConMachine con    -> rnf con
        NameDaConMachine con    -> rnf con
        NameOpMachine   op      -> rnf op

instance NFData KiConMachine where
 rnf !_ = ()
instance NFData TyConMachine where
 rnf !_ = ()
instance NFData OpMachine where
 rnf !_ = ()
instance NFData DaConMachine where
 rnf !_ = ()

instance Pretty Name where
 ppr nn
  = case nn of
        NameVar         s       -> text s
        NameVarMod      n s     -> ppr n <> text "$" <> text s
        NameCon         s       -> text s
        NameKiConMachine con    -> ppr con
        NameTyConMachine con    -> ppr con
        NameDaConMachine con    -> ppr con
        NameOpMachine   op      -> ppr op

instance Pretty KiConMachine where
 ppr con
  = case con of
        KiConStatic -> text "Static"

instance Pretty TyConMachine where
 ppr con
  = case con of
        TyConStream  -> text "Stream#"
        TyConSource  -> text "Source#"
        TyConSink    -> text "Sink#"
        TyConProcess -> text "Process#"
        TyConTuple n -> text "Tuple" <> int n <> text "#"

instance Pretty DaConMachine where
 ppr dc
  = case dc of
        DaConTuple n
         -> text "T" <> int n <> text "#"

instance Pretty OpMachine where
 ppr con
  = case con of
        OpStream  i o -> text "stream_"  <> int i <> text "_" <> int o <> text "#"
        OpProcess i o -> text "process_" <> int i <> text "_" <> int o <> text "#"
        OpPull        -> text "pull#"
        OpPush        -> text "push#"
        OpDrop        -> text "drop#"


instance CompoundName Name where
 extendName n str       
  = NameVarMod n str
 
 splitName nn
  = case nn of
        NameVarMod n str   -> Just (n, str)
        _                  -> Nothing


-- | Read the name of a variable, constructor or literal.
readName :: String -> Maybe Name
readName str
        | Just p <- readKiConMachine  str = Just $ NameKiConMachine  p
        | Just p <- readTyConMachine  str = Just $ NameTyConMachine  p
        | Just p <- readDaConMachine  str = Just $ NameDaConMachine  p
        | Just p <- readOpMachine     str = Just $ NameOpMachine     p

        -- Variables.
        | c : _                 <- str
        , isVarStart c
        , Just (str1, strMod)   <- splitModString str
        , Just n                <- readName str1
        = Just $ NameVarMod n strMod

        | c : _         <- str
        , isVarStart c      
        = Just $ NameVar str

        -- Constructors.
        | c : _         <- str
        , isUpper c
        = Just $ NameCon str

        | otherwise
        = Nothing


-- | Strip a `...$thing` modifier from a name.
splitModString :: String -> Maybe (String, String)
splitModString str
 = case break (== '$') (reverse str) of
        (_, "")         -> Nothing
        ("", _)         -> Nothing
        (s2, _ : s1)    -> Just (reverse s1, reverse s2)


-- | Read a kind constructor name.
readKiConMachine :: String -> Maybe KiConMachine
readKiConMachine str
 = case str of
        "Static" -> Just $ KiConStatic
        _        -> Nothing

-- | Read a type constructor name.
readTyConMachine :: String -> Maybe TyConMachine
readTyConMachine str
 | Just rest     <- stripPrefix "Tuple" str
 , (ds, "#")     <- span isDigit rest
 , not $ null ds
 , arity         <- read ds
 = Just $ TyConTuple arity

 | otherwise
 = case str of
        "Stream#"   -> Just $ TyConStream
        "Sink#"     -> Just $ TyConSink
        "Source#"   -> Just $ TyConSource
        "Process#"  -> Just $ TyConProcess
        _           -> Nothing

-- | Read a data constructor name.
readDaConMachine :: String -> Maybe DaConMachine
readDaConMachine str
        | Just rest     <- stripPrefix "T" str
        , (ds, "#")     <- span isDigit rest
        , not $ null ds
        , arity         <- read ds
        = Just $ DaConTuple arity

        | otherwise
        = Nothing

-- | Read a series operator name.
readOpMachine :: String -> Maybe OpMachine
readOpMachine str
        | Just rest         <- stripPrefix "stream_" str
        , (ds, '_' : rest2) <- span isDigit rest
        , not $ null ds
        , inputs            <- read ds
        , (ds2, "#")        <- span isDigit rest2
        , not $ null ds2
        , outputs           <- read ds2
        = Just $ OpStream inputs outputs

        | Just rest         <- stripPrefix "process_" str
        , (ds, '_' : rest2) <- span isDigit rest
        , not $ null ds
        , inputs            <- read ds
        , (ds2, "#")        <- span isDigit rest2
        , not $ null ds2
        , outputs           <- read ds2
        = Just $ OpProcess inputs outputs

        | otherwise
        = case str of
                "pull#" -> Just $ OpPull
                "push#" -> Just $ OpPush
                "drop#" -> Just $ OpDrop
                _       -> Nothing



-- Kinds ----------------------------------------------------------------------
-- | Yield the kind of a primitive type constructor.
kindTyConMachine :: TyConMachine -> Kind Name
kindTyConMachine tc
 = case tc of
        TyConStream     -> kData `kFun` kStatic
        TyConSink       -> kData `kFun` kStatic
        TyConSource     -> kData `kFun` kStatic
        TyConProcess    ->              kStatic
        TyConTuple n    -> foldr kFun kData (replicate n kData)

-- | Yield the type of a data constructor.
typeDaConMachine :: DaConMachine -> Type Name
typeDaConMachine (DaConTuple n)
        = tForalls (replicate n kData)
        $ \args -> foldr tFun (tTupleN args) args

-- | Yield the type of a machine operator.
typeOpMachine :: OpMachine -> Type Name
typeOpMachine op
 = case op of
        -- stream_i_o# :
        --     : [in_0..in_i : Data]
        --     . [out_0..out_o : Data]
        --     . (Source in_0 .. -> Source in_i -> Sink out_0 .. -> Sink out_o -> Process)
        --     -> Stream in_0 .. -> Stream in_i
        --     -> Stream out_0 .. * Stream out_o
        OpStream inputs outputs
         -> tForalls (replicate (outputs + inputs) kData) 
         $ \_
         -> let sources = [TVar (UIx i) | i <- reverse [outputs..outputs + inputs-1]]
                sinks   = [TVar (UIx i) | i <- reverse [0..outputs-1]]
                proc    = tFunOfParamResult (map tSource sources ++ map tSink sinks) tProcess
                strins  = map tStream sources
                strouts = tTupleN (map tStream sinks)
            in tFunOfParamResult (proc : strins) strouts

        -- process_i_o# :
        --     : [in_0..in_i : Data]
        --     . [out_0..out_o : Data]
        --     . (Stream in_0 .. -> Stream in_i -> Stream out_0 .. * Stream out_o)
        --     -> Source in_0 .. -> Source in_i
        --     -> Sink out_0 .. -> Sink out_o
        --     -> Process
        OpProcess inputs outputs
         -> tForalls (replicate (outputs + inputs) kData) 
         $ \_
         -> let sources = [TVar (UIx i) | i <- reverse [outputs..outputs + inputs-1]]
                sinks   = [TVar (UIx i) | i <- reverse [0..outputs-1]]
                proc    = tFunOfParamResult (map tSource sources ++ map tSink sinks) tProcess
                strins  = map tStream sources
                strouts = tTupleN (map tStream sinks)
            in tFunOfParamResult strins strouts `tFun` proc


        -- pull# : [a : Data]. Source a -> (a -> Process) -> Process
        OpPull 
         -> tForall kData $ \tA 
         -> tSource tA `tFun` (tA `tFun` tProcess) `tFun` tProcess

        -- push# : [a : Data]. Sink a -> a -> Process -> Process
        OpPush 
         -> tForall kData $ \tA 
         -> tSink tA `tFun` tA `tFun` tProcess `tFun` tProcess

        -- drop# : [a : Data]. Source a -> Process -> Process
        OpDrop 
         -> tForall kData $ \tA 
         -> tSource tA `tFun` tProcess `tFun` tProcess


-- Compounds ------------------------------------------------------------------

-- Can't actually use a Static in function arrows, so just use Data instead for now
-- Maybe create a new static arrow later?
kStatic = kData -- TCon (TyConBound (UPrim (NameKiConMachine KiConStatic) sProp) sProp)

tTupleN :: [Type Name] -> Type Name
tTupleN tys     = tApps (tConTyConMachine (TyConTuple (length tys))) tys

tStream :: Type Name -> Type Name
tStream tA      = tApps (tConTyConMachine TyConStream)    [tA]

tSource :: Type Name -> Type Name
tSource tA      = tApps (tConTyConMachine TyConSource)    [tA]

tSink   :: Type Name -> Type Name
tSink   tA      = tApps (tConTyConMachine TyConSink)    [tA]

tProcess :: Type Name
tProcess = tConTyConMachine TyConProcess


tConTyConMachine :: TyConMachine -> Type Name
tConTyConMachine tcm
 = let  k       = kindTyConMachine tcm
        u       = UPrim (NameTyConMachine tcm) k
        tc      = TyConBound u k
   in   TCon tc



