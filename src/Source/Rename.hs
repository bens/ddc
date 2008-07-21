
-- | Apply scoping rules and add VarBinds to every variable in the program.
module Source.Rename
	( Rename
	, renameTrees )
where

-----
import Shared.Error		(panic)
import qualified Shared.Var	as Var
import qualified Shared.VarUtil	as Var
import Shared.Var		(NameSpace (..), Module(..))
import Shared.VarUtil		(isCtorName)
import Shared.Pretty
import Shared.Base

import Source.Util
import Source.Horror
import Source.RenameM
import Source.Slurp
import Source.Error
import Source.Exp

import Type.Util
import Type.Plate.Collect
import Type.Plate.FreeVars

import qualified Data.Set	as Set
import Data.Set			(Set)

import qualified Debug.Trace
import Util


-----
stage		= "Source.Rename"
-- debug		= True
-- trace s xx	= if debug then Debug.Trace.trace (pprStrPlain s) xx else xx

-- Tree --------------------------------------------------------------------------------------------
renameTrees
	-- | the modules to rename.
	--   the current module should be first, and all the imported ones afterwards.
	:: [(Module, Tree SourcePos)]		

	-> RenameM 
		[(Module, Tree SourcePos)]	

renameTrees mTrees@(mTree1 : mTreeImports)
 = do
	-- bind all the top-level names.
	--	Do the imports first so if we have name clashes at top level the vars
	--	in the error messages will come out in the right order.
	mapM_ bindTopNames mTreeImports
	bindTopNames mTree1
	
	-- now rename all the trees
	mTrees'	<- mapM renameTree mTrees
	return	mTrees'

-- Add the top-level names from this module to the renamer state
bindTopNames :: (Module, Tree SourcePos) -> RenameM ()
bindTopNames (moduleName, tree)
 = do
 	-- Slurp out all the top-level names.	
	let vsTop	= catMap slurpTopNames tree
	
	-- Add them to the rename state, along with the module name so it gets
	--	set on linked vars. 
	mapM_ (\v -> lbindZ v { Var.nameModule = moduleName }) vsTop

	return ()

