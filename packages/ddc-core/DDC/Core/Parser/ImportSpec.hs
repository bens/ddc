
module DDC.Core.Parser.ImportSpec
        ( ImportSpec    (..)
        , pImportSpecs)
where
import DDC.Core.Module
import DDC.Core.Parser.Type
import DDC.Core.Parser.Context
import DDC.Core.Parser.Base
import DDC.Core.Parser.DataDef
import DDC.Core.Lexer.Tokens
import DDC.Base.Pretty
import Control.Monad
import qualified DDC.Base.Parser        as P


---------------------------------------------------------------------------------------------------
-- | An imported thing.
--
--   During parsing the specifications of all imported things are bundled
--   into this common type. The caller can split them out into separate 
--   buckets if it wants to.
--
data ImportSpec n
        = ImportType    n (ImportType   n)
        | ImportCap     n (ImportCap    n)
        | ImportValue   n (ImportValue  n)
        | ImportData    (DataDef n)
        deriving Show
        

-- | Parse some import specifications.
pImportSpecs
        :: (Ord n, Pretty n)
        => Context n -> Parser n [ImportSpec n]

pImportSpecs c
 = do   
        -- import ...
        pTok KImport

        P.choice
         [      -- data ...
           do   def     <- pDataDef c
                return  [ ImportData def ]

                -- import value { (NAME :: TYPE)+ }
         , do   P.choice [ pTok KValue, return () ]
                pTok KBraceBra
                specs   <- P.sepEndBy1 (pImportValue c) (pTok KSemiColon)
                pTok KBraceKet
                return specs

                -- foreign ...
         , do   pTok KForeign
                src     <- liftM (renderIndent . ppr) pName

                P.choice
                 [      -- import foreign MODE type { (NAME : TYPE)+ }
                  do    pTok KType
                        pTok KBraceBra
                        sigs <- P.sepEndBy1 (pImportForeignType c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs
        
                        -- import foreign MODE capability { (NAME : TYPE)+ }
                 , do   pTok KCapability
                        pTok KBraceBra
                        sigs <- P.sepEndBy1 (pImportForeignCap c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs

                        -- import foreign MODE value { (NAME : TYPE)+ }
                 , do   pTok KValue
                        pTok KBraceBra
                        sigs <- P.sepEndBy1 (pImportForeignValue c src) (pTok KSemiColon)
                        pTok KBraceKet
                        return sigs
                 ]
         ]
         P.<?> "something to import"


---------------------------------------------------------------------------------------------------
-- | Parse a foreign type import specification.
pImportForeignType
        :: (Ord n, Pretty n) 
        => Context n -> String -> Parser n (ImportSpec n)

pImportForeignType c src

        -- Abstract types are not associated with data values,
        -- they can be used as phantom type parameters, 
        -- or have a kind of something that is not Data.
        | "abstract"    <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c
                return  $ ImportType n (ImportTypeAbstract k)

        -- Boxed types are associate with values that follow the standard
        -- heap object layout. They can be passed and return from functions.
        | "boxed"       <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c
                return  $ ImportType n (ImportTypeBoxed k)

        | otherwise
        = P.unexpected "import mode for foreign type."


---------------------------------------------------------------------------------------------------
-- | Parse a foreign capability import specification.
pImportForeignCap
        :: (Ord n, Pretty n)
        => Context n -> String -> Parser n (ImportSpec n)

pImportForeignCap c src

        -- Abstract capability.
        | "abstract"    <- src
        = do    n       <- pName
                pTokSP  (KOp ":")
                t       <- pType c
                return  $  ImportCap n (ImportCapAbstract t)

        | otherwise
        = P.unexpected "import mode for foreign capability."


---------------------------------------------------------------------------------------------------
-- | Parse a value import specification.
---
-- When we parse this initially the arity information is set to Nothing.
-- The arity information itself comes in with the associated ARITY pragma
-- which is parsed separately. The information from the ARITY pragma
-- is attached to the `InputValueModule` constructor by the Module parser.
--
pImportValue
        :: (Ord n, Pretty n)
        => Context n -> Parser n (ImportSpec n)

pImportValue c
 = do   n       <- pName
        pTokSP (KOp ":")
        t       <- pType c
        return  (ImportValue n (ImportValueModule (ModuleName []) n t Nothing))


-- | Parse a foreign value import spec.
pImportForeignValue    
        :: (Ord n, Pretty n)
        => Context n -> String -> Parser n (ImportSpec n)

pImportForeignValue c src
        | "c"           <- src
        = do    n       <- pName
                pTokSP (KOp ":")
                k       <- pType c

                -- ISSUE #327: Allow external symbol to be specified 
                --             with foreign C imports and exports.
                let symbol = renderIndent (ppr n)

                return  $ ImportValue n (ImportValueSea symbol k)

        | otherwise
        = P.unexpected "import mode for foreign value."
