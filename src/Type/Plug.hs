
module Type.Plug
	( plugClassIds
	, staticRsDataT
	, staticRsClosureT
	)

where

import Util
import Shared.Error

import Type.Exp
import Type.Util
import Type.Plate
import Type.Pretty

import Type.State
import Type.Class

import Debug.Trace

import qualified Data.Set	as Set
import Data.Set			(Set)

-----
stage	= "Type.Plug"


plugClassIds env xx
	= transZM (plugTable env) xx

-----
plugTable env
	= transTableId
	{ transV	= sinkVar
	, transT_leave	= plugT env}


plugT env t
 = case t of
	TClass k cid
	 | elem cid env	
	 -> 	return t

	 | otherwise
	 -> do	var	<- makeClassName cid
		Just c	<- lookupClass cid
	 	return	$ TVar (classKind c) var
		
	_ -> 	return t
	


-----
-- staticRsDataT
--	return the list of region classes which are non-generalisable because
--	they appear in non-function types.
--
staticRsDataT :: Type -> Set ClassId
staticRsDataT tt
 = case tt of
	TVar{}			-> Set.empty
	TClass k cid		
	 | k == KRegion		-> Set.singleton cid
	 | otherwise		-> Set.empty

	TSum k ts
	 | k == KEffect		-> Set.empty
	 | k == KClosure	-> Set.unions $ map staticRsDataT ts

	TMask KClosure t1 t2	-> staticRsDataT t1
	TMask{}			-> Set.empty


 	TData v ts		-> Set.unions $ map staticRsDataT ts
	TFun{}			-> Set.empty
	TFetters fs t		-> staticRsDataT t
	TForall vks t		-> staticRsDataT t
	
	TFree v t		-> staticRsDataT t
	
	TError k t		-> Set.empty

	TBot{}			-> Set.empty

	-- for data containing function objects
	TEffect{}		-> Set.empty
	
	_ 	-> panic stage
		$ "staticRsDataT: " ++ show tt
		
-----
-- staticRsClosureT
--	Region cids that are free in the closure of the outer-most function
--	constructor(s) are being shared with the caller. These functions
--	did not allocate those regions, so they be can't generalised here.
--
staticRsClosureT
	:: Type -> Set ClassId

staticRsClosureT t
 = case t of
	TFetters fs t		-> staticRsClosureT t
 	TFun t1 t2 eff clo	-> staticRsDataT clo
	TData v ts		-> Set.unions $ map staticRsClosureT ts
	_ 			-> Set.empty

	