-- Rename a source tree in this module
renameTree :: (Module, Tree SourcePos) -> RenameM (Module, Tree SourcePos)
renameTree (moduleName, tree)
 = do	tree'	<- rename tree
	return	(moduleName, tree')
	
	
-- Top ---------------------------------------------------------------------------------------------
instance Rename (Top SourcePos) where
 rename	top
  = case top of
	PPragma sp es
	 -> do 	return	$ PPragma sp es 	

	PModule sp m
	 -> do 	m'	<- rename m
		return	$ PModule sp m'

	PImportModule sp ms
	 -> do	ms'	<- rename ms
		return	$ PImportModule sp ms'

	PExport sp exs
	 -> do	exs'	<- rename exs
		return	$ PExport sp exs'

	PForeign sp f
	 -> do	f'	<- rename f
	 	return	$ PForeign sp f'

	PInfix sp m i vs
	 -> do 	vs'	<- mapM lbindV vs
		return	$ PInfix sp m i vs'

	-- types
	PTypeKind sp v k
	 -> do	v'	<- lookupV v
	 	return	$ PTypeKind sp v' k

	PTypeSynonym sp v t		
	 -> do 	v'	<- lookupV v
	 	t'	<- local $ rename t
		return	$ PTypeSynonym sp v' t'

	PData sp vData vsData ctors
	 -> local
	  $ do
	 	vData'	<- lookupN NameType vData
		vsData'	<- mapM bindZ vsData
		ctors'	<- mapM (renameCtor vData' vsData') ctors
	
		return	$ PData sp vData' vsData' ctors' 
	
	PRegion sp v
	 -> do	v'	<- lookupN NameRegion v
	 	return	$ PRegion sp v'
	
	PEffect sp v k
	 -> do 	v'	<- lookupN NameEffect v
		return	$ PEffect sp v' k

	PStmt	s
	 -> -- local
	    do	s'	<- rename s
		return	$ PStmt s'
	
	-- classes
	PClass sp v k
	 -> do 	v'	<- lookupN NameClass v
	 	return	$ PClass sp v' k

	PClassDict sp v vks inh sigs
	 -> do 	v'	<- lbindN NameClass v

		(vs', inh', sigs')
		 <- local
		 $ do	let (vs, ks)	= unzip vks
			vs'		<- mapM (lbindN NameType) vs
			let vks'	= zip vs' ks
			
			inh'	<- mapM renameClassInh inh
			sigs'	<- mapM renameClassSig sigs
			return	(vks', inh', sigs')
	
		return	$ PClassDict sp v' vs' inh' sigs'

	PClassInst sp v ts inh stmts
	 -> do
	 	v'	<- lbindN NameClass v

		(ts', inh')
		 <- local
		 $ do	ts'	<- rename ts
			inh'	<- mapM renameInstInh inh
			return	(ts', inh')

		stmts'	<- rename stmts

		return	$ PClassInst sp v' ts' inh' stmts'			

	-- projections
	PProjDict sp t ss
	 -> do	
	 	-- The way the projection dict is parsed, the projection funtions end up in the wrong namespace, 
		--	NameValue. Convert them to NameField vars here.
		--	
		let fixupV v	= v 	{ Var.nameSpace 	= NameField }
		
		let ssF		= map (\s -> case s of 
					SSig  sp v t		-> SSig   sp 	(fixupV v) t
					SBindFun sp v xs x	-> SBindFun sp	(fixupV v) xs x)
			$ ss
	 
	   	t' 	<- local
		 	 $ do	t'	<- rename t
				return	t'
	
		ss'	<- rename ssF
		return	$ PProjDict sp t' ss'

-- Export ------------------------------------------------------------------------------------------
instance Rename (Export SourcePos) where
 rename ex	
  = case ex of
	EValue sp v 
	 -> do	v'	<- lookupV v
		return	$ EValue sp v'

	EType sp v 
	 -> do	v'	<- lookupN NameType v
		return	$ EType sp v'
	
	ERegion sp v 
	 -> do	v'	<- lookupN NameRegion v
		return	$ ERegion sp v'

	EEffect sp v 
	 -> do	v'	<- lookupN NameEffect v
		return	$ EEffect sp v'

	EClass sp v 
	 -> do	v'	<- lookupN NameClass v
		return	$ EClass sp v'

-- Module ------------------------------------------------------------------------------------------
instance Rename Module where
 rename m	= return m
 
 
-- Foreign -----------------------------------------------------------------------------------------
instance Rename (Foreign SourcePos) where
 rename ff
  = case ff of
 	OImport mS v tv to 
	 -> local
	 $  do 	v'	<- lookupV v
	 	tv'	<- rename tv
		to'	<- rename to
		return	$ OImport mS v' tv' to' 
	
	OImportUnboxedData s v k
	 -> local
	  $ do	v'	<- lookupN NameType v
		return	$ OImportUnboxedData s v' k

-- Classes -----------------------------------------------------------------------------------------
-- all this stuff should really have it's own constructor
--
renameClassInh :: (Var, [Var])  -> RenameM (Var, [Var])
renameClassInh	  (v, vs)
 = do	v'	<- lbindN NameClass v
	vs'	<- mapM (lbindN NameType) vs
	return	(v, vs)


renameClassSig :: ([Var], Type) -> RenameM ([Var], Type)
renameClassSig    (vs, t)
 = local
 $ do 	vs'	<- mapM lbindV vs
	t'	<- rename t
	return	(vs', t')


renameInstInh :: (Var, [Type])	-> RenameM (Var, [Type])
renameInstInh    (v, ts)
 = do
 	v'	<- lookupN NameClass v
	ts'	<- rename ts
	return	(v', ts')
		

-- Constructor -----------------------------------------------------------------
renameCtor 
	:: Var			-- type constructor name
	-> [Var]		-- type constructor parameters
	-> (Var, [DataField (Exp SourcePos) Type])	
	-> RenameM (Var, [DataField (Exp SourcePos) Type])

renameCtor vData vsData (v, fields)
 = do	v'	<- lookupV v
	fields'	<- mapM (renameDataField vData vsData) fields
	return	(v', fields')


renameDataField vData vsData df
  = do	
  	-- field vars aren't supposed to have module qualifiers...
  	let fixupV v	
  		= v { Var.nameSpace 	= NameField
		    , Var.nameModule 	= ModuleNil }

   	mLabel'	<- case dLabel df of
			Nothing		-> return Nothing
			Just label
			 -> do 	label'	<- lbindN NameField label
				return	$ Just $ fixupV label'

	tField'	<- rename $ dType df

	-- check that all vars in the field type are params to the type constructor.
	let vsFree	= Set.filter (not . Var.isCtorName) $ freeVars tField'
	let vsBad	= Set.difference vsFree (Set.fromList vsData)

	when (not $ Set.null vsBad)
	 $ mapM_ (\v -> addError $ ErrorUndefinedVar v) $ Set.toList vsBad

	mExp'	<- rename $ dInit df

	return 	df
		{ dLabel	= mLabel'
		, dType		= tField'
		, dInit		= mExp' }
		
	
-- Expressions -----------------------------------------------------------------
instance Rename (Exp SourcePos) where 
 rename exp
  = case exp of

	-- core
	XLit sp lit		
	 -> return exp

	XVar sp v		
	 -> do 	v'	<- lookupV v
		return	$ XVar sp v'

	XProj sp x proj
	 -> do 	x'	<- rename x
		proj'	<- rename proj
		return	$ XProj sp x' proj'

	XProjT sp t proj
	 -> do	t'	<- rename t
	 	proj'	<- rename proj
		return	$ XProjT sp t' proj'

	XApp sp e1 e2	
	 -> do 	e1'	<- rename e1
		e2'	<- rename e2
		return	$ XApp sp e1' e2'

	XCase sp e1 cs	
	 -> do 	e1'	<- rename e1
		cs'	<- rename cs
		return	$ XCase sp e1' cs'

	XDo sp ss 
	 -> local
	 $ do 	ss'	<- renameSs ss
		return	$  XDo sp ss'

 	XLet sp ss e	
	 -> local
	 $ do 	ss'	<- renameSs ss
		e'	<- rename e
		return	$ XLet sp ss' e'
		
	XWhere sp x ss
	 -> local
	 $ do	ss'	<- renameSs ss
		x'	<- rename x
		return	$ XWhere sp x' ss'
		

	XIfThenElse sp e1 e2 e3 
	 -> do 	e1'	<- rename e1
		e2'	<- rename e2
		e3'	<- rename e3
		return	$ XIfThenElse sp e1' e2' e3'
		
	-- oop
	XObjField sp v
	 -> do	objV	<- peekObjectVar
		v'	<- lbindN NameField v
		return	$ XProj sp (XVar sp objV) (JField sp v')
		
	-- sugar
	XLambdaPats sp ps x
	 -> local
	 $ do 	(ps', _)	<- liftM unzip 
	 			$ mapM (bindPat False) ps

		x'		<- rename x
		return	$ XLambdaPats sp ps' x'

	XLambdaCase sp cs
	 -> do 	cs'	<- rename cs
		return	$ XLambdaCase sp cs'
		
	XLambdaProj sp j xs
	 -> do	j'	<- rename j
	 	xs'	<- rename xs
	 	return	$ XLambdaProj sp j' xs'
		
	-- defix sugar
	XOp sp v 
	 | Var.name v	== "@"
	 -> 	return	$ XOp sp v
	 
	 | otherwise
	  -> do	v'	<- lookupV v
	 	return	$ XOp sp v'

	XDefix sp es 
	 -> do 	es'	<- rename es
		return	$ XDefix sp es'

	XDefixApps sp es
	 -> do	es'	<- rename es
	 	return	$ XDefixApps sp es'
		
	XAppSusp sp x1 x2
	 -> do	x1'	<- rename x1
	 	x2'	<- rename x2
		return	$ XAppSusp sp x1' x2'
		
	-- match sugar
	XMatch sp aa
	 -> do	aa'	<- rename aa
	 	return	$ XMatch sp aa'
		
	-- exception sugar
	XTry sp x aa w
	 -> do 	x'	<- rename x
	 	aa'	<- rename aa
		w'	<- rename w
		return	$ XTry sp x' aa' w'

	XThrow sp x
	 -> do	x'	<- rename x
	 	return	$ XThrow sp x'

	-- imperative sugar
	XWhile sp x1 x2
	 -> do	x1'	<- rename x1
	 	x2'	<- rename x2
		return	$ XWhile sp x1' x2'
		
	XWhen sp x1 x2
	 -> do	x1'	<- rename x1
	 	x2'	<- rename x2
		return	$ XWhen sp x1' x2'
		
	XUnless sp x1 x2
	 -> do	x1'	<- rename x1
	 	x2'	<- rename x2
		return	$ XUnless sp x1' x2'

	XBreak sp
	 ->	return	exp

	-- list sugar
	XListRange sp b x1 x2
	 -> do	x1'	<- rename x1
	 	x2'	<- rename x2
		return	$ XListRange sp b x1' x2'

	XListComp sp x qs
	 -> local
	 $ do	qs'	<- renameLCQuals qs

		addN NameValue
			$ concat $ map boundByLCQual qs'
		x'	<- rename x
		return	$ XListComp sp x' qs'

	XTuple sp xx
	 -> do	xx'	<- rename xx
	 	return	$ XTuple sp xx'
		
	XList sp xx
	 -> do	xx'	<- rename xx
	 	return	$ XList sp xx'
		
	_ -> panic stage
		$ "rename: cannot rename " % show exp
		
			
-- Projections -------------------------------------------------------------------------------------
instance Rename (Proj SourcePos) where
 rename jj 
  = case jj of
	JField sp v
	 -> do	v'	<- lbindN NameField v
		return	$ JField sp v'
		
	JFieldR sp v
	 -> do	v'	<- lbindN NameField v
	 	return	$ JFieldR sp v'

	JIndex sp x
	 -> do	x'	<- rename x
	 	return	$ JIndex sp x'
		
	JIndexR sp x
	 -> do	x'	<- rename x
	 	return	$ JIndexR sp x'

	
-- Alternatives ------------------------------------------------------------------------------------
instance Rename (Alt SourcePos) where
 rename a
  = case a of
	APat sp p x2
	 -> do	(p', x2')
	 	 	<- local
		  	$ do	(p', [])	<- bindPat False p
			 	x2'		<- rename x2
				return (p', x2')

		return	$ APat sp p' x2'

	AAlt sp gs x
	 -> do	(gs', x')
	 		<- local
			$ do	gs'	<- mapM bindGuard gs
				x'	<- rename x
				return	(gs', x')
				
		return	$ AAlt sp gs' x'

	ADefault sp x
	 -> do	x'	<- rename x
	 	return	$  ADefault sp x'


-- Labels ------------------------------------------------------------------------------------------
instance Rename (Label SourcePos) where
 rename ll
  = case ll of
  	LIndex sp i	-> return ll

	LVar sp v 
	 -> do	v'	<- lbindN NameField v
	 	return	$  LVar sp v'
	 


-- Patterns ----------------------------------------------------------------------------------------

-- | Bind the variables in a guard
bindGuard :: Guard SourcePos -> RenameM (Guard SourcePos)
bindGuard gg
 = case gg of
	GExp sp  pat x
	 -> do	x'		<- rename x	
	 	(pat', [])	<- bindPat False pat
		return	$ GExp sp pat' x'
		
	GBool sp x
	 -> do	x'	<- rename x
	 	return	$ GBool sp x'
		

-- | Bind the variables in a pattern
bindPat :: Bool			-- lazy bind
	-> Pat SourcePos 
	-> RenameM 
		( Pat SourcePos
		, [Var])

bindPat lazy ww
 = case ww of
 	WVar sp v
	 -> do	v'	<- if lazy 	then lbindV v
	 				else bindV v

	 	return	( WVar sp v'
			, [])

	WObjVar sp v	
	 -> do	v'	<- bindV v
	 	return	( WVar sp v'
			, [v'])
 
 	WLit sp _
	 -> do	return	(ww, [])
	 
	WCon sp v ps
	 -> do	v'		<- lookupV v
	 	(ps', bvs)	<- liftM unzip $ mapM (bindPat lazy) ps
		return	( WCon sp v' ps'
			, concat bvs)
	 
	WConLabel sp v lvs 
	 -> do	v'		<- lookupV v

	 	let (ls, vs)	= unzip lvs
		ls'		<- rename ls
		(vs', bvss)	<- liftM unzip 
				$ mapM (bindPat lazy) vs
		let lvs'	= zip ls' vs'
		
		return	( WConLabel sp v' lvs'
			, concat bvss)
	
	WAt sp v p
	 -> do	(p', vs)	<- (bindPat lazy) p
	 	v'		<- bindV v
		return	( WAt sp v' p'
			, vs)
	
	WWildcard sp	-> return (ww, [])
	WUnit sp	-> return (ww, [])

	WTuple sp xs
	 -> do	(xs', vss)	<- liftM unzip $ mapM (bindPat lazy) xs
	 	return	( WTuple sp xs'
			, concat vss)
	
	WCons sp x1 x2
	 -> do	(x1', vs1)	<- bindPat lazy x1
	 	(x2', vs2)	<- bindPat lazy x2
		return	( WCons sp x1' x2'
			, vs1 ++ vs2)
		
	WList sp xs
	 -> do	(xs', vss)	<- liftM unzip $ mapM (bindPat lazy) xs
	 	return	( WList sp xs'
			, concat vss)
		
	 

-----------------------
-- renameLCQuals
--	Rename some list comprehension qualifiers.
--	In a sequence of qualifiers, the vars bound in a qualifier
--	are in-scope for subsequent qualifiers.
--
renameLCQuals :: [LCQual SourcePos] -> RenameM [LCQual SourcePos]
renameLCQuals qq
 = case qq of
  	[]			
	 -> 	return []

	(LCGen b (WVar sp v) x2 : qs)
	 -> do	x2'	<- rename x2
		local
		 $ do	v'	<- bindV v
			qs'	<- renameLCQuals qs		
			return	$ (LCGen b (WVar sp v') x2' : qs')
		
	(LCExp x : qs)
	 -> do	x'	<- rename x
	 	qs'	<- renameLCQuals qs
		return	$ LCExp x' : qs'
		

boundByLCQual :: LCQual SourcePos -> [Var]
boundByLCQual    q
 = case q of
 	LCGen _ (WVar sp v) _	-> [v]
	LCExp{}			-> []


-- Stmt --------------------------------------------------------------------------------------------

instance Rename (Stmt SourcePos) where
 rename s
  = case s of
	SSig sp v t
	 -> do	v'	<- lbindZ v
		t'	<- local $ rename t
		return	$ SSig sp v' t'

	SStmt sp x
	 -> do	x'	<- local $ rename x
		return	$ SStmt sp x'		

	SBindFun sp v ps x
	 -> do	v'	<- lbindZ v

	 	local
		 $ do	(ps', objVss)	<- liftM unzip
					$  mapM (bindPat False) ps

			let objVs	= concat objVss

			(case objVs of
			  []	-> return ()
			  [v]	-> pushObjectVar v)

			x'		<- rename x

			(case objVs of
			  []	-> return ()
			  [v]	-> do { popObjectVar; return () })

			return	$ SBindFun sp v' ps' x'

	SBindPat sp pat x
	 -> do	(pat', _) <- bindPat True pat
	 	x'	<- rename x
		return	$ SBindPat sp pat' x'
	 	
	SBindMonadic sp pat x
	 -> do	(pat', _) <- bindPat True pat
	 	x'	<- rename x
		return	$ SBindMonadic sp pat' x'


		

-- | Rename the variables in a list of statements
--	When using pattern bindings, the bound variable can appear in multiple statements
--	ie 	not True	= False
--		not False	= True
--
--	BUGS: make it an error for non-consecutive bindings to bind the same variable.
---
renameSs ::	[Stmt SourcePos] -> RenameM [Stmt SourcePos]
renameSs	ss
 = do	-- work out all the vars that are bound by this list of stmts
 	let vsBound	= catMap takeStmtBoundVs ss

	-- create fresh binding occurances to shadow anything with the same name bound above.
	mapM_ (lbindN_shadow NameValue) 
		$ nub vsBound

	-- Rename each statement.
	ss'	<- mapM rename ss

	return ss'

		

-- Type --------------------------------------------------------------------------------------------
instance Rename Type where
 rename tt
  = case tt of
	TForall b k t
	 -> do 	(b', t')	<- local 
		 $  do	let (BVar v)	= b
		 	v'	<- bindZ v
			t'	<- rename t
			return	(BVar v', t')

		let tt'		= TForall b' k t'
		return tt'
{-
		-- If a type contains an explicit forall then all free vars must be bound by it.
		-- .. this doesn't work for class definitions.
		-- .. perhaps we should use the renamer state to indicate whether all tyvars need
		-- .. to be bound by the forall.

		let vsFree	= Set.filter (not . Var.isCtorName)
				$ freeVars tt'
		
		if Set.null vsFree
		 then return	$ tt'
		 else do
		 	mapM_ 	(\v -> addError ErrorUndefinedVar { eUndefined = v })
				$ Set.toList vsFree
			return tt
-}

	TFetters t fs
	 -> do
	 	let bindingVars	=  catMaybes $ map takeBindingVarF fs

	  	-- if any of the LHS vars are already bound (perhaps by a forall) at this level
	  	--	then this is an error. Type vars aren't permitted to shadow each other.
		isShadowed	<- mapM isBound_local bindingVars
		let shadowVars	= [ v 	| (v, True) <- zip bindingVars isShadowed]
		let shadow	=  not $ null shadowVars

		when shadow
		 $ modify (\s -> s { 
	  		stateErrors 	= (stateErrors s) ++ map ErrorShadowVar shadowVars })

		local
		  $ do	
		  	-- bind the vars on the LHS of let binds
		  	mapM_ bindZ bindingVars

			fs'	<- rename fs
			t'	<- rename t
			return	$ TFetters t' fs'
			 	
	TVar k v 	
	 -> do 	v'	<- lbindN (spaceOfKind k) v
		return	$ TVar k v'

	TSum k ts
	 -> do	ts'	<- rename ts
	 	return	$ TSum k ts'

	TApp t1 t2
	 -> do	t1'	<- rename t1
	 	t2'	<- rename t2
		return	$ TApp t1' t2'
		
	TCon tc
	 -> do	tc'	<- rename tc
	 	return	$ TCon tc'

	TTop k 	 -> return tt
	TBot k	 -> return tt

	-- data
 	TFun t1 t2 eff clo
	 -> do 	t1'	<- rename t1
		t2'	<- rename t2
		eff'	<- rename eff
		clo'	<- rename clo
		return	$ TFun t1' t2' eff' clo'

	TData k v ts		
	 -> do 	v'	<- lookupN NameType v
		ts'	<- mapM rename ts
		return	$ TData k v' ts'
	
	-- effect
	TEffect v rs
	 -> do 	v'	<- lookupN NameEffect v
		rs'	<- rename rs
		return	$ TEffect v' rs'
		
	-- closure
	TFree v t
	 -> do	v'	<- lbindV v
	 	local
		 $  do	t'	<- rename t
		 	return	$ TFree v' t'
	
	TDanger t1 t2
	 -> do	t1'	<- rename t1
	 	t2'	<- rename t2
		return	$ TDanger t1' t2'
	
	TMask k t1 t2
	 -> do	t1'	<- rename t1
	 	t2'	<- rename t2
		return	$ TMask k t1' t2'
	
	TTag v
	 -> do	v'	<- lbindV v
	 	return	$ TTag v'
	
	-- wildcards
	TWild k
	 -> 	return	$ TWild k

	-- 
	TElaborate ee t
	 -> do	t'	<- rename t
	 	return	$ TElaborate ee t'
		
-- TyCon -------------------------------------------------------------------------------------------
instance Rename TyCon where
 rename tc
  = case tc of
  	TyConFun{}
	 -> do 	return	tc
		
	TyConData { tyConName }
	 -> do	v	<- lookupN NameType tyConName
	 	return	$ tc { tyConName = v }

-- Fetter ------------------------------------------------------------------------------------------
instance Rename Fetter where
 rename f
  = case f of
	FConstraint v ts
	 -> do 	v'	<- lookupN NameClass v
		ts'	<- rename ts
		return	$ FConstraint v' ts'

  	FWhere t1 t2
	 -> do	t1'	<- rename t1
		t2'	<- rename t2
		return	$ FWhere t1' t2'

