{-# OPTIONS -fwarn-unused-imports #-}

-- | Helpers for converting Sea to LLVM code.
module Llvm.Runtime
	( runtimeEnter
	, runtimeLeave

	, panicOutOfSlots
	, allocCollect
	, force

	, ddcSlotPtr
	, ddcSlotMax
	, ddcSlotBase

	, ddcHeapPtr
	, ddcHeapMax

	, writeSlot
	, readSlot
	, localSlotBase

	, allocate

	, boxInt32	, unboxInt32
	, boxInt64
	, boxFloat32
	, boxFloat64 )
where

import DDC.Main.Error

import Llvm
import Llvm.GhcReplace.Unique
import Llvm.Runtime.Alloc
import Llvm.Runtime.Boxing
import Llvm.Runtime.Data
import Llvm.Runtime.Slot
import Llvm.Util

stage :: String
stage = "Llvm.Runtime"

-- | Generate LLVM code that reserves the required number of GC slots
-- at the start of a function.
runtimeEnter :: Int -> IO [LlvmStatement]
runtimeEnter 0
 = do	return	$
		[ Comment ["_ENTER (0)"]
		, Comment ["---------------------------------------------------------------"]
		]

runtimeEnter count
 = do	let enter1	= LMNLocalVar "enter.1" ppObj
	let enter2	= LMNLocalVar "enter.2" ppObj
	let enter3	= LMNLocalVar "enter.3" i1
	let epanic	= fakeUnique "enter.panic"
	let egood	= fakeUnique "enter.good"
	slotInitCode	<- slotInit egood count
	return	$
		[ Comment ["_ENTER (" ++ show count ++ ")"]
		, Assignment localSlotBase (Load ddcSlotPtr)
		, Assignment enter1 (GetElemPtr True localSlotBase [llvmWordLitVar count])
		, Store enter1 ddcSlotPtr

		, Assignment enter2 (Load ddcSlotMax)
		, Assignment enter3 (Compare LM_CMP_Ult enter1 enter2)
		, BranchIf enter3 (LMLocalVar egood LMLabel) (LMLocalVar epanic LMLabel)
		, MkLabel epanic
		, Expr (Call StdCall (LMGlobalVar "_panicOutOfSlots" (LMFunction panicOutOfSlots) External Nothing Nothing True) [] [NoReturn])
		, Branch (LMLocalVar egood LMLabel)
		, MkLabel egood
		, Comment ["----- Slot initialization -----"]
		]
		++ slotInitCode
		++ [ Comment ["---------------------------------------------------------------"] ]


-- | Generate LLVM code that releases the required number of GC slots
-- at the start of a function.
runtimeLeave :: Int -> [LlvmStatement]
runtimeLeave 0
 =	[ Comment ["---------------------------------------------------------------"]
	, Comment ["_LEAVE"]
	, Comment ["---------------------------------------------------------------"]
	]

runtimeLeave _
 =	[ Comment ["---------------------------------------------------------------"]
	, Comment ["_LEAVE"]
	, Store localSlotBase ddcSlotPtr
	, Comment ["---------------------------------------------------------------"]
	]


slotInit :: Unique -> Int -> IO [LlvmStatement]
slotInit _ count
 | count < 0
 = panic stage $ "Asked for " ++ show count ++ " GC slots."

slotInit _ count
 | count < 8
 = let	build n
	 =	let target = LMNLocalVar ("init.target." ++ show n) ppObj
		in	[ Assignment target (GetElemPtr False localSlotBase [llvmWordLitVar n])
			, Store nullObj target ]
   in	return $ concatMap build [0 .. (count - 1)]


slotInit initstart n
 | otherwise
 = do	let initloop	= fakeUnique "init.loop"
	let initend		= fakeUnique "init.end"
	let index		= LMNLocalVar "init.index" llvmWord
	let indexNext	= LMNLocalVar "init.index.next" llvmWord
	let initdone	= LMNLocalVar "init.done" i1
	let target		= LMNLocalVar "init.target" ppObj
	return $
		[ Branch (LMLocalVar initloop LMLabel)

		, MkLabel initloop
		, Assignment index (Phi llvmWord [((llvmWordLitVar (0 :: Int)), (LMLocalVar initstart LMLabel)), (indexNext, (LMLocalVar initloop LMLabel))])

		, Assignment target (GetElemPtr False localSlotBase [index])
		, Store nullObj target

		, Assignment indexNext (LlvmOp LM_MO_Add index (llvmWordLitVar (1 :: Int)))
		, Assignment initdone (Compare LM_CMP_Eq indexNext (llvmWordLitVar n))
		, BranchIf initdone (LMLocalVar initend LMLabel)  (LMLocalVar initloop LMLabel)
		, MkLabel initend
		]


